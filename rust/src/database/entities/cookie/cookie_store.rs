use crate::database::entities::CookieEntity;
use bytes::Bytes;
use reqwest::cookie::CookieStore;
use reqwest::header::HeaderValue;
use reqwest::Url;
use std::time::{SystemTime, UNIX_EPOCH};

pub struct DatabaseCookieStore {}

impl DatabaseCookieStore {
    async fn save_cookie(&self, cookie: &::cookie::Cookie<'_>, url: &Url) -> anyhow::Result<()> {
        let Some(host) = url.host_str() else {
            return Ok(());
        };
        let Some(domain) = stored_domain(cookie.domain(), host) else {
            // A Set-Cookie Domain that does not include the response host is invalid.
            return Ok(());
        };
        let path = stored_path(cookie.path(), url.path());
        let expires = cookie_expiration(cookie, unix_timestamp());

        let model = crate::database::entities::Cookie {
            domain,
            name: cookie.name().to_string(),
            value: cookie.value().to_string(),
            path,
            expires,
            secure: cookie.secure(),
            http_only: cookie.http_only(),
        };

        CookieEntity::save_or_update_cookie(model).await?;
        Ok(())
    }

    async fn load_cookies(&self, url: &Url) -> anyhow::Result<Vec<::cookie::Cookie<'static>>> {
        let Some(host) = url.host_str() else {
            return Ok(Vec::new());
        };
        let now = unix_timestamp();
        let mut cookies = Vec::new();

        // Query the exact host key (host-only and pre-fix legacy rows), plus
        // explicitly marked Domain keys for each ancestor domain.
        for domain_key in lookup_domain_keys(host) {
            for stored in CookieEntity::find_by_domain(&domain_key).await? {
                if cookie_matches_url(
                    &stored.domain,
                    &stored.path,
                    stored.secure.unwrap_or(false),
                    stored.expires,
                    url,
                    now,
                ) {
                    cookies.push(::cookie::Cookie::new(stored.name, stored.value));
                }
            }
        }

        Ok(cookies)
    }
}

#[async_trait::async_trait]
impl CookieStore for DatabaseCookieStore {
    fn set_cookies(&self, cookie_headers: &mut dyn Iterator<Item = &HeaderValue>, url: &Url) {
        for header in cookie_headers {
            if let Ok(value) = header.to_str() {
                if let Ok(cookie) = ::cookie::Cookie::parse(value) {
                    let _ = tokio::task::block_in_place(|| {
                        tokio::runtime::Handle::current()
                            .block_on(async move { self.save_cookie(&cookie, url).await })
                    });
                }
            }
        }
    }

    fn cookies(&self, url: &Url) -> Option<HeaderValue> {
        if let Ok(cookies) = tokio::task::block_in_place(|| {
            tokio::runtime::Handle::current().block_on(async move { self.load_cookies(url).await })
        }) {
            let s = cookies
                .into_iter()
                .map(|c| format!("{}={}", c.name(), c.value()))
                .collect::<Vec<_>>()
                .join("; ");

            if s.is_empty() {
                return None;
            }

            HeaderValue::from_maybe_shared(Bytes::from(s)).ok()
        } else {
            None
        }
    }
}

fn stored_domain(cookie_domain: Option<&str>, response_host: &str) -> Option<String> {
    let host = response_host.to_ascii_lowercase();
    match cookie_domain {
        None => Some(host),
        Some(domain) => {
            // cookie 0.18.1's Cookie::domain() strips one leading dot. Reject
            // malformed remnants and use a leading dot in storage to retain
            // the distinction from a host-only cookie without a DB migration.
            let domain = domain.to_ascii_lowercase();
            if domain.is_empty()
                || domain.starts_with('.')
                || domain.ends_with('.')
                || !domain_matches(&host, &domain)
            {
                return None;
            }
            Some(format!(".{domain}"))
        }
    }
}

fn stored_path(cookie_path: Option<&str>, request_path: &str) -> String {
    match cookie_path.filter(|path| path.starts_with('/')) {
        Some(path) => path.to_string(),
        None => default_path(request_path).to_string(),
    }
}

fn default_path(request_path: &str) -> &str {
    if !request_path.starts_with('/') {
        return "/";
    }
    match request_path.rfind('/') {
        Some(0) | None => "/",
        Some(index) => &request_path[..index],
    }
}

fn cookie_expiration(cookie: &::cookie::Cookie<'_>, now: i64) -> Option<i64> {
    if let Some(max_age) = cookie.max_age() {
        return Some(now.saturating_add(max_age.whole_seconds()));
    }
    cookie
        .expires()
        .and_then(|expires| expires.datetime().map(|datetime| datetime.unix_timestamp()))
}

fn unix_timestamp() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_secs().min(i64::MAX as u64) as i64)
        .unwrap_or(0)
}

fn lookup_domain_keys(host: &str) -> Vec<String> {
    let host = host.to_ascii_lowercase();
    let mut keys = vec![host.clone()];
    let labels: Vec<_> = host.split('.').collect();

    // A leading dot marks a newly stored Domain cookie. Do not use bare
    // ancestor keys here: old rows cannot tell Domain from host-only, so they
    // are conservatively retained only for their exact host.
    for index in 0..labels.len().saturating_sub(1) {
        let suffix = labels[index..].join(".");
        if !suffix.is_empty() {
            keys.push(format!(".{suffix}"));
        }
    }
    keys
}

fn cookie_matches_url(
    stored_domain: &str,
    cookie_path: &str,
    secure: bool,
    expires: Option<i64>,
    url: &Url,
    now: i64,
) -> bool {
    let Some(host) = url.host_str() else {
        return false;
    };
    let host = host.to_ascii_lowercase();
    let domain_matches = match stored_domain.strip_prefix('.') {
        Some(domain) if !domain.is_empty() => domain_matches(&host, &domain.to_ascii_lowercase()),
        // Unmarked database rows include cookies written before the marker
        // existed. Their scope is ambiguous, so treat them as host-only.
        _ => stored_domain.eq_ignore_ascii_case(&host),
    };

    domain_matches
        && path_matches(url.path(), cookie_path)
        && (!secure || url.scheme().eq_ignore_ascii_case("https"))
        && expires.map_or(true, |expires| expires > now)
}

fn domain_matches(host: &str, domain: &str) -> bool {
    host.eq_ignore_ascii_case(domain)
        || host
            .to_ascii_lowercase()
            .strip_suffix(&format!(".{}", domain.to_ascii_lowercase()))
            .is_some()
}

fn path_matches(request_path: &str, cookie_path: &str) -> bool {
    if cookie_path.is_empty() || !cookie_path.starts_with('/') {
        return false;
    }
    if request_path == cookie_path {
        return true;
    }
    if !request_path.starts_with(cookie_path) {
        return false;
    }
    cookie_path.ends_with('/') || request_path.as_bytes().get(cookie_path.len()) == Some(&b'/')
}

#[cfg(test)]
mod tests {
    use super::*;

    fn url(value: &str) -> Url {
        Url::parse(value).expect("test URL should parse")
    }

    #[test]
    fn cookie_crate_domain_is_normalized_and_stored_as_domain_scope() {
        let cookie = ::cookie::Cookie::parse("test=fixture; Domain=.WenKu8.NET").unwrap();
        assert_eq!(cookie.domain(), Some("WenKu8.NET"));
        assert_eq!(
            stored_domain(cookie.domain(), "www.wenku8.net"),
            Some(".wenku8.net".to_string())
        );
    }

    #[test]
    fn domain_cookie_matches_apex_and_subdomains_but_respects_label_boundary() {
        assert!(cookie_matches_url(
            ".wenku8.net",
            "/",
            false,
            None,
            &url("https://wenku8.net/"),
            100,
        ));
        assert!(cookie_matches_url(
            ".wenku8.net",
            "/",
            false,
            None,
            &url("https://www.wenku8.net/"),
            100,
        ));
        assert!(!cookie_matches_url(
            ".wenku8.net",
            "/",
            false,
            None,
            &url("https://notwenku8.net/"),
            100,
        ));
    }

    #[test]
    fn host_only_cookie_matches_only_its_exact_host() {
        assert!(cookie_matches_url(
            "www.wenku8.net",
            "/",
            false,
            None,
            &url("https://www.wenku8.net/"),
            100,
        ));
        assert!(!cookie_matches_url(
            "www.wenku8.net",
            "/",
            false,
            None,
            &url("https://wenku8.net/"),
            100,
        ));
        assert_eq!(
            lookup_domain_keys("www.wenku8.net"),
            vec!["www.wenku8.net", ".www.wenku8.net", ".wenku8.net",]
        );
    }

    #[test]
    fn path_matching_requires_a_path_boundary() {
        assert!(path_matches("/verify", "/verify"));
        assert!(path_matches("/verify/image", "/verify"));
        assert!(path_matches("/verify/image", "/verify/"));
        assert!(!path_matches("/verification", "/verify"));
    }

    #[test]
    fn secure_expiry_and_legacy_rows_are_filtered_conservatively() {
        let secure = |scheme, expires| {
            cookie_matches_url(
                ".wenku8.net",
                "/",
                true,
                expires,
                &url(&format!("{scheme}://www.wenku8.net/")),
                100,
            )
        };
        assert!(secure("https", None));
        assert!(!secure("http", None));
        assert!(!secure("https", Some(100)));
        assert!(secure("https", Some(101)));

        // A pre-marker parent-domain key is indistinguishable from a legacy
        // host-only key and therefore remains exact-host only.
        assert!(cookie_matches_url(
            "wenku8.net",
            "/",
            false,
            None,
            &url("https://wenku8.net/"),
            100,
        ));
        assert!(!cookie_matches_url(
            "wenku8.net",
            "/",
            false,
            None,
            &url("https://www.wenku8.net/"),
            100,
        ));
    }

    #[test]
    fn saving_rejects_unrelated_domain_and_computes_default_path() {
        let cookie = ::cookie::Cookie::parse("test=fixture; Domain=evil.example").unwrap();
        assert_eq!(stored_domain(cookie.domain(), "www.wenku8.net"), None);
        assert_eq!(stored_path(None, "/verify/image"), "/verify");
        assert_eq!(stored_path(None, "/"), "/");
    }
}
