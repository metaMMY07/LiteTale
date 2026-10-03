use super::models::*;
use anyhow::{anyhow, Context, Result};
use base64::Engine;
use encoding_rs::GBK;
use futures::stream::{self, StreamExt, TryStreamExt};
use once_cell::sync::Lazy;
use rand::Rng;
use regex::Regex;
use reqwest::{
    header::{
        HeaderMap, HeaderName, HeaderValue, ACCEPT, ACCEPT_LANGUAGE, CONNECTION, CONTENT_TYPE,
        REFERER, USER_AGENT,
    },
    Client, RequestBuilder, Response,
};
use scraper::Node::Element;
use scraper::{ElementRef, Html, Selector};
use serde::{Deserialize, Serialize};
use std::collections::HashSet;
use std::ops::Deref;
use std::sync::Arc;
use tokio::sync::{Mutex, RwLock};
use tokio::time::{sleep, Duration};

const DEFAULT_API_HOST: &str = "https://www.wenku8.net";
const APP_HOST: &str = "http://app.wenku8.com";
const SEARCH_INDEX_PROPERTY: &str = "search_index_v2_all_books";
const SEARCH_INDEX_TTL_SECONDS: i64 = 7 * 24 * 60 * 60;
const SEARCH_FALLBACK_PAGE_SIZE: usize = 20;

#[derive(Clone, Debug, Serialize, Deserialize)]
pub(crate) struct SearchIndexEntry {
    pub(crate) cover: NovelCover,
    pub(crate) author: String,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
struct SearchIndexCache {
    updated_at: i64,
    entries: Vec<SearchIndexEntry>,
}

static SEARCH_INDEX_CACHE: Lazy<RwLock<Option<SearchIndexCache>>> = Lazy::new(|| RwLock::new(None));
static SEARCH_INDEX_REFRESH_LOCK: Lazy<Mutex<()>> = Lazy::new(|| Mutex::new(()));
static AUTH_REQUEST_LOCK: Lazy<Mutex<()>> = Lazy::new(|| Mutex::new(()));

fn validate_captcha_response(status: u16, content_type: &str, body: &[u8]) -> Result<Vec<u8>> {
    if !(200..300).contains(&status) {
        return Err(anyhow!("captcha_fetch_failed HTTP {status}"));
    }
    if !content_type.to_ascii_lowercase().starts_with("image/") {
        let category = index_error_response_category(status, content_type, body);
        return Err(anyhow!("captcha_fetch_failed: {category}"));
    }
    if body.is_empty() || body.len() > 512 * 1024 {
        return Err(anyhow!("captcha_fetch_failed: invalid image size"));
    }
    let mut reader = image::io::Reader::new(std::io::Cursor::new(body)).with_guessed_format()?;
    if !matches!(reader.format(), Some(image::ImageFormat::Png | image::ImageFormat::Jpeg |
        image::ImageFormat::Gif | image::ImageFormat::WebP)) {
        return Err(anyhow!("captcha_fetch_failed: unsupported image format"));
    }
    let mut limits = image::io::Limits::default();
    limits.max_image_width = Some(1024);
    limits.max_image_height = Some(512);
    limits.max_alloc = Some(4 * 1024 * 1024);
    reader.limits(limits);
    reader.decode().context("captcha_fetch_failed: invalid image")?;
    Ok(body.to_vec())
}

fn login_error_message(body: &str) -> &'static str {
    if body.contains("用户不存在") || body.contains("用戶不存在") { "用户不存在" }
    else if body.contains("密码错误") || body.contains("密碼錯誤") { "密码错误" }
    else if body.contains("验证码过期") || body.contains("驗證碼過期") { "验证码过期" }
    else if body.contains("校验码错误") || body.contains("校驗碼錯誤") ||
        body.contains("验证码错误") || body.contains("驗證碼錯誤") { "验证码错误" }
    else { "登录结果未能确认，请打开站点查看。" }
}

fn is_retryable_get_error(error: &reqwest::Error) -> bool {
    let message = error.to_string().to_ascii_lowercase();
    error.is_connect()
        || error.is_timeout()
        || error.is_request()
        || message.contains("close_notify")
        || message.contains("unexpected eof")
        || message.contains("unexpected-eof")
        || message.contains("connection reset")
        || message.contains("connection closed")
}

fn index_error_response_category(status: u16, content_type: &str, body: &[u8]) -> &'static str {
    let preview = String::from_utf8_lossy(&body[..body.len().min(32 * 1024)]).to_ascii_lowercase();
    if status == 403
        && [
            "__cf_chl",
            "cf-chl-",
            "challenge-form",
            "just a moment",
            "attention required",
            "sorry, you have been blocked",
        ]
        .iter()
        .any(|marker| preview.contains(marker))
    {
        "Cloudflare challenge/block HTML"
    } else if status == 403 {
        "access-denied response"
    } else if content_type.to_ascii_lowercase().contains("text/html") {
        "HTML error response"
    } else {
        "non-HTML error response"
    }
}

/// Retry idempotent GET requests when Wenku8 closes a TLS connection early.
/// The site intermittently drops keep-alive connections without a TLS
/// `close_notify`; a fresh request normally succeeds immediately.
async fn send_idempotent_get(mut request: RequestBuilder) -> reqwest::Result<Response> {
    for attempt in 0..3 {
        let retry = request.try_clone();
        match request.send().await {
            Ok(response) => return Ok(response),
            Err(error) => {
                if attempt == 2 || !is_retryable_get_error(&error) {
                    return Err(error);
                }
                let Some(next_request) = retry else {
                    return Err(error);
                };
                sleep(Duration::from_millis(150 * (attempt + 1))).await;
                request = next_request;
            }
        }
    }
    unreachable!("GET retry loop always returns")
}

pub struct Wenku8Client {
    pub client: Client,
    pub user_agent: RwLock<String>,
    pub api_host: RwLock<String>,
}

impl Wenku8Client {
    pub async fn load_user_agent(&self) -> String {
        let user_agent = self.user_agent.read().await;
        user_agent.clone()
    }

    pub async fn set_user_agent(&self, user_agent_value: String) {
        let mut user_agent = self.user_agent.write().await;
        *user_agent = user_agent_value;
    }

    pub async fn load_api_host(&self) -> String {
        let api_host = self.api_host.read().await;
        if api_host.is_empty() {
            DEFAULT_API_HOST.to_string()
        } else {
            api_host.clone()
        }
    }

    pub async fn set_api_host(&self, api_host_value: String) {
        let mut api_host = self.api_host.write().await;
        *api_host = api_host_value;
    }

    // 👇 新增：統一產生常用標頭（帶 User-Agent / Referer / Accept 等）
    fn default_headers_sync(ua: &str, api_host: &str) -> HeaderMap {
        let mut headers = HeaderMap::new();
        headers.insert(
            USER_AGENT,
            HeaderValue::from_str(if ua.is_empty() {
                // 後備 UA（避免空字串）
                "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
            } else {
                ua
            }).unwrap_or(HeaderValue::from_static("Mozilla/5.0")),
        );
        headers.insert(
            ACCEPT,
            HeaderValue::from_static("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"),
        );
        headers.insert(
            ACCEPT_LANGUAGE,
            HeaderValue::from_static("zh-TW,zh;q=0.9,en;q=0.8"),
        );
        headers.insert(
            REFERER,
            HeaderValue::from_str(&format!("{api_host}/login.php"))
                .unwrap_or(HeaderValue::from_static("https://www.wenku8.net/login.php")),
        );
        headers.insert(CONNECTION, HeaderValue::from_static("keep-alive"));
        headers
    }

    // 模擬 Android app 的請求標頭，用於書架等 HTML 頁面請求
    // 使用 Dalvik UA（與其他請求一致），避免觸發 Cloudflare 的瀏覽器偵測
    async fn bookcase_headers(&self, referer: &str) -> HeaderMap {
        let ua = self.load_user_agent().await;
        let mut headers = HeaderMap::new();
        if let Ok(v) = HeaderValue::from_str(&ua) {
            headers.insert(USER_AGENT, v);
        }
        headers.insert(
            ACCEPT,
            HeaderValue::from_static(
                "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            ),
        );
        headers.insert(ACCEPT_LANGUAGE, HeaderValue::from_static("zh-CN,zh;q=0.9"));
        if !referer.is_empty() {
            if let Ok(v) = HeaderValue::from_str(referer) {
                headers.insert(REFERER, v);
            }
        }
        headers.insert(CONNECTION, HeaderValue::from_static("keep-alive"));
        headers
    }

    // 先訪問首頁與 login.php，讓伺服器種初始 Cookie（包含 CF 的 __cflb 等）
    pub async fn init_session(&self) -> Result<()> {
        let api_host = self.load_api_host().await;
        let home_headers = self.bookcase_headers(&format!("{api_host}/")).await;
        let mut login_headers = home_headers.clone();
        login_headers.insert(
            REFERER,
            HeaderValue::from_str(&format!("{api_host}/login.php"))
                .context("Invalid Wenku8 login referer")?,
        );
        // 1) 訪問首頁，觸發 CF cookie 設置
        let _ = send_idempotent_get(
            self.client
                .get(format!("{}/", api_host))
                .headers(home_headers),
        )
        .await;
        // 2) 再打 login.php 種 session cookie
        let _ = send_idempotent_get(
            self.client
                .get(format!("{}/login.php", api_host))
                .headers(login_headers),
        )
        .await;
        Ok(())
    }

    // 👇 修改：checkcode 先 init，再抓圖；若回 HTML（CF 挑戰）就回傳 cf_challenge
    pub async fn checkcode(&self) -> Result<Vec<u8>> {
        let _guard = AUTH_REQUEST_LOCK.lock().await;
        let host = self.load_api_host().await;
        let login_url = format!("{host}/login.php");
        let login_headers = self.bookcase_headers(&login_url).await;
        // The CAPTCHA belongs to this login document/session. Stop on a denied
        // document instead of fetching another challenge as though it were an image.
        let page = send_idempotent_get(self.client.get(&login_url).headers(login_headers)
            .timeout(Duration::from_secs(12))).await?;
        if !page.status().is_success() {
            return Err(anyhow!("captcha_session_failed HTTP {}", page.status().as_u16()));
        }
        let page_type = page.headers().get(CONTENT_TYPE).and_then(|v| v.to_str().ok()).unwrap_or("").to_string();
        let page_body = decode_home(page.bytes().await?, &page_type)?;
        if page_body.contains("__cf_chl") || page_body.contains("challenge-form") || page_body.contains("Just a moment") {
            return Err(anyhow!("cf_challenge"));
        }

        // 2) 準備 URL + 標頭
        let url = format!("{}/checkcode.php", self.load_api_host().await);
        let params = [("random", rand::rng().random::<f64>().to_string())];
        let url = reqwest::Url::parse_with_params(url.as_str(), &params)?;
        let ua = self.load_user_agent().await;
        let mut headers = Self::default_headers_sync(&ua, &host);
        headers.insert(ACCEPT, HeaderValue::from_static("image/png,image/jpeg,image/gif,image/webp,image/*;q=0.8"));

        // 3) 取驗證碼
        let resp = send_idempotent_get(self.client.get(url).headers(headers)
            .timeout(Duration::from_secs(12)))
            .await
            .context("checkcode: GET failed")?;

        let status = resp.status();
        let ct: String = resp
            .headers()
            .get(CONTENT_TYPE)
            .and_then(|v| v.to_str().ok())
            .unwrap_or("")
            .to_string(); // <-- 這裡變成 String，不再借用 resp

        // 現在再讀取 body（會移動 resp）
        let bytes = resp.bytes().await?.to_vec();

        validate_captcha_response(status.as_u16(), &ct, &bytes)
    }

    // 輕微調整：login 也帶上 Referer/Accept（提高通過率）
    pub async fn login(&self, username: &str, password: &str, checkcode: &str) -> Result<()> {
        let _guard = AUTH_REQUEST_LOCK.lock().await;
        let url = format!("{}/login.php", self.load_api_host().await);
        let params = [
            ("username", username),
            ("password", password),
            ("checkcode", checkcode),
            ("usecookie", "315360000"),
            ("action", "login"),
        ];

        let ua = self.load_user_agent().await;
        let mut headers = Self::default_headers_sync(&ua, &self.load_api_host().await);
        // login 是 form，覆蓋 Accept 比較中性
        headers.insert(
            ACCEPT,
            HeaderValue::from_static(
                "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            ),
        );

        let resp = self
            .client
            .post(url)
            .headers(headers)
            .form(&params)
            .send()
            .await?;

        if !resp.status().is_success() {
            return Err(anyhow!("Login failed: HTTP {}", resp.status()));
        }

        let content_type = resp.headers().get(CONTENT_TYPE).and_then(|v| v.to_str().ok()).unwrap_or("").to_string();
        let body = decode_home(resp.bytes().await?, &content_type)?;
        if body.contains("登录成功") || body.contains("登錄成功") {
            Ok(())
        } else {
            Err(anyhow!("{}", login_error_message(&body)))
        }
    }

    // /userdetail.php?charset=gbk
    pub async fn userdetail(&self) -> Result<UserDetail> {
        let url = format!("{}/userdetail.php?charset=gbk", self.load_api_host().await);
        let response = self
            .client
            .get(url)
            .header("User-Agent", self.load_user_agent().await)
            .send()
            .await?;
        if !response.status().is_success() {
            return Err(anyhow!("Login failed: {}", response.status()));
        }

        let text = response.bytes().await?;
        let text = decode_gbk(text)?;
        Self::parse_user_detail(text.as_str())
    }

    pub(crate) fn parse_user_detail(text: &str) -> Result<UserDetail> {
        let mut user_detail = UserDetail::default();
        let html = Html::parse_document(text);
        let tr_selector = Selector::parse("tr[align=left]").unwrap();
        let td_odd_selector = Selector::parse("td.odd").unwrap();
        let td_even_selector = Selector::parse("td.even").unwrap();
        let tr_select = html.select(&tr_selector);
        for x in tr_select.into_iter() {
            let odd_select = x.select(&td_odd_selector).into_iter().next();
            let even_select = x.select(&td_even_selector).next();
            if let Some(odd) = odd_select {
                if let Some(even) = even_select {
                    let title = odd.inner_html();
                    let value = even.inner_html();
                    if title.trim().starts_with("用户ID：") {
                        user_detail.user_id = value.trim().to_string();
                    } else if title.trim().starts_with("用户名：") {
                        user_detail.username = value.trim().to_string();
                    } else if title.trim().starts_with("昵称：") {
                        user_detail.nickname =
                            value.trim().replace("(留空则用户名做昵称)", "").to_string();
                    } else if title.trim().starts_with("等级：") {
                        user_detail.level = value.trim().to_string();
                    } else if title.trim().starts_with("头衔：") {
                        user_detail.title = value.trim().to_string();
                    } else if title.trim().starts_with("性别：") {
                        user_detail.sex = value.trim().to_string();
                    } else if title.trim().starts_with("Email：") {
                        user_detail.email = regex::Regex::new("<a[^>]+>")?
                            .replace(value.trim(), "")
                            .replace("</a>", "")
                            .to_string();
                    } else if title.trim().starts_with("QQ：") {
                        user_detail.qq = value.trim().to_string();
                    } else if title.trim().starts_with("MSN：") {
                        user_detail.msn = regex::Regex::new("<a[^>]+>")?
                            .replace(value.trim(), "")
                            .replace("</a>", "")
                            .to_string();
                    } else if title.trim().starts_with("网站：") {
                        user_detail.web = regex::Regex::new("<a[^>]+>")?
                            .replace(value.trim(), "")
                            .replace("</a>", "")
                            .to_string();
                    } else if title.trim().starts_with("注册日期：") {
                        user_detail.register_date = value.trim().to_string();
                    } else if title.trim().starts_with("贡献值：") {
                        user_detail.contribute_point = value.trim().to_string();
                    } else if title.trim().starts_with("经验值：") {
                        user_detail.experience_value = value.trim().to_string();
                    } else if title.trim().starts_with("现有积分：") {
                        user_detail.holding_points = value.trim().to_string();
                    } else if title.trim().starts_with("最多好友数：") {
                        user_detail.quantity_of_friends = value.trim().to_string();
                    } else if title.trim().starts_with("信箱最多消息数：") {
                        user_detail.quantity_of_mail = value.trim().to_string();
                    } else if title.trim().starts_with("书架最大收藏量：") {
                        user_detail.quantity_of_collection = value.trim().to_string();
                    } else if title.trim().starts_with("每天允许推荐次数：") {
                        user_detail.quantity_of_recommend_daily = value.trim().to_string();
                    } else if title.trim().starts_with("用户签名：") {
                        user_detail.personalized_signature = value.trim().to_string();
                    } else if title.trim().starts_with("个人简介：") {
                        user_detail.personalized_description = value.trim().to_string();
                    }
                }
            }
        }
        Ok(user_detail)
    }

    pub async fn novel_info(&self, aid: &str) -> Result<NovelInfo> {
        let url = format!(
            "{}/modules/article/articleinfo.php?id={aid}&charset=gbk",
            self.load_api_host().await
        );
        let ua = self.load_user_agent().await;
        let headers = Self::default_headers_sync(&ua, &self.load_api_host().await);
        let response = send_idempotent_get(self.client.get(&url).headers(headers)).await?;
        if !response.status().is_success() {
            return Err(anyhow!("Failed to get novel info: {}", response.status()));
        }

        let text = response.bytes().await?;
        let text = decode_gbk(text)?;
        Self::parse_novel_info(text.as_str())
    }

    pub(crate) fn parse_novel_info(text: &str) -> Result<NovelInfo> {
        let mut novel_info = NovelInfo::default();
        //
        let content_selector = Selector::parse("#content").unwrap();
        let table_selector = Selector::parse("table").unwrap();
        let span_selector = Selector::parse("span").unwrap();
        let b_selector = Selector::parse("b").unwrap();
        let tr_selector = Selector::parse("tr").unwrap();
        let td_selector = Selector::parse("td").unwrap();
        let img_selector = Selector::parse("img").unwrap();
        //
        let html = Html::parse_document(text);
        let content = html
            .select(&content_selector)
            .next()
            .ok_or_else(|| anyhow!("Failed to find content"))?;
        let table = content
            .select(&table_selector)
            .next()
            .ok_or_else(|| anyhow!("Failed to find table"))?;

        /*

        val title = table.select("span").eq(0).select("b").eq(0).text()
        val author = table.select("tr").eq(2).select("td").eq(1).text().substring(5)
        val status = table.select("tr").eq(2).select("td").eq(2).text().substring(5)
         */

        let title = table
            .select(&span_selector)
            .next()
            .ok_or_else(|| anyhow!("Failed to find title"))?
            .select(&b_selector)
            .next()
            .ok_or_else(|| anyhow!("Failed to find title"))?
            .text()
            .collect::<String>();
        novel_info.title = title;

        let author = table
            .select(&tr_selector)
            .nth(2)
            .ok_or_else(|| anyhow!("Failed to find author"))?
            .select(&td_selector)
            .nth(1)
            .ok_or_else(|| anyhow!("Failed to find author"))?
            .text()
            .collect::<String>()
            .chars()
            .skip(5)
            .collect();
        novel_info.author = author;

        let status = table
            .select(&tr_selector)
            .nth(2)
            .ok_or_else(|| anyhow!("Failed to find status"))?
            .select(&td_selector)
            .nth(2)
            .ok_or_else(|| anyhow!("Failed to find status"))?
            .text()
            .collect::<String>()
            .chars()
            .skip(5)
            .collect();
        novel_info.status = status;

        let fin_update = if let Some(tr) = table.select(&tr_selector).nth(2) {
            if let Some(td) = tr.select(&td_selector).nth(3) {
                let text = td.text().collect::<String>();
                text.chars().skip(5).collect::<String>()
            } else {
                "".to_string()
            }
        } else {
            "".to_string()
        };
        novel_info.fin_update = fin_update;

        let img_url = content
            .select(&img_selector)
            .next()
            .ok_or_else(|| anyhow!("Failed to find img_url"))?
            .value()
            .attr("src")
            .ok_or_else(|| anyhow!("Failed to find img_url"))?
            .to_string();
        novel_info.img_url = img_url;

        if let Some(table) = content.select(&table_selector).nth(2) {
            if let Some(td) = table.select(&td_selector).nth(1) {
                if let Some(span) = td.select(&span_selector).nth(5) {
                    let text = span.html();
                    novel_info.introduce = text;
                }
            }
        }
        if novel_info.introduce.is_empty() {
            if let Some(table) = content.select(&table_selector).nth(2) {
                if let Some(td) = table.select(&td_selector).nth(1) {
                    if let Some(span) = td.select(&span_selector).nth(3) {
                        let text = span.text().collect::<String>();
                        novel_info.introduce = text.chars().skip(5).collect::<String>();
                    }
                }
            }
        }

        let tag = content
            .select(&table_selector)
            .nth(2)
            .ok_or_else(|| anyhow!("Failed to find tag"))?
            .select(&td_selector)
            .nth(1)
            .ok_or_else(|| anyhow!("Failed to find tag"))?
            .select(&span_selector)
            .next()
            .ok_or_else(|| anyhow!("Failed to find tag"))?
            .text()
            .collect::<String>();
        let tag = tag
            .chars()
            .skip(7)
            .collect::<String>()
            .split(" ")
            .map(|e| e.to_string())
            .collect();
        novel_info.tags = tag;

        if let Some(table) = content.select(&table_selector).nth(2) {
            if let Some(td) = table.select(&td_selector).nth(1) {
                if let Some(_) = td.select(&span_selector).nth(1) {
                    novel_info.is_animated = true;
                }
            }
        }

        Ok(novel_info)
    }

    pub async fn index(&self) -> Result<Vec<HomeBlock>> {
        let api_host = self.load_api_host().await;
        // Request the same canonical home as the site's navigation and WebView.
        // `charset` is a display preference, not a required home API parameter.
        let url = format!("{api_host}/");
        let headers = self.bookcase_headers(&url).await;

        let response = send_idempotent_get(self.client.get(&url).headers(headers.clone()))
            .await
            .with_context(|| format!("GET {url} failed"))?;
        let response = if response.status().as_u16() == 403 {
            // A fresh visit to the same Wenku8 login domain lets the persistent
            // CookieStore retain any session/challenge cookies before one retry.
            let _ = response.bytes().await;
            self.init_session().await?;
            send_idempotent_get(self.client.get(&url).headers(headers))
                .await
                .with_context(|| format!("GET {url} retry after session refresh failed"))?
        } else {
            response
        };

        if !response.status().is_success() {
            let status = response.status();
            let content_type = response
                .headers()
                .get(CONTENT_TYPE)
                .and_then(|value| value.to_str().ok())
                .unwrap_or("")
                .to_string();
            let body = response
                .bytes()
                .await
                .context("Failed to read Wenku8 index error response")?;
            let category = index_error_response_category(status.as_u16(), &content_type, &body);
            return Err(anyhow!("GET {url} failed: HTTP {status} ({category})"));
        }

        let content_type = response
            .headers()
            .get(CONTENT_TYPE)
            .and_then(|value| value.to_str().ok())
            .unwrap_or("")
            .to_string();
        let text = decode_home(response.bytes().await?, &content_type)?;
        Self::parse_index_at(&text, &api_host)
    }

    pub(crate) fn parse_index(text: &str) -> Result<Vec<HomeBlock>> {
        Self::parse_index_at(text, DEFAULT_API_HOST)
    }

    fn parse_index_at(text: &str, api_host: &str) -> Result<Vec<HomeBlock>> {
        let base = reqwest::Url::parse(&format!("{}/", api_host.trim_end_matches('/')))?;
        let html = Html::parse_document(text);
        let block_selector = Selector::parse("#centers .block, div.main .block").unwrap();
        let title_selector = Selector::parse(".blocktitle, h1, h2, h3, h4").unwrap();
        let image_selector = Selector::parse("img").unwrap();
        let anchor_selector = Selector::parse("a").unwrap();
        let mut blocks = Vec::new();
        let mut total_books = 0;

        // Column positions and wrapper depths change when banners are inserted.
        // Identify actual same-site book cards instead of assuming item ordinals.
        for block in html.select(&block_selector).take(128) {
            let Some(title_node) = block.select(&title_selector).next() else {
                continue;
            };
            let Some(title) = clean_home_title(&title_node.text().collect::<String>()) else {
                continue;
            };
            if title.contains("公告")
                || title == "广告"
                || title == "广告推广"
                || title == "文库Telegram群组"
                || title_node
                    .select(&Selector::parse("span.txt").unwrap())
                    .next()
                    .is_some()
            {
                continue;
            }
            let mut covers = Vec::new();
            let mut seen = HashSet::new();
            for image in block.select(&image_selector).take(200) {
                if covers.len() >= 100 || total_books >= 500 {
                    break;
                }
                let Some(img) = home_image_url(image, &base) else {
                    continue;
                };
                let image_anchor = image
                    .ancestors()
                    .filter_map(ElementRef::wrap)
                    .find(|element| element.value().name() == "a");
                // An ad's image must not borrow a neighboring novel's identity.
                if image_anchor.is_some_and(|anchor| {
                    anchor.value().attr("href").is_some() && home_book_url(anchor, &base).is_none()
                }) {
                    continue;
                }
                let direct = image_anchor.and_then(|anchor| home_book_url(anchor, &base));
                let mut matched = None;
                for card in image.ancestors().filter_map(ElementRef::wrap) {
                    if card.id() == block.id() {
                        break;
                    }
                    let mut links = Vec::new();
                    if card.value().name() == "a" {
                        if let Some(book) = home_book_url(card, &base) {
                            links.push((card, book));
                        }
                    }
                    links.extend(card.select(&anchor_selector).filter_map(|anchor| {
                        home_book_url(anchor, &base).map(|book| (anchor, book))
                    }));
                    let ids = links
                        .iter()
                        .map(|(_, (_, aid))| aid)
                        .collect::<HashSet<_>>();
                    if ids.len() != 1 {
                        continue;
                    }
                    let Some((_, (detail_url, aid))) = links.first() else {
                        continue;
                    };
                    if direct.as_ref().is_some_and(|(_, id)| id != aid) {
                        continue;
                    }
                    let name = links
                        .iter()
                        .find_map(|(anchor, _)| {
                            anchor.value().attr("title").and_then(clean_home_title)
                        })
                        .or_else(|| {
                            image
                                .value()
                                .attr("alt")
                                .and_then(clean_home_title)
                                .filter(|name| name != "封面" && name != "小说封面")
                        })
                        .or_else(|| {
                            links.iter().find_map(|(anchor, _)| {
                                clean_home_title(&anchor.text().collect::<String>())
                            })
                        })
                        .or_else(|| {
                            card.select(&anchor_selector)
                                .filter(|anchor| anchor.value().attr("href").is_none())
                                .find_map(|anchor| {
                                    clean_home_title(&anchor.text().collect::<String>())
                                })
                        });
                    if let Some(name) = name {
                        matched = Some(NovelCover {
                            title: name,
                            img: img.clone(),
                            detail_url: detail_url.clone(),
                            aid: aid.clone(),
                        });
                        break;
                    }
                    // A picture link may have a sibling text link for the same
                    // book; continue outward until that name becomes available.
                }
                if let Some(cover) = matched {
                    if seen.insert(cover.aid.clone()) {
                        covers.push(cover);
                        total_books += 1;
                    }
                }
            }
            if !covers.is_empty() {
                blocks.push(HomeBlock {
                    title,
                    list: covers,
                });
            }
        }
        if blocks.is_empty() {
            return Err(anyhow!(
                "Wenku8 home contains no usable book recommendations"
            ));
        }
        Ok(blocks)
    }

    pub async fn tags(&self) -> Result<Vec<TagGroup>> {
        let resp = self
            .client
            .get(format!(
                "{}/modules/article/tags.php?charset=gbk",
                self.load_api_host().await
            ))
            .header("User-Agent", self.load_user_agent().await)
            .send()
            .await?;

        if !resp.status().is_success() {
            return Err(anyhow!("Failed to get tags: HTTP {}", resp.status()));
        }

        let text = resp.bytes().await?;
        let text = decode_gbk(text)?;
        Self::parse_tags(text.as_str())
    }

    pub(crate) fn parse_tags(text: &str) -> Result<Vec<TagGroup>> {
        let mut tag_groups = Vec::new();
        let html = Html::parse_document(text);

        let ul_selector = Selector::parse("ul.ultops").unwrap();
        let li_selector = Selector::parse("li").unwrap();
        let a_selector = Selector::parse("a").unwrap();

        let ul_elements = html.select(&ul_selector);
        let mut group_name = "".to_string();
        let mut tags = Vec::<String>::new();
        for ul in ul_elements {
            let li = ul.select(&li_selector);
            for li in li {
                if li.inner_html().ends_with("Tags：") {
                    if !group_name.is_empty() {
                        tag_groups.push(TagGroup {
                            title: group_name.clone(),
                            tags: tags.clone(),
                        });
                    }
                    group_name = li
                        .inner_html()
                        .replace("Tags：", "")
                        .replace("系", "")
                        .replace("属性", "")
                        .replace("类", "");
                    tags.clear();
                } else {
                    let a = li.select(&a_selector);
                    for a in a {
                        let tag = a.text().collect::<String>();
                        tags.push(tag.clone());
                    }
                }
            }
        }

        Ok(tag_groups)
    }

    ///
    /// v  "0"=按更新查看 , "1"=按热门查看 , "2"=只看已完结 , "3"=只看动画化
    ///
    pub async fn tag_page(
        &self,
        tag: &str,
        v: &str,
        page_number: i32,
    ) -> Result<PageStats<NovelCover>> {
        let url = format!(
            "{}/modules/article/tags.php?t={}&v={}&page={}&charset=gbk",
            self.load_api_host().await,
            gbk_url_encode(tag),
            v,
            page_number,
        );
        let response = self
            .client
            .get(url)
            .header("User-Agent", self.load_user_agent().await)
            .send()
            .await?;
        if !response.status().is_success() {
            return Err(anyhow!("Failed to get tag page: {}", response.status()));
        }

        let text = response.bytes().await?;
        let text = decode_gbk(text)?;
        Self::parse_tag_page(text.as_str())
    }

    pub(crate) fn parse_books(novels: &mut Vec<NovelCover>, html: &Html) -> Result<()> {
        let gird_selector = Selector::parse("table.grid tr td>div").unwrap();
        let img_selector = Selector::parse("div>a>img").unwrap();
        for block in html.select(&gird_selector) {
            for img in block.select(&img_selector) {
                let parent = img
                    .parent()
                    .ok_or_else(|| anyhow!("Failed to find block title"))?;
                if let Element(e) = &parent.value() {
                    if e.name.local.to_string().eq("a") {
                        let parent = ElementRef::wrap(parent).unwrap();
                        let title = parent
                            .value()
                            .attr("title")
                            .ok_or_else(|| anyhow!("Failed to find title"))?
                            .to_string();
                        let mut img = img
                            .value()
                            .attr("src")
                            .ok_or_else(|| anyhow!("Failed to find img"))?
                            .to_string();
                        let detail_url = parent
                            .value()
                            .attr("href")
                            .ok_or_else(|| anyhow!("Failed to find detail_url"))?
                            .to_string();
                        let aid = detail_url
                            .split('/')
                            .last()
                            .ok_or_else(|| anyhow!("Failed to find aid"))?
                            .replace(".htm", "");
                        novels.push(NovelCover {
                            title: title.clone(),
                            img: img.clone(),
                            detail_url: detail_url.clone(),
                            aid: aid.clone(),
                        });
                    }
                }
            }
        }
        Ok(())
    }

    pub(crate) fn parse_page_stats(html: &Html) -> Result<(i32, i32)> {
        let page_stats_selector = Selector::parse("em#pagestats").unwrap();
        let mut current_page = 0;
        let mut max_page = 0;
        for page_stats in html.select(&page_stats_selector) {
            let text = page_stats.text().collect::<String>();
            let split = text.split("/").collect::<Vec<&str>>();
            if let Some(&a) = split.get(0) {
                if let Ok(num) = a.trim().parse::<i32>() {
                    current_page = num;
                }
            }
            if let Some(&a) = split.get(1) {
                if let Ok(num) = a.trim().parse::<i32>() {
                    max_page = num;
                }
            }
        }
        Ok((current_page, max_page))
    }

    pub(crate) fn parse_tag_page(text: &str) -> Result<PageStats<NovelCover>> {
        let mut novels = Vec::new();
        let html = Html::parse_document(text);
        Self::parse_books(&mut novels, &html)?;
        let (current_page, max_page) = Self::parse_page_stats(&html)?;
        Ok(PageStats {
            current_page,
            max_page,
            records: novels,
        })
    }

    pub async fn get_bookshelf(&self) -> Result<Vec<BookshelfItem>> {
        let api_host = self.load_api_host().await;
        let referer = format!("{}/", api_host);
        let headers = self.bookcase_headers(&referer).await;
        let url = format!("{}/modules/article/bookcase.php", api_host);
        let resp = self.client.get(&url).headers(headers).send().await?;

        let status = resp.status();
        let body = resp.bytes().await.unwrap_or_default();
        if !status.is_success() {
            let text = String::from_utf8_lossy(&body);
            if text.contains("Attention Required")
                || text.contains("cf_chl")
                || text.contains("Just a moment")
            {
                return Err(anyhow!("Cloudflare 封鎖了書架請求，請嘗試重新登入後再試"));
            }
            return Err(anyhow!("Failed to get bookshelf: HTTP {}", status));
        }

        let body = decode_gbk(bytes::Bytes::from(body.to_vec()))?;
        let document = Html::parse_document(&body);

        let mut items = Vec::new();
        let row_selector = Selector::parse("tr").unwrap();
        let link_selector = Selector::parse("a").unwrap();

        for row in document.select(&row_selector).skip(1) {
            if let Some(first_link) = row.select(&link_selector).next() {
                let href = first_link.value().attr("href").unwrap_or("");
                if href.contains("/book/") {
                    let id = href.split('/').last().unwrap_or("").replace(".htm", "");
                    let title = first_link.text().collect::<String>();

                    items.push(BookshelfItem {
                        novel: Novel {
                            id: id.clone(),
                            title,
                            author: String::new(),
                            cover_url: format!(
                                "http://img.wenku8.com/image/{}/{}/{}.jpg",
                                id.chars().next().unwrap_or('0'),
                                id,
                                id
                            ),
                            last_chapter: String::new(),
                            tags: Vec::new(),
                        },
                        last_read: String::new(),
                    });
                }
            }
        }

        Ok(items)
    }

    pub async fn download_image(&self, url: &str) -> Result<Vec<u8>> {
        // The site still emits HTTP cover URLs. Use TLS for its image CDN,
        // keeping the original URL as the disk-cache key for existing users.
        let mut image_url = reqwest::Url::parse(url)?;
        if image_url.scheme() == "http"
            && matches!(
                image_url.host_str(),
                Some("img.wenku8.com" | "img.wenku8.net" | "img.wenku8.cc")
            )
        {
            image_url
                .set_scheme("https")
                .map_err(|_| anyhow!("Invalid image scheme"))?;
        }
        let request = self.client.get(image_url)
            .header("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.124 Safari/537.36")
            .header("Referer", "https://www.wenku8.net/")
            .timeout(Duration::from_secs(25));
        let response = send_idempotent_get(request).await?;

        if !response.status().is_success() {
            return Err(anyhow!("Failed to download image: {}", response.status()));
        }

        Ok(response.bytes().await?.to_vec())
    }

    pub(crate) fn parse_reader(text: &str) -> Result<Vec<Volume>> {
        let mut volumes = Vec::new();
        let html = Html::parse_document(text);
        let table_selector = Selector::parse("table.css").unwrap();
        let tr_selector = Selector::parse("tr").unwrap();
        let vcss_td_selector = Selector::parse("td.vcss").unwrap();
        let ccss_td_a_selector = Selector::parse("td.ccss>a").unwrap();

        let mut vid = "".to_string();
        let mut vtitle = "".to_string();
        let mut chapters = Vec::<Chapter>::new();

        let table = html
            .select(&table_selector)
            .next()
            .ok_or_else(|| anyhow!("Failed to find table"))?;

        for tr in table.select(&tr_selector) {
            if let Some(td) = tr.select(&vcss_td_selector).next() {
                if !"".eq(vid.as_str()) {
                    volumes.push(Volume {
                        id: vid,
                        title: vtitle,
                        chapters,
                    });
                }
                vid = td.value().attr("vid").unwrap_or("").to_string();
                vtitle = td.text().collect();
                chapters = vec![];
            } else {
                for a in tr.select(&ccss_td_a_selector) {
                    let title = a.text().collect::<String>();
                    let url = a.value().attr("href").unwrap_or("");
                    let url = url::Url::parse(url)?;
                    let pairs = url.query_pairs();
                    let pairs_map = pairs
                        .into_owned()
                        .collect::<std::collections::HashMap<_, _>>();
                    let cid = pairs_map
                        .get("cid")
                        .ok_or_else(|| anyhow!("Failed to find cid"))?
                        .to_string();
                    let aid = pairs_map
                        .get("aid")
                        .ok_or_else(|| anyhow!("Failed to find aid"))?
                        .to_string();
                    chapters.push(Chapter {
                        title,
                        url: url.to_string(),
                        cid,
                        aid,
                    });
                }
            }
        }
        if !"".eq(vid.as_str()) {
            volumes.push(Volume {
                id: vid,
                title: vtitle,
                chapters,
            });
        }

        Ok(volumes)
    }

    pub async fn novel_reader(&self, aid: &str) -> Result<Vec<Volume>> {
        let url = format!(
            "{}/modules/article/reader.php?aid={aid}&charset=gbk",
            self.load_api_host().await
        );
        let ua = self.load_user_agent().await;
        let headers = Self::default_headers_sync(&ua, &self.load_api_host().await);
        let response = send_idempotent_get(self.client.get(url).headers(headers)).await?;
        if !response.status().is_success() {
            return Err(anyhow!("Failed to get novel reader: {}", response.status()));
        }

        let text = response.bytes().await?;
        let text = decode_gbk(text)?;
        Self::parse_reader(text.as_str())
    }

    pub async fn c_content(&self, aid: &str, cid: &str) -> Result<String> {
        let aid_num: u64 = aid.parse().unwrap_or(0);
        let sub_dir = aid_num / 1000;
        let url = format!(
            "{}/novel/{}/{}/{}.htm",
            self.load_api_host().await,
            sub_dir,
            aid,
            cid
        );
        let ua = self.load_user_agent().await;
        let headers = Self::default_headers_sync(&ua, &self.load_api_host().await);
        let response = send_idempotent_get(self.client.get(&url).headers(headers)).await?;
        if !response.status().is_success() {
            return Err(anyhow!("Failed to get novel reader: {}", response.status()));
        }
        let bytes = response.bytes().await?;
        let html = decode_gbk(bytes)?;

        Self::parse_chapter_content(&html, &url)
    }

    pub(crate) fn parse_chapter_content(html: &str, page_url: &str) -> Result<String> {
        let document = Html::parse_document(&html);
        let content_selector = Selector::parse("#content").unwrap();
        let content = document
            .select(&content_selector)
            .next()
            .ok_or_else(|| anyhow!("Failed to find #content in chapter page"))?;

        // Build reader content: skip the watermark, preserve line breaks, and
        // encode illustrations using the marker understood by the Flutter reader.
        let mut result = String::new();
        Self::extract_content_text(content, &mut result, page_url);
        Ok(result.trim().to_string())
    }

    fn extract_content_text(element: ElementRef, buf: &mut String, page_url: &str) {
        use scraper::Node;
        for child in element.children() {
            match child.value() {
                Node::Text(t) => {
                    let s = t.text.replace('\u{a0}', " "); // &nbsp; → space
                    buf.push_str(&s);
                }
                Node::Element(e) => {
                    let name = e.name();
                    if name == "ul" {
                        // skip watermark block
                        continue;
                    }
                    if name == "br" {
                        buf.push('\n');
                        continue;
                    }
                    let child_ref = ElementRef::wrap(child).unwrap();
                    if name == "img" {
                        if let Some(src) = child_ref
                            .value()
                            .attr("src")
                            .or_else(|| child_ref.value().attr("data-src"))
                        {
                            let image_url = url::Url::parse(page_url)
                                .and_then(|base| base.join(src.trim()))
                                .map(|value| value.to_string())
                                .unwrap_or_else(|_| src.trim().to_string());
                            if !image_url.is_empty() {
                                buf.push_str("\n<!--image-->");
                                buf.push_str(&image_url);
                                buf.push_str("<!--image-->\n");
                            }
                        }
                        continue;
                    }
                    Self::extract_content_text(child_ref, buf, page_url);
                }
                _ => {}
            }
        }
    }

    pub async fn toplist(&self, sort: &str, page: i32) -> Result<PageStats<NovelCover>> {
        let url = format!(
            "{}/modules/article/toplist.php?sort={sort}&page={page}&charset=gbk",
            self.load_api_host().await
        );
        let response = send_idempotent_get(
            self.client
                .get(url)
                .header("User-Agent", self.load_user_agent().await),
        )
        .await?;
        if !response.status().is_success() {
            return Err(anyhow!("Failed to get toplist: {}", response.status()));
        }

        let text = response.bytes().await?;
        let text = decode_gbk(text)?;
        Self::parse_toplist(text.as_str())
    }

    pub(crate) fn parse_toplist(text: &str) -> Result<PageStats<NovelCover>> {
        Self::parse_tag_page(text)
    }

    pub async fn articlelist(&self, fullflag: i32, page: i32) -> Result<PageStats<NovelCover>> {
        let url = format!(
            "{}/modules/article/articlelist.php?fullflag={fullflag}&page={page}&charset=gbk",
            self.load_api_host().await
        );
        let response = send_idempotent_get(
            self.client
                .get(url)
                .header("User-Agent", self.load_user_agent().await),
        )
        .await?;
        if !response.status().is_success() {
            return Err(anyhow!("Failed to get article list: {}", response.status()));
        }

        let text = response.bytes().await?;
        let text = decode_gbk(text)?;
        Self::parse_articlelist(text.as_str())
    }

    pub(crate) fn parse_articlelist(text: &str) -> Result<PageStats<NovelCover>> {
        Self::parse_tag_page(text)
    }

    async fn search_index_page(&self, page: i32) -> Result<PageStats<SearchIndexEntry>> {
        let url = format!(
            // The completed-book catalog is the public Wenku8 endpoint. The
            // ongoing-book variant redirects to login for anonymous clients.
            "{}/modules/article/articlelist.php?fullflag=1&page={page}&charset=gbk",
            self.load_api_host().await
        );
        let response = send_idempotent_get(
            self.client
                .get(url)
                .header("User-Agent", self.load_user_agent().await),
        )
        .await?;
        if !response.status().is_success() {
            return Err(anyhow!(
                "Failed to build local search index: {}",
                response.status()
            ));
        }

        let text = decode_gbk(response.bytes().await?)?;
        Self::parse_search_index_page(&text)
    }

    pub(crate) fn parse_search_index_page(text: &str) -> Result<PageStats<SearchIndexEntry>> {
        let html = Html::parse_document(text);
        let block_selector = Selector::parse("table.grid tr td>div").unwrap();
        let image_selector = Selector::parse("div>a>img").unwrap();
        let author_regex = Regex::new(r"作者[:：]\s*([^/\r\n]+)").unwrap();
        let mut records = Vec::new();

        for block in html.select(&block_selector) {
            let Some(image) = block.select(&image_selector).next() else {
                continue;
            };
            let Some(parent) = image.parent().and_then(ElementRef::wrap) else {
                continue;
            };
            if parent.value().name() != "a" {
                continue;
            }

            let Some(title) = parent.value().attr("title") else {
                continue;
            };
            let Some(image_url) = image.value().attr("src") else {
                continue;
            };
            let Some(detail_url) = parent.value().attr("href") else {
                continue;
            };
            let Some(aid) = detail_url
                .split('/')
                .last()
                .map(|value| value.trim_end_matches(".htm"))
            else {
                continue;
            };

            let block_text = block.text().collect::<String>();
            let author = author_regex
                .captures(&block_text)
                .and_then(|captures| captures.get(1))
                .map(|value| value.as_str().trim().to_string())
                .unwrap_or_default();
            records.push(SearchIndexEntry {
                cover: NovelCover {
                    title: title.trim().to_string(),
                    img: image_url.to_string(),
                    detail_url: detail_url.to_string(),
                    aid: aid.to_string(),
                },
                author,
            });
        }

        let (current_page, max_page) = Self::parse_page_stats(&html)?;
        if current_page <= 0 || max_page <= 0 || records.is_empty() {
            return Err(anyhow!(
                "Failed to parse local search index page (possibly blocked by Cloudflare)"
            ));
        }
        Ok(PageStats {
            current_page,
            max_page,
            records,
        })
    }

    async fn rebuild_search_index(&self) -> Result<SearchIndexCache> {
        let first_page = self.search_index_page(1).await?;
        let max_page = first_page.max_page.clamp(1, 500);
        let mut pages = stream::iter(2..=max_page)
            .map(|page| async move { self.search_index_page(page).await })
            .buffer_unordered(4)
            .try_collect::<Vec<_>>()
            .await?;
        pages.sort_by_key(|page| page.current_page);

        let mut entries = first_page.records;
        for page in pages {
            entries.extend(page.records);
        }

        let mut seen = HashSet::new();
        entries.retain(|entry| seen.insert(entry.cover.aid.clone()));
        if entries.is_empty() {
            return Err(anyhow!("The local search index is empty"));
        }

        Ok(SearchIndexCache {
            updated_at: chrono::Utc::now().timestamp(),
            entries,
        })
    }

    async fn load_search_index(&self) -> Result<SearchIndexCache> {
        let now = chrono::Utc::now().timestamp();
        if let Some(cache) = SEARCH_INDEX_CACHE.read().await.as_ref() {
            if now - cache.updated_at < SEARCH_INDEX_TTL_SECONDS {
                return Ok(cache.clone());
            }
        }

        let _refresh_guard = SEARCH_INDEX_REFRESH_LOCK.lock().await;
        if let Some(cache) = SEARCH_INDEX_CACHE.read().await.as_ref() {
            if now - cache.updated_at < SEARCH_INDEX_TTL_SECONDS {
                return Ok(cache.clone());
            }
        }

        let persisted = crate::api::database::load_property(SEARCH_INDEX_PROPERTY.to_string())
            .await
            .unwrap_or_default();
        let persisted_cache = if persisted.is_empty() {
            None
        } else {
            serde_json::from_str::<SearchIndexCache>(&persisted).ok()
        };
        if let Some(cache) = persisted_cache.as_ref() {
            *SEARCH_INDEX_CACHE.write().await = Some(cache.clone());
            if now - cache.updated_at < SEARCH_INDEX_TTL_SECONDS {
                return Ok(cache.clone());
            }
        }

        match self.rebuild_search_index().await {
            Ok(cache) => {
                let serialized = serde_json::to_string(&cache)?;
                crate::api::database::save_property(SEARCH_INDEX_PROPERTY.to_string(), serialized)
                    .await?;
                *SEARCH_INDEX_CACHE.write().await = Some(cache.clone());
                Ok(cache)
            }
            Err(error) => {
                if let Some(cache) = persisted_cache {
                    Ok(cache)
                } else {
                    Err(error)
                }
            }
        }
    }

    pub async fn search_compatible(
        &self,
        search_type: &str,
        search_key: &str,
        page: i32,
    ) -> Result<PageStats<NovelCover>> {
        let cache = tokio::time::timeout(Duration::from_secs(120), self.load_search_index())
            .await
            .map_err(|_| anyhow!("搜索数据加载超时，请检查网络后重试"))??;
        let normalized_key = search_key.trim().to_lowercase();
        let mut matches = cache
            .entries
            .iter()
            .filter(|entry| {
                let value = if search_type == "author" {
                    &entry.author
                } else {
                    &entry.cover.title
                };
                value.to_lowercase().contains(&normalized_key)
            })
            .map(|entry| entry.cover.clone())
            .collect::<Vec<_>>();

        let max_page = ((matches.len() + SEARCH_FALLBACK_PAGE_SIZE - 1) / SEARCH_FALLBACK_PAGE_SIZE)
            .max(1) as i32;
        let current_page = page.max(1).min(max_page);
        let start = (current_page as usize - 1) * SEARCH_FALLBACK_PAGE_SIZE;
        let end = (start + SEARCH_FALLBACK_PAGE_SIZE).min(matches.len());
        let records = if start < matches.len() {
            matches.drain(start..end).collect()
        } else {
            Vec::new()
        };

        Ok(PageStats {
            current_page,
            max_page,
            records,
        })
    }

    pub async fn add_bookshelf(&self, aid: &str) -> Result<()> {
        let api_host = self.load_api_host().await;
        let url = format!(
            "{}/modules/article/addbookcase.php?bid={aid}&charset=gbk",
            api_host
        );
        // 使用小說頁面作為 Referer
        let referer = format!("{}/book/{}.htm", api_host, aid);
        let headers = self.bookcase_headers(&referer).await;

        // 使用不跟隨 redirect 的臨時客戶端：
        // addbookcase.php 成功後會 302 redirect 到 bookcase.php
        // 但 bookcase.php 被 Cloudflare 封鎖，所以我們在 302 時就直接返回成功
        let temp_client = reqwest::Client::builder()
            .cookie_provider(Arc::clone(crate::COOKIE_STORE.deref()))
            .redirect(reqwest::redirect::Policy::none())
            .gzip(true)
            .build()?;

        let response = temp_client.get(&url).headers(headers).send().await?;

        let status = response.status();

        // 302 = 加入成功，wenku8 重定向到書架頁
        if status.as_u16() == 302 {
            return Ok(());
        }

        if !status.is_success() {
            return Err(anyhow!("Failed to add bookshelf: HTTP {}", status));
        }

        let text = response.bytes().await?;
        let text = decode_gbk(text)?;
        if text.contains("处理成功") || text.contains("已经在您的书架") {
            Ok(())
        } else {
            // 從 HTML 中提取錯誤原因
            let doc = Html::parse_document(&text);
            let sel = Selector::parse(".blockcontent").unwrap();
            let msg = doc
                .select(&sel)
                .next()
                .map(|e| e.text().collect::<Vec<_>>().join("").trim().to_string())
                .unwrap_or_else(|| text.clone());
            Err(anyhow!("Failed to add bookshelf: {}", msg))
        }
    }

    pub async fn bookcase_list(&self) -> Result<Vec<Bookcase>> {
        // 先訪問首頁，確保 session cookie 已建立（避免 CF 403）
        let _ = self.init_session().await;
        let api_host = self.load_api_host().await;
        // bookcase.php 不支持 charset；附加该参数会直接触发 Cloudflare 403。
        let url = format!("{}/modules/article/bookcase.php?classid=0", api_host);
        let referer = format!("{}/", api_host);
        let headers = self.bookcase_headers(&referer).await;
        let response = send_idempotent_get(self.client.get(url).headers(headers)).await?;
        let status = response.status();
        let body = response
            .bytes()
            .await
            .context("Failed to read bookcase list response")?;
        let category = index_error_response_category(status.as_u16(), "text/html", &body);
        if !status.is_success() {
            return Err(anyhow!("書架請求失敗 [HTTP {}] ({})", status, category));
        }
        // 200 但可能是 CF challenge 頁面
        if index_error_response_category(403, "text/html", &body)
            == "Cloudflare challenge/block HTML"
        {
            return Err(anyhow!("Cloudflare Challenge [HTTP {}]", status));
        }

        let text = decode_gbk(bytes::Bytes::from(body.to_vec()))?;
        Self::parse_bookcase_list(text.as_str())
    }

    pub(crate) fn parse_bookcase_list(text: &str) -> Result<Vec<Bookcase>> {
        let mut bookcase_list = Vec::new();

        let option_selector = Selector::parse("select[name=classlist] option").unwrap();
        let html = Html::parse_document(text);

        for option in html.select(&option_selector) {
            let value = option.value().attr("value").unwrap_or("");
            let text = option.text().collect::<String>();
            bookcase_list.push(Bookcase {
                id: value.to_string(),
                title: text.to_string(),
            });
        }

        Ok(bookcase_list)
    }

    pub async fn book_in_case(&self, case_id: &str) -> Result<BookcaseDto> {
        let api_host = self.load_api_host().await;
        let url = format!(
            "{}/modules/article/bookcase.php?classid={case_id}",
            api_host
        );
        let referer = format!("{}/modules/article/bookcase.php", api_host);
        let headers = self.bookcase_headers(&referer).await;
        let response = send_idempotent_get(self.client.get(url).headers(headers)).await?;
        let status = response.status();
        let body = response
            .bytes()
            .await
            .context("Failed to read bookcase response")?;
        if !status.is_success() {
            let text = String::from_utf8_lossy(&body);
            if text.contains("Attention Required")
                || text.contains("cf_chl")
                || text.contains("Just a moment")
            {
                return Err(anyhow!("Cloudflare 封鎖了書架請求，請嘗試重新登入後再試"));
            }
            return Err(anyhow!("Failed to get book in case: {}", text));
        }

        let text = decode_gbk(bytes::Bytes::from(body.to_vec()))?;
        Self::parse_book_in_case(text.as_str())
    }

    pub(crate) fn parse_book_in_case(text: &str) -> Result<BookcaseDto> {
        let mut novels = Vec::new();

        let checkbox_selector = Selector::parse("td.odd>input[type=checkbox]").unwrap();
        let a_selector = Selector::parse("a").unwrap();

        let html = Html::parse_document(text);
        for checkbox in html.select(&checkbox_selector) {
            let parent = checkbox.parent().unwrap();
            if let Element(e) = &parent.value() {
                if e.name.local.to_string().eq("td") {
                    let mut aid = "".to_string();
                    let mut bid = "".to_string();
                    let mut title = "".to_string();
                    let mut author = "".to_string();
                    let mut cid = "".to_string();
                    let mut chapter_name = "".to_string();

                    let parent =
                        ElementRef::wrap(parent).with_context(|| "Failed to wrap parent")?;

                    let next = parent
                        .next_sibling()
                        .with_context(|| "Failed to find next sibling element")?;

                    let next = next
                        .next_sibling()
                        .with_context(|| "Failed to wrap next sibling")?;

                    let next =
                        ElementRef::wrap(next).with_context(|| "Failed to wrap next sibling")?;

                    let a = next
                        .select(&a_selector)
                        .next()
                        .ok_or_else(|| anyhow!("Failed to find a"))?;
                    let href = a.value().attr("href").unwrap_or("");
                    let href = url::Url::parse(href)?;
                    // https://www.wenku8.net/modules/article/readbookcase.php?aid=2070&bid=11249875
                    let pairs = href.query_pairs();
                    let pairs_map = pairs
                        .into_owned()
                        .collect::<std::collections::HashMap<_, _>>();
                    if let Some(aid_value) = pairs_map.get("aid") {
                        aid = aid_value.to_string();
                    }
                    if let Some(bid_value) = pairs_map.get("bid") {
                        bid = bid_value.to_string();
                    }
                    title = a.text().collect::<String>();
                    let next = next
                        .next_sibling()
                        .ok_or_else(|| anyhow!("Failed to find next sibling"))?;
                    let next = next
                        .next_sibling()
                        .with_context(|| "Failed to wrap next sibling")?;
                    let next =
                        ElementRef::wrap(next).with_context(|| "Failed to wrap next sibling")?;
                    let a = next
                        .select(&a_selector)
                        .next()
                        .ok_or_else(|| anyhow!("Failed to find a"))?;
                    author = a.text().collect::<String>();
                    let next = next
                        .next_sibling()
                        .ok_or_else(|| anyhow!("Failed to find next sibling"))?;

                    let next = next
                        .next_sibling()
                        .with_context(|| "Failed to wrap next sibling")?;
                    let next =
                        ElementRef::wrap(next).with_context(|| "Failed to wrap next sibling")?;
                    let a = next
                        .select(&a_selector)
                        .next()
                        .ok_or_else(|| anyhow!("Failed to find a"))?;
                    let href = a.value().attr("href").unwrap_or("");
                    let href = url::Url::parse(href)?;
                    let pairs = href.query_pairs();
                    let pairs_map = pairs
                        .into_owned()
                        .collect::<std::collections::HashMap<_, _>>();
                    if let Some(cid_value) = pairs_map.get("cid") {
                        cid = cid_value.to_string();
                    }
                    chapter_name = a.text().collect::<String>();
                    novels.push(BookcaseItem {
                        aid,
                        bid,
                        title,
                        author,
                        cid,
                        chapter_name,
                    });
                }
            }
        }

        let mut tip: &str = "";

        // 您的书架可收藏 300 本，已收藏 7 本 regex
        let re = Regex::new(r"您的书架可收藏 (\d+) 本，已收藏 (\d+) 本").unwrap();
        if let Some(caps) = re.captures(text) {
            tip = caps.get(0).unwrap().as_str();
        }

        Ok(BookcaseDto {
            items: novels,
            tip: tip.to_string(),
        })
    }

    pub async fn delete_bookcase(&self, delid: &str) -> Result<()> {
        let api_host = self.load_api_host().await;
        let url = format!("{}/modules/article/bookcase.php?delid={delid}", api_host);
        let referer = format!("{}/modules/article/bookcase.php", api_host);
        let headers = self.bookcase_headers(&referer).await;
        // 刪除後也會 302 redirect，用 no-redirect 客戶端
        let temp_client = reqwest::Client::builder()
            .cookie_provider(Arc::clone(crate::COOKIE_STORE.deref()))
            .redirect(reqwest::redirect::Policy::none())
            .gzip(true)
            .build()?;
        let response = temp_client.get(url).headers(headers).send().await?;
        let status = response.status();
        if status.as_u16() == 302 || status.is_success() {
            Ok(())
        } else {
            let text = response.bytes().await.unwrap_or_default();
            let text = String::from_utf8_lossy(&text);
            Err(anyhow!("Failed to delete bookcase: {}", text))
        }
    }

    pub async fn move_bookcase(
        &self,
        ids: Vec<String>,
        old_classid: String,
        new_classid: String,
    ) -> Result<()> {
        let api_host = self.load_api_host().await;
        let url = format!("{}/modules/article/bookcase.php", api_host);
        let referer = format!("{}/modules/article/bookcase.php", api_host);
        let headers = self.bookcase_headers(&referer).await;
        let mut params = vec![];
        for id in ids {
            params.push(("checkid[]", id));
        }
        params.push(("classlist", old_classid.clone()));
        params.push(("checkall", "checkall".to_string()));
        params.push(("newclassid", new_classid));
        params.push(("classid", old_classid));

        // move 也是 POST 後 302 redirect
        let temp_client = reqwest::Client::builder()
            .cookie_provider(Arc::clone(crate::COOKIE_STORE.deref()))
            .redirect(reqwest::redirect::Policy::none())
            .gzip(true)
            .build()?;
        let response = temp_client
            .post(url)
            .headers(headers)
            .form(&params)
            .send()
            .await?;
        let status = response.status();
        if status.as_u16() == 302 || status.is_success() {
            Ok(())
        } else {
            let text = response.bytes().await.unwrap_or_default();
            let text = decode_gbk(text)?;
            Err(anyhow!("Failed to move bookcase: {}", text))
        }
    }

    // search_type: articlename author
    pub async fn search(
        &self,
        search_type: &str,
        search_key: &str,
        page: i32,
    ) -> Result<PageStats<NovelCover>> {
        let search_key = gbk_url_encode(search_key);
        let url = format!(
            "{}/modules/article/search.php?searchtype={search_type}&searchkey={search_key}&page={page}&charset=gbk",self.load_api_host().await
        );
        let response = self
            .client
            .get(url)
            .header("User-Agent", self.load_user_agent().await)
            .send()
            .await?;
        if !response.status().is_success() {
            return Err(anyhow!(
                "Failed to get search result: {}",
                response.status()
            ));
        }

        let text = response.bytes().await?;
        let text = decode_gbk(text)?;
        Self::parse_search(text.as_str())
    }

    pub(crate) fn parse_search(text: &str) -> Result<PageStats<NovelCover>> {
        Self::parse_tag_page(text)
    }

    pub async fn sign(&self) -> Result<String> {
        let url = format!("{APP_HOST}/api.php");
        let params = [
            (
                "request",
                base64::prelude::BASE64_STANDARD.encode(format!("action=block&do=sign").as_bytes()),
            ),
            ("appver", "1.21".to_string()),
            ("timestamp", chrono::Utc::now().timestamp().to_string()),
        ];
        let response = self
            .client
            .post(url)
            .header("User-Agent", self.load_user_agent().await)
            .form(&params)
            .send()
            .await?;
        if !response.status().is_success() {
            return Err(anyhow!("Failed to get novel reader: {}", response.status()));
        }
        let text = response.text().await?;
        Ok(text)
    }

    pub async fn reviews(&self, aid: &str, page_number: i32) -> Result<PageStats<Review>> {
        let url = format!(
            "{}/modules/article/reviews.php?aid={aid}&page={page_number}&charset=gbk",
            self.load_api_host().await
        );
        let response = self
            .client
            .get(url)
            .header("User-Agent", self.load_user_agent().await)
            .send()
            .await?;
        if !response.status().is_success() {
            return Err(anyhow!("Failed to delete bookcase: {}", response.status()));
        }

        let code = response.status();
        let text = response.bytes().await?;
        let text = decode_gbk(text)?;
        if code.is_success() {
            Self::parse_reviews(text.as_str())
        } else {
            Err(anyhow!("Failed to load reviews: {}", text))
        }
    }

    pub fn parse_reviews(text: &str) -> Result<PageStats<Review>> {
        let html = Html::parse_document(text);
        let table_selector = Selector::parse("#content table.grid").unwrap();
        let tr_selector = Selector::parse("tr").unwrap();
        let td_selector: Selector = Selector::parse("td").unwrap();
        let a_selector: Selector = Selector::parse("a").unwrap();

        let mut reviews = Vec::new();

        let table = html.select(&table_selector);
        for table in table {
            for tr in table.select(&tr_selector).into_iter().skip(2) {
                let mut review = Review::default();
                let tds = tr.select(&td_selector);
                let mut l = 0;
                for td in tds {
                    match l {
                        0 => {
                            for a in td.select(&a_selector) {
                                if let Some(href) = a.attr("href") {
                                    if let Some(find) = href.find("=") {
                                        review.rid = href[find + 1..].to_string();
                                    }
                                }
                                review.content = a.inner_html();
                            }
                        }
                        1 => {
                            let regex = regex::Regex::new(r#"(\d+)/"#).unwrap();
                            let t = td.inner_html();
                            if let Some(caps) = regex.captures(t.as_str()) {
                                if let Some(matched) = caps.get(1) {
                                    if let Ok(i) = matched.as_str().parse() {
                                        review.reply_count = i;
                                    }
                                }
                            }
                        }
                        2 => {
                            for a in td.select(&a_selector) {
                                if let Some(href) = a.attr("href") {
                                    if let Some(find) = href.find("=") {
                                        review.uid = href[find + 1..].to_string();
                                    }
                                }
                                review.uname = a.inner_html();
                            }
                        }
                        3 => {
                            review.time = td.inner_html().replace("<!---->", "").to_string();
                        }
                        _ => {}
                    }
                    l += 1;
                }
                reviews.push(review);
            }
            break;
        }

        let (current_page, max_page) = Self::parse_page_stats(&html)?;
        Ok(PageStats {
            current_page,
            max_page,
            records: reviews,
        })
    }
}

#[cfg(test)]
mod index_request_tests {
    use super::*;
    use reqwest::cookie::CookieStore;
    use reqwest::header::HeaderValue;
    use std::collections::HashMap;
    use std::sync::{Arc, Mutex};
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    use tokio::net::{TcpListener, TcpStream};

    #[test]
    fn captcha_rejects_html_empty_truncated_or_denied_responses() {
        use image::ImageOutputFormat;
        let mut png = std::io::Cursor::new(Vec::new());
        image::DynamicImage::new_rgba8(120, 40).write_to(&mut png, ImageOutputFormat::Png).unwrap();
        let bytes = png.into_inner();
        assert!(validate_captcha_response(200, "image/png", &bytes).is_ok());
        assert!(validate_captcha_response(403, "text/html", b"<html>Just a moment</html>").unwrap_err().to_string().contains("403"));
        assert!(validate_captcha_response(200, "image/png", b"<html>login form</html>").is_err());
        assert!(validate_captcha_response(200, "image/png", &bytes[..bytes.len()/2]).is_err());
        assert!(validate_captcha_response(200, "image/png", &[]).is_err());
        assert!(validate_captcha_response(200, "text/html", &bytes).is_err());
    }

    #[test]
    fn auth_headers_use_configured_origin_and_login_errors_are_bounded() {
        let headers = Wenku8Client::default_headers_sync("", "https://alt.wenku8.net");
        assert_eq!(headers[REFERER], "https://alt.wenku8.net/login.php");
        assert!(headers[ACCEPT].to_str().unwrap().contains("text/html"));
        assert_eq!(login_error_message("fixture 验证码错误 extra account controls"), "验证码错误");
        assert_eq!(login_error_message("unrecognized sensitive body fixture"), "登录结果未能确认，请打开站点查看。");
    }

    #[derive(Default)]
    struct MemoryCookieStore(Mutex<HashMap<String, String>>);

    impl CookieStore for MemoryCookieStore {
        fn set_cookies(
            &self,
            cookie_headers: &mut dyn Iterator<Item = &HeaderValue>,
            _url: &reqwest::Url,
        ) {
            let mut cookies = self.0.lock().unwrap();
            for header in cookie_headers {
                if let Some(pair) = header
                    .to_str()
                    .ok()
                    .and_then(|value| value.split(';').next())
                    .and_then(|value| value.split_once('='))
                {
                    cookies.insert(pair.0.trim().to_string(), pair.1.trim().to_string());
                }
            }
        }

        fn cookies(&self, _url: &reqwest::Url) -> Option<HeaderValue> {
            let cookies = self.0.lock().unwrap();
            let value = cookies
                .iter()
                .map(|(name, value)| format!("{name}={value}"))
                .collect::<Vec<_>>()
                .join("; ");
            if value.is_empty() {
                None
            } else {
                HeaderValue::from_str(&value).ok()
            }
        }
    }

    async fn read_request(stream: &mut TcpStream) -> String {
        let mut request = Vec::new();
        let mut buffer = [0_u8; 1024];
        loop {
            let read = stream.read(&mut buffer).await.unwrap();
            if read == 0 {
                break;
            }
            request.extend_from_slice(&buffer[..read]);
            if request.windows(4).any(|window| window == b"\r\n\r\n") {
                break;
            }
        }
        String::from_utf8_lossy(&request).to_string()
    }

    async fn write_response(stream: &mut TcpStream, status: &str, extra: &str, body: &str) {
        let response = format!(
            "HTTP/1.1 {status}\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: {}\r\nConnection: close\r\n{extra}\r\n{body}",
            body.len()
        );
        stream.write_all(response.as_bytes()).await.unwrap();
    }

    #[tokio::test]
    async fn index_refreshes_same_host_session_once_after_a_403_and_preserves_cookies() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let host = format!("http://{}", listener.local_addr().unwrap());
        let requests = Arc::new(Mutex::new(Vec::<String>::new()));
        let captured = Arc::clone(&requests);
        let server = tokio::spawn(async move {
            for number in 0..4 {
                let (mut stream, _) = listener.accept().await.unwrap();
                let request = read_request(&mut stream).await;
                captured.lock().unwrap().push(request.clone());
                let path = request.lines().next().unwrap_or_default();
                if number == 0 {
                    assert!(path.starts_with("GET / "));
                    write_response(
                        &mut stream,
                        "403 Forbidden",
                        "Set-Cookie: cf_clearance=verified; Path=/\r\n",
                        "<html>__cf_chl_tk=challenge</html>",
                    )
                    .await;
                } else if number == 1 {
                    assert!(path.starts_with("GET / "));
                    write_response(&mut stream, "200 OK", "", "<html></html>").await;
                } else if number == 2 {
                    assert!(path.starts_with("GET /login.php "));
                    write_response(&mut stream, "200 OK", "", "<html></html>").await;
                } else {
                    assert!(path.starts_with("GET / "));
                    write_response(
                        &mut stream,
                        "200 OK",
                        "",
                        "<div id=centers><div class=block><div class=blocktitle>推荐</div><div><a href='/book/101.htm'><img src='http://img1.wenku8.com/image/0/101/101s.jpg'></a><a href='/book/101.htm'>正常书目</a></div></div></div>",
                    )
                    .await;
                }
            }
        });

        let cookie_store = Arc::new(MemoryCookieStore::default());
        cookie_store
            .0
            .lock()
            .unwrap()
            .insert("jieqiUserInfo".into(), "saved-account-session".into());
        let client = Client::builder()
            .cookie_provider(cookie_store)
            .build()
            .unwrap();
        let w8 = Wenku8Client {
            client,
            user_agent: RwLock::new("Dalvik/2.1.0 (Linux; U; Android 15)".into()),
            api_host: RwLock::new(host.clone()),
        };

        let blocks = w8.index().await.unwrap();
        assert_eq!(blocks.len(), 1);
        assert_eq!(blocks[0].list[0].title, "正常书目");
        server.await.unwrap();

        let requests = requests.lock().unwrap();
        assert_eq!(requests.len(), 4);
        assert!(requests[0].contains(&format!("Referer: {host}/")));
        assert!(requests[1].contains(&format!("Referer: {host}/")));
        assert!(requests[2].contains(&format!("Referer: {host}/login.php")));
        assert!(requests[1].contains("jieqiUserInfo=saved-account-session"));
        assert!(requests[2].contains("jieqiUserInfo=saved-account-session"));
        assert!(requests[3].contains("jieqiUserInfo=saved-account-session"));
        assert!(requests[3].contains("cf_clearance=verified"));
        for request in requests.iter() {
            let lower = request.to_ascii_lowercase();
            assert!(lower.contains("accept: text/html,application/xhtml+xml"));
            assert!(!request.contains("charset=gbk"));
        }
    }

    #[test]
    fn index_http_403_category_distinguishes_cloudflare_challenge_from_generic_denial() {
        assert_eq!(
            index_error_response_category(
                403,
                "text/html",
                b"<html>Attention Required __cf_chl_tk=1</html>"
            ),
            "Cloudflare challenge/block HTML"
        );
        assert_eq!(
            index_error_response_category(403, "text/html", b"forbidden"),
            "access-denied response"
        );
    }

    #[test]
    fn home_parser_reads_nested_cards_and_skips_ads_and_empty_sections() {
        let html = r#"
          <div id="centers">
            <div class="block"><div class="blocktitle">empty banner</div></div>
            <div class="block"><div class="blocktitle">广告</div>
              <a title="有效广告书号" href="/book/9.htm"><img src="https://img1.wenku8.com/9.jpg"></a>
            </div>
            <div class="block"><div class="blocktitle">文库轻小说推广区</div>
              <a title="合法推广书目" href="/book/106.htm"><img src="https://img1.wenku8.com/106.jpg"></a>
            </div>
            <div class="block"><div class="blocktitle">轻小说文库公告</div>
              <a title="公告内书目" href="/book/8.htm"><img src="https://img1.wenku8.com/8.jpg"></a>
            </div>
            <div class="block"><h3>新书风云榜</h3><table><tr>
              <td><a href="http://www.wenku8.net/book/101.htm"><span>
                <img src="/placeholder.jpg" data-src="http://img1.wenku8.com/101.jpg">
              </span></a><p><a href="/book/101.htm">第一个书名</a></p></td>
              <td><a href="/book/102.htm"><img alt="第二个书名" src="https://img1.wenku8.com/102.jpg"></a></td>
              <td><a href="https://ads.example.com/book/103.htm"><img src="https://img1.wenku8.com/ad.jpg"></a>
                <a href="/book/103.htm">不应借用此书名</a></td>
              <td><img src="data:image/png;base64,broken"><a href="/book/104.htm">错误图片</a></td>
            </tr></table></div>
          </div>
          <div class="main"><div class="block"><div class="blocktitle">会员推荐</div>
            <div><a href="/book/105.htm" title="第五个书名"><img src="https://img1.wenku8.com/105.jpg"></a></div>
          </div></div>"#;
        let blocks = Wenku8Client::parse_index(html).unwrap();
        assert_eq!(blocks.len(), 3);
        assert_eq!(blocks[0].title, "文库轻小说推广区");
        assert_eq!(blocks[0].list[0].aid, "106");
        assert_eq!(blocks[1].title, "新书风云榜");
        assert_eq!(blocks[1].list.len(), 2);
        assert_eq!(blocks[1].list[0].title, "第一个书名");
        assert_eq!(
            blocks[1].list[0].detail_url,
            "https://www.wenku8.net/book/101.htm"
        );
        assert_eq!(blocks[1].list[0].img, "https://img1.wenku8.com/101.jpg");
        assert_eq!(blocks[2].list[0].aid, "105");
    }

    #[test]
    fn home_parser_does_not_treat_challenge_login_or_empty_home_as_success() {
        for page in [
            "<html><title>Just a moment</title></html>",
            "<form action='/login.php'>用户登录</form>",
            "<div id=centers></div>",
            "<div id=centers><div class=block><div class=blocktitle>广告</div><a href='/book/12oops.htm'><img src='https://img1.wenku8.com/ad.jpg'></a></div></div>",
        ] {
            assert!(Wenku8Client::parse_index(page).is_err());
        }
    }

    #[test]
    fn home_parser_reads_plain_sibling_names_in_the_legacy_fixture() {
        let blocks = Wenku8Client::parse_index(include_str!(
            "../../../test/fixtures/wenku8_home_index.html"
        ))
        .unwrap();
        assert_eq!(blocks.len(), 3);
        assert_eq!(blocks[0].list[0].title, "中心小说甲");
        assert_eq!(blocks[0].list[1].title, "中心小说丁");
        assert_eq!(blocks[1].list[0].title, "新书小说乙");
        assert_eq!(blocks[2].list[0].title, "热门书丙");
    }

    #[test]
    fn home_decoder_obeys_gbk_and_utf8_declarations() {
        let html = "<html><div>中文书名</div></html>";
        let (encoded, _, errors) = GBK.encode(html);
        assert!(!errors);
        assert_eq!(
            decode_home(
                bytes::Bytes::from(encoded.into_owned()),
                "text/html; charset=gbk"
            )
            .unwrap(),
            html
        );
        assert_eq!(
            decode_home(
                bytes::Bytes::from(html.as_bytes().to_vec()),
                "text/html; charset=UTF-8"
            )
            .unwrap(),
            html
        );
    }
}

fn clean_home_title(value: &str) -> Option<String> {
    let title = value.split_whitespace().collect::<Vec<_>>().join(" ");
    (!title.is_empty() && title.chars().count() <= 240).then_some(title)
}

fn home_book_url(anchor: ElementRef<'_>, base: &reqwest::Url) -> Option<(String, String)> {
    let raw = anchor.value().attr("href")?.trim();
    if raw.len() > 2048 {
        return None;
    }
    let mut url = base.join(raw).ok()?;
    if !["http", "https"].contains(&url.scheme())
        || url.host_str() != base.host_str()
        || url.port() != base.port()
        || !url.username().is_empty()
        || url.password().is_some()
        || url.query().is_some()
        || url.fragment().is_some()
    {
        return None;
    }
    let aid = url.path().strip_prefix("/book/")?.strip_suffix(".htm")?;
    if aid.is_empty() || aid.len() > 12 || !aid.bytes().all(|byte| byte.is_ascii_digit()) {
        return None;
    }
    let aid = aid.to_string();
    url.set_scheme("https").ok()?;
    Some((url.to_string(), aid))
}

fn home_image_url(image: ElementRef<'_>, base: &reqwest::Url) -> Option<String> {
    let raw = [
        "data-original",
        "data-original-src",
        "data-lazy-src",
        "data-src",
        "src",
    ]
    .into_iter()
    .filter_map(|name| image.value().attr(name))
    .map(str::trim)
    .find(|value| !value.is_empty())?;
    if raw.len() > 2048 {
        return None;
    }
    let mut url = base.join(raw).ok()?;
    let host = url.host_str()?;
    if !["http", "https"].contains(&url.scheme())
        || !["wenku8.net", "wenku8.com"]
            .iter()
            .any(|domain| host == *domain || host.ends_with(&format!(".{domain}")))
        || url.port().is_some()
        || !url.username().is_empty()
        || url.password().is_some()
    {
        return None;
    }
    url.set_scheme("https").ok()?;
    url.set_fragment(None);
    Some(url.to_string())
}

fn decode_home(bytes: bytes::Bytes, content_type: &str) -> Result<String> {
    let declaration = String::from_utf8_lossy(&bytes[..bytes.len().min(2048)])
        .to_ascii_lowercase()
        .replace(' ', "");
    let declared_utf8 = content_type
        .to_ascii_lowercase()
        .replace(' ', "")
        .contains("charset=utf-8")
        || declaration.contains("charset=utf-8")
        || declaration.contains("charset=\"utf-8\"")
        || declaration.contains("charset='utf-8'")
        || bytes.starts_with(&[0xef, 0xbb, 0xbf]);
    if declared_utf8 {
        String::from_utf8(bytes.to_vec()).context("Failed to decode UTF-8 Wenku8 home")
    } else {
        decode_gbk(bytes)
    }
}

fn decode_gbk(bytes: bytes::Bytes) -> Result<String> {
    let (cow, _, had_errors) = GBK.decode(&bytes);
    if had_errors {
        Err(anyhow!("Failed to decode GBK"))
    } else {
        Ok(cow.into_owned())
    }
}

fn gbk_url_encode(text: &str) -> String {
    let gbk_bytes = GBK
        .encode(text)
        .0
        .into_iter()
        .map(|b| *b)
        .collect::<Vec<u8>>();
    let mut encoded = String::new();
    for byte in gbk_bytes {
        if byte.is_ascii_alphanumeric() || byte == b'_' {
            encoded.push(byte as char);
        } else {
            encoded.push_str(&format!("%{:02X}", byte));
        }
    }
    encoded
}
