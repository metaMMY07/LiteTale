//! Versioned local snapshots. Account/session databases are never attached.
use crate::database::entities::{active::reading_history, properties::property};
use crate::database::{ACTIVE_DB_CONNECT, PROPERTIES_DB_CONNECT};
use anyhow::{bail, ensure, Context, Result};
use base64::Engine;
use chrono::{Local, Timelike};
use sea_orm::{
    ConnectionTrait, Database, DatabaseConnection, DbBackend, EntityTrait, Statement,
    TransactionTrait,
};
use serde_json::{json, Map, Value};
use sha2::{Digest, Sha256};

const MAX_BYTES: usize = 256 * 1024 * 1024;
const SETTINGS_KEYS: &[&str] = &[
    "font_size",
    "line_height",
    "paragraph_spacing",
    "top_bar_height",
    "bottom_bar_height",
    "left_padding",
    "right_padding",
    "reader_type",
    "reader_theme_mode",
    "reader_light_background_color",
    "reader_light_text_color",
    "reader_dark_background_color",
    "reader_dark_text_color",
    "app_accent_v1",
    "reader_page_curl_v1",
    "_volumeControlProperty",
    "_screenUpOnReadingProperty",
    "_screenUpOnScrollProperty",
    "litetale.settings_v1",
    "litetale.font_settings_v1",
    "reader_background_v1",
];
const SHELF_KEYS: &[&str] = &[
    "litetale.lns.local_shelf",
    "litetale.lns.search_history",
    "litetale.lnovel.local_shelf",
    "litetale.lnovel.search_history",
];
const STATS_KEY: &str = "litetale.reading_statistics_v1";

fn sql(text: &str, values: Vec<sea_orm::Value>) -> Statement {
    Statement::from_sql_and_values(DbBackend::Sqlite, text, values)
}

pub async fn export_snapshot(
    include_bookshelves: bool,
    include_reading: bool,
    include_settings: bool,
) -> Result<String> {
    ensure!(
        include_bookshelves || include_reading || include_settings,
        "请选择要导出的数据"
    );
    let properties = PROPERTIES_DB_CONNECT
        .get()
        .context("Database not initialized")?
        .lock()
        .await;
    let active = ACTIVE_DB_CONNECT
        .get()
        .context("Database not initialized")?
        .lock()
        .await;
    let rows = property::Entity::find().all(&*properties).await?;
    let selected = |keys: &[&str]| -> Map<String, Value> {
        rows.iter()
            .filter(|r| keys.contains(&r.key.as_str()))
            .map(|r| (r.key.clone(), Value::String(r.value.clone())))
            .collect()
    };
    let mut result =
        json!({"format":"litetale", "version":1, "createdAt":Local::now().to_rfc3339()});
    if include_bookshelves {
        result["bookshelves"] = json!({"properties":selected(SHELF_KEYS)});
    }
    if include_settings {
        result["settings"] = json!({"properties":selected(SETTINGS_KEYS),"media":{"files":{}}});
    }
    if include_reading {
        let history = reading_history::Entity::find().all(&*active).await?;
        let statistics = rows
            .iter()
            .find(|r| r.key == STATS_KEY)
            .map(|r| serde_json::from_str::<Value>(&r.value))
            .transpose()?
            .unwrap_or_else(|| json!({"version":1,"events":[]}));
        result["reading"] = json!({"history":history,"statistics":statistics});
    }
    validate(&result)?;
    Ok(serde_json::to_string(&result)?)
}

pub fn inspect_snapshot(json: String) -> Result<String> {
    let snapshot = parse(&json)?;
    Ok(summary(&snapshot).to_string())
}

/// Both user databases participate in a single SQLite transaction. A dedicated
/// one-connection pool prevents ATTACH from accidentally reaching another pool
/// connection; the normal database guards also serialize existing FRB writers.
pub async fn import_snapshot(json: String, overwrite: bool) -> Result<String> {
    let snapshot = parse(&json)?;
    let properties = PROPERTIES_DB_CONNECT
        .get()
        .context("Database not initialized")?
        .lock()
        .await;
    let active = ACTIVE_DB_CONNECT
        .get()
        .context("Database not initialized")?
        .lock()
        .await;
    let active_path = database_path(&*active).await?;
    let properties_path = database_path(&*properties).await?;
    let mut options = sea_orm::ConnectOptions::new(format!("sqlite:{}?mode=rw", active_path));
    options
        .max_connections(1)
        .min_connections(1)
        .sqlx_logging(false);
    let connection = Database::connect(options).await?;
    connection
        .execute(sql(
            "ATTACH DATABASE ? AS snapshot_properties",
            vec![properties_path.into()],
        ))
        .await?;
    let applied = async {
        // Attached databases need rollback journals for a crash-atomic commit.
        // Refuse WAL/OFF/MEMORY rather than silently changing an existing DB.
        for name in ["main", "snapshot_properties"] {
            let row = connection
                .query_one(sql(&format!("PRAGMA {}.journal_mode", name), vec![]))
                .await?
                .context("Database journal unavailable")?;
            let mode: String = row.try_get_by_index(0)?;
            ensure!(
                ["delete", "truncate", "persist"].contains(&mode.to_lowercase().as_str()),
                "数据库日志模式不支持安全导入"
            );
        }
        apply(&connection, &snapshot, overwrite).await
    }
    .await;
    let _ = connection
        .execute(sql("DETACH DATABASE snapshot_properties", vec![]))
        .await;
    connection.close().await?;
    applied?;
    Ok(summary(&snapshot).to_string())
}

async fn database_path<C: ConnectionTrait>(connection: &C) -> Result<String> {
    let rows = connection
        .query_all(sql("PRAGMA database_list", vec![]))
        .await?;
    for row in rows {
        let name: String = row.try_get("", "name")?;
        if name == "main" {
            let file: String = row.try_get("", "file")?;
            ensure!(!file.is_empty(), "Database file unavailable");
            return Ok(file);
        }
    }
    bail!("Database file unavailable")
}

fn parse(raw: &str) -> Result<Value> {
    ensure!(raw.len() <= MAX_BYTES, "快照不能超过256 MB");
    let result: Value = serde_json::from_str(raw).context("无效的LiteTale快照")?;
    validate(&result)?;
    validate_media(&result)?;
    Ok(result)
}

fn object(value: &Value) -> Result<&Map<String, Value>> {
    value.as_object().context("快照对象无效")
}
fn text(value: &Value, max: usize) -> Result<&str> {
    let s = value.as_str().context("快照文本无效")?;
    ensure!(s.len() <= max, "快照文本过长");
    Ok(s)
}
fn allowed_fields(value: &Value, allowed: &[&str]) -> Result<()> {
    ensure!(
        object(value)?
            .keys()
            .all(|key| allowed.contains(&key.as_str())),
        "快照包含不支持的字段"
    );
    Ok(())
}
fn source(id: &str) -> Result<&'static str> {
    let (number, name) = if let Some(n) = id.strip_prefix("lns:") {
        (n, "lightNovelShelf")
    } else if let Some(n) = id.strip_prefix("lnv:") {
        (n, "lnovel")
    } else {
        (id, "wenku8")
    };
    ensure!(
        !number.is_empty() && number.len() < 80 && number.bytes().all(|b| b.is_ascii_digit()),
        "书籍编号无效"
    );
    Ok(name)
}

fn validate(snapshot: &Value) -> Result<()> {
    allowed_fields(
        snapshot,
        &[
            "format",
            "version",
            "createdAt",
            "bookshelves",
            "reading",
            "settings",
        ],
    )?;
    ensure!(
        snapshot["format"] == "litetale" && snapshot["version"] == 1,
        "这不是受支持的LiteTale快照；LightNovelReader的.lnr格式不能直接导入"
    );
    chrono::DateTime::parse_from_rfc3339(text(&snapshot["createdAt"], 80)?)?;
    ensure!(
        snapshot.get("bookshelves").is_some()
            || snapshot.get("reading").is_some()
            || snapshot.get("settings").is_some(),
        "快照没有可导入的数据"
    );
    if let Some(shelf) = snapshot.get("bookshelves") {
        allowed_fields(shelf, &["properties"])?;
        for (key, value) in object(&shelf["properties"])? {
            ensure!(SHELF_KEYS.contains(&key.as_str()), "快照收藏键无效");
            let items: Value = serde_json::from_str(text(value, 16 * 1024 * 1024)?)?;
            let rows = items.as_array().context("收藏数据无效")?;
            ensure!(rows.len() <= 50000, "收藏数据过多");
            for row in rows {
                if key.ends_with("local_shelf") {
                    allowed_fields(row, &["id", "cover", "title", "author", "cid", "chapter"])?;
                    let id = text(&row["id"], 2048)?;
                    let expected = if key.contains(".lns.") {
                        "lightNovelShelf"
                    } else {
                        "lnovel"
                    };
                    ensure!(source(id)? == expected, "收藏数据混入了其他书源");
                    text(&row["title"], 4096)?;
                    for field in ["cover", "author", "cid", "chapter"] {
                        if let Some(v) = row.get(field) {
                            if !v.is_null() {
                                text(v, 8192)?;
                            }
                        }
                    }
                } else {
                    allowed_fields(row, &["key", "type", "time"])?;
                    text(&row["key"], 4096)?;
                    text(&row["type"], 80)?;
                    ensure!(row["time"].as_i64().is_some(), "搜索记录时间无效");
                }
            }
        }
    }
    if let Some(reading) = snapshot.get("reading") {
        allowed_fields(reading, &["history", "statistics"])?;
        let rows = reading["history"].as_array().context("阅读记录无效")?;
        ensure!(rows.len() <= 100000, "阅读记录过多");
        for row in rows {
            allowed_fields(
                row,
                &[
                    "novel_id",
                    "novel_name",
                    "volume_id",
                    "volume_name",
                    "chapter_id",
                    "chapter_title",
                    "last_read_at",
                    "progress",
                    "progress_page",
                    "cover",
                    "author",
                ],
            )?;
            let history: reading_history::Model = serde_json::from_value(row.clone())?;
            source(&history.novel_id)?;
            ensure!(
                history.progress >= 0 && history.progress_page >= 0 && history.last_read_at >= 0,
                "阅读进度无效"
            );
            for field in [
                "novel_name",
                "volume_id",
                "volume_name",
                "chapter_id",
                "chapter_title",
                "cover",
                "author",
            ] {
                text(&row[field], 8192)?;
            }
        }
        validate_statistics(&reading["statistics"])?;
    }
    if let Some(settings) = snapshot.get("settings") {
        allowed_fields(settings, &["properties", "media"])?;
        for (key, value) in object(&settings["properties"])? {
            ensure!(
                SETTINGS_KEYS.contains(&key.as_str()),
                "快照包含账号或不支持的设置"
            );
            validate_setting(key, text(value, 65536)?)?;
        }
        if let Some(media) = settings.get("media") {
            allowed_fields(media, &["files"])?;
            let files = object(&media["files"])?;
            ensure!(files.len() <= 4, "媒体文件过多");
            for (name, value) in files {
                ensure!(valid_media_name(name), "媒体文件名无效");
                text(value, 90 * 1024 * 1024)?;
            }
        }
    }
    Ok(())
}

fn valid_media_name(name: &str) -> bool {
    if ["light_reader_background.png", "dark_reader_background.png"].contains(&name) {
        return true;
    }
    let Some((digest, extension)) = name.rsplit_once('.') else {
        return false;
    };
    digest.len() == 64
        && digest
            .bytes()
            .all(|b| b.is_ascii_hexdigit() && !b.is_ascii_uppercase())
        && ["ttf", "otf"].contains(&extension)
}

fn validate_media(snapshot: &Value) -> Result<()> {
    let Some(settings) = snapshot.get("settings") else {
        return Ok(());
    };
    let mut media = std::collections::HashMap::<String, Vec<u8>>::new();
    if let Some(files) = settings
        .get("media")
        .and_then(|v| v.get("files"))
        .and_then(|v| v.as_object())
    {
        for (name, value) in files {
            let bytes =
                base64::engine::general_purpose::STANDARD.decode(text(value, 90 * 1024 * 1024)?)?;
            if name.ends_with(".ttf") || name.ends_with(".otf") {
                ensure!(
                    bytes.len() >= 12
                        && bytes.len() <= 64 * 1024 * 1024
                        && (bytes[..4] == [0, 1, 0, 0] || &bytes[..4] == b"OTTO"),
                    "字体文件无效"
                );
                ensure!(
                    hex::encode(Sha256::digest(&bytes)) == name[..64],
                    "字体摘要不匹配"
                );
            } else {
                ensure!(bytes.len() <= 20 * 1024 * 1024, "纸张图片过大");
                let format = image::guess_format(&bytes)?;
                ensure!(
                    [image::ImageFormat::Png, image::ImageFormat::Jpeg].contains(&format),
                    "纸张图片格式无效"
                );
                let dimensions =
                    image::io::Reader::with_format(std::io::Cursor::new(&bytes), format)
                        .into_dimensions()?;
                ensure!(
                    dimensions.0 > 0
                        && dimensions.1 > 0
                        && dimensions.0 as u64 * dimensions.1 as u64 <= 24000000,
                    "纸张分辨率过大"
                );
                image::load_from_memory_with_format(&bytes, format)?;
            }
            media.insert(name.clone(), bytes);
        }
    }
    let properties = object(&settings["properties"])?;
    if let Some(raw) = properties.get("litetale.font_settings_v1") {
        let fonts: Value = serde_json::from_str(text(raw, 65536)?)?;
        for field in ["app", "reader"] {
            if let Some(font) = fonts.get(field).filter(|v| !v.is_null()) {
                let filename = format!(
                    "{}.{}",
                    text(&font["digest"], 64)?,
                    text(&font["extension"], 3)?
                );
                ensure!(media.contains_key(&filename), "快照缺少选择的字体文件");
            }
        }
    }
    if let Some(raw) = properties.get("reader_background_v1") {
        let paper: Value = serde_json::from_str(text(raw, 65536)?)?;
        for (field, name) in [
            ("lightFile", "light_reader_background.png"),
            ("darkFile", "dark_reader_background.png"),
        ] {
            if let Some(value) = paper.get(field) {
                let filename = text(value, 100)?;
                if !filename.is_empty() {
                    let bytes = media.get(name).context("快照缺少选择的纸张图片")?;
                    ensure!(
                        filename == name
                            || filename
                                == format!("snapshot_{}.png", hex::encode(Sha256::digest(bytes))),
                        "纸张摘要不匹配"
                    );
                }
            }
        }
    }
    Ok(())
}

fn validate_setting(key: &str, raw: &str) -> Result<()> {
    if [
        "font_size",
        "line_height",
        "paragraph_spacing",
        "top_bar_height",
        "bottom_bar_height",
        "left_padding",
        "right_padding",
    ]
    .contains(&key)
    {
        let number: f64 = raw.parse()?;
        let min = if key == "font_size" {
            8.0
        } else if key == "line_height" {
            0.8
        } else {
            0.0
        };
        let max = if key == "line_height" { 4.0 } else { 200.0 };
        ensure!(
            number.is_finite() && number >= min && number <= max,
            "阅读参数超出范围"
        );
    } else if key.ends_with("_color") {
        raw.parse::<u32>()?;
    } else if key == "reader_type" {
        ensure!(
            ["ReaderType.normal", "ReaderType.html"].contains(&raw),
            "阅读模式无效"
        );
    } else if key == "reader_theme_mode" {
        ensure!(
            [
                "ReaderThemeMode.auto",
                "ReaderThemeMode.light",
                "ReaderThemeMode.dark"
            ]
            .contains(&raw),
            "主题模式无效"
        );
    } else if [
        "reader_page_curl_v1",
        "_volumeControlProperty",
        "_screenUpOnReadingProperty",
        "_screenUpOnScrollProperty",
    ]
    .contains(&key)
    {
        ensure!(["true", "false"].contains(&raw), "开关值无效");
    } else if key == "app_accent_v1" {
        ensure!(
            ["system", "iris", "blue", "rose", "orange", "teal", "green"].contains(&raw)
                || (raw.starts_with("custom:#")
                    && raw.len() == 14
                    && raw[8..].bytes().all(|b| b.is_ascii_hexdigit())),
            "配色无效"
        );
    } else {
        let value: Value = serde_json::from_str(raw)?;
        object(&value)?;
        ensure!(value["version"] == 1, "设置格式无效");
        if key == "reader_background_v1" {
            allowed_fields(
                &value,
                &[
                    "version",
                    "enabled",
                    "builtin",
                    "opacity",
                    "lightFile",
                    "darkFile",
                ],
            )?;
            for field in ["enabled", "builtin"] {
                ensure!(value[field].is_boolean(), "纸张开关无效");
            }
            let opacity = value["opacity"].as_f64().context("纸张强度无效")?;
            ensure!((0.0..=1.0).contains(&opacity), "纸张强度无效");
            for field in ["lightFile", "darkFile"] {
                if let Some(v) = value.get(field) {
                    let name = text(v, 100)?;
                    ensure!(
                        name.is_empty()
                            || ["light_reader_background.png", "dark_reader_background.png"]
                                .contains(&name)
                            || (name.is_ascii()
                                && name.starts_with("snapshot_")
                                && name.ends_with(".png")
                                && name.len() == 77
                                && name[9..73]
                                    .bytes()
                                    .all(|b| b.is_ascii_hexdigit() && !b.is_ascii_uppercase())),
                        "纸张文件名无效"
                    );
                }
            }
        } else if key == "litetale.settings_v1" {
            allowed_fields(
                &value,
                &[
                    "version",
                    "autoUpdate",
                    "updateChannel",
                    "hanVariant",
                    "logLevel",
                    "blackTheme",
                    "tapToTurn",
                    "boundaryChapters",
                    "preventBack",
                ],
            )?;
            for field in [
                "autoUpdate",
                "blackTheme",
                "tapToTurn",
                "boundaryChapters",
                "preventBack",
            ] {
                if let Some(v) = value.get(field) {
                    ensure!(v.is_boolean(), "设置开关无效");
                }
            }
            for (field, allowed) in [
                ("updateChannel", vec!["stable", "preview"]),
                (
                    "hanVariant",
                    vec!["system", "zh-CN", "zh-TW", "zh-HK", "ja-JP", "ko-KR"],
                ),
                ("logLevel", vec!["off", "error", "info", "debug"]),
            ] {
                if let Some(v) = value.get(field) {
                    ensure!(allowed.contains(&text(v, 40)?), "设置选项无效");
                }
            }
        } else if key == "litetale.font_settings_v1" {
            allowed_fields(&value, &["version", "app", "reader"])?;
            for field in ["app", "reader"] {
                if let Some(v) = value.get(field) {
                    if !v.is_null() {
                        allowed_fields(v, &["name", "digest", "extension"])?;
                        ensure!(!text(&v["name"], 1024)?.is_empty(), "字体名称无效");
                        let digest = text(&v["digest"], 64)?;
                        let extension = text(&v["extension"], 3)?;
                        ensure!(
                            valid_media_name(&format!("{}.{}", digest, extension)),
                            "字体元数据无效"
                        );
                    }
                }
            }
        }
    }
    Ok(())
}

fn validate_statistics(value: &Value) -> Result<()> {
    allowed_fields(value, &["version", "events"])?;
    ensure!(
        value["version"] == 1 && value.to_string().len() <= 16 * 1024 * 1024,
        "统计版本或大小无效"
    );
    let events = value["events"].as_array().context("统计事件无效")?;
    ensure!(events.len() <= 100000, "统计事件过多");
    for e in events {
        allowed_fields(
            e,
            &[
                "id",
                "sessionId",
                "bookId",
                "source",
                "title",
                "kind",
                "occurredAt",
                "seconds",
            ],
        )?;
        let id = text(&e["id"], 512)?;
        let session = text(&e["sessionId"], 512)?;
        ensure!(
            !session.is_empty() && id.starts_with(&format!("{}:", session)),
            "统计编号无效"
        );
        ensure!(
            source(text(&e["bookId"], 2048)?)? == text(&e["source"], 64)?,
            "统计来源无效"
        );
        ensure!(
            text(&e["title"], 4096)?.encode_utf16().count() <= 1024,
            "统计标题过长"
        );
        let date = text(&e["occurredAt"], 64)?;
        ensure!(
            date.is_ascii()
                && date.len() >= 19
                && date.len() <= 26
                && date.as_bytes()[10] == b'T'
                && (date.len() == 19
                    || (date.as_bytes()[19] == b'.'
                        && date[20..].bytes().all(|b| b.is_ascii_digit()))),
            "统计时间无效"
        );
        let timestamp = chrono::NaiveDateTime::parse_from_str(date, "%Y-%m-%dT%H:%M:%S%.f")?;
        let seconds = e["seconds"].as_u64().context("统计时长无效")?;
        match text(&e["kind"], 20)? {
            "session" => ensure!(
                seconds == 0 && id == format!("{}:session", session),
                "统计会话无效"
            ),
            "duration" => {
                ensure!(
                    seconds > 0
                        && seconds <= 86400
                        && timestamp.minute() == 0
                        && timestamp.second() == 0
                        && timestamp.nanosecond() == 0,
                    "统计时长桶无效"
                );
                ensure!(
                    id == format!("{}:{}", session, timestamp.format("%Y%m%d:%H")),
                    "统计时长编号无效"
                );
            }
            _ => bail!("统计类型无效"),
        }
    }
    Ok(())
}

fn summary(snapshot: &Value) -> Value {
    json!({"bookshelves":snapshot.get("bookshelves").is_some(), "reading":snapshot.get("reading").is_some(),
        "settings":snapshot.get("settings").is_some(), "historyCount":snapshot["reading"]["history"].as_array().map_or(0, |v| v.len()),
        "eventCount":snapshot["reading"]["statistics"]["events"].as_array().map_or(0, |v| v.len()),"createdAt":snapshot["createdAt"]})
}

async fn read_property<C: ConnectionTrait>(connection: &C, key: &str) -> Result<Option<String>> {
    Ok(connection
        .query_one(sql(
            "SELECT value FROM snapshot_properties.property WHERE key=?",
            vec![key.into()],
        ))
        .await?
        .map(|row| row.try_get("", "value"))
        .transpose()?)
}
async fn set_property<C: ConnectionTrait>(connection: &C, key: &str, value: String) -> Result<()> {
    connection.execute(sql("INSERT INTO snapshot_properties.property(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", vec![key.into(),value.into()])).await?;
    Ok(())
}

fn merge_array(existing: &str, incoming: &str, shelf: bool) -> Result<String> {
    let existing: Vec<Value> = serde_json::from_str(existing)?;
    let incoming: Vec<Value> = serde_json::from_str(incoming)?;
    let mut rows = Vec::<Value>::new();
    let mut indices = std::collections::HashMap::<(String, String), usize>::new();
    for row in existing.into_iter().chain(incoming) {
        let key = if shelf {
            (text(&row["id"], 2048)?.to_string(), String::new())
        } else {
            (
                text(&row["type"], 80)?.to_string(),
                text(&row["key"], 4096)?.to_string(),
            )
        };
        if let Some(index) = indices.get(&key) {
            if shelf || row["time"].as_i64() >= rows[*index]["time"].as_i64() {
                rows[*index] = row;
            }
        } else {
            indices.insert(key, rows.len());
            rows.push(row);
        }
    }
    ensure!(rows.len() <= 50000, "合并后收藏数据过多");
    if !shelf {
        rows.sort_by(|a, b| b["time"].as_i64().cmp(&a["time"].as_i64()));
    }
    Ok(serde_json::to_string(&rows)?)
}

fn merge_statistics(existing: Value, incoming: &Value) -> Result<Value> {
    validate_statistics(&existing)?;
    validate_statistics(incoming)?;
    let mut events = std::collections::BTreeMap::<String, Value>::new();
    for row in existing["events"]
        .as_array()
        .unwrap()
        .iter()
        .chain(incoming["events"].as_array().unwrap())
    {
        let id = text(&row["id"], 512)?.to_string();
        if let Some(previous) = events.get(&id) {
            for field in ["sessionId", "bookId", "source", "kind"] {
                ensure!(previous[field] == row[field], "统计重复编号不一致");
            }
            if row["kind"] == "duration" {
                if previous["seconds"].as_u64() >= row["seconds"].as_u64() {
                    continue;
                }
            } else {
                let previous_time = chrono::NaiveDateTime::parse_from_str(
                    text(&previous["occurredAt"], 64)?,
                    "%Y-%m-%dT%H:%M:%S%.f",
                )?;
                let incoming_time = chrono::NaiveDateTime::parse_from_str(
                    text(&row["occurredAt"], 64)?,
                    "%Y-%m-%dT%H:%M:%S%.f",
                )?;
                if previous_time >= incoming_time {
                    continue;
                }
            }
        }
        events.insert(id, row.clone());
    }
    ensure!(events.len() <= 100000, "合并后统计数据过多");
    let result = json!({"version":1,"events":events.into_values().collect::<Vec<_>>()});
    validate_statistics(&result)?;
    Ok(result)
}

async fn apply(connection: &DatabaseConnection, snapshot: &Value, overwrite: bool) -> Result<()> {
    let transaction = connection.begin().await?;
    let result = apply_transaction(&transaction, snapshot, overwrite).await;
    match result {
        Ok(()) => {
            transaction.commit().await?;
            Ok(())
        }
        Err(error) => {
            transaction.rollback().await?;
            Err(error)
        }
    }
}

async fn apply_transaction<C: ConnectionTrait>(
    transaction: &C,
    snapshot: &Value,
    overwrite: bool,
) -> Result<()> {
    for (section, keys) in [("settings", SETTINGS_KEYS), ("bookshelves", SHELF_KEYS)] {
        let Some(domain) = snapshot.get(section) else {
            continue;
        };
        if overwrite {
            for key in keys {
                transaction
                    .execute(sql(
                        "DELETE FROM snapshot_properties.property WHERE key=?",
                        vec![(*key).into()],
                    ))
                    .await?;
            }
            if section == "settings" {
                // Older snapshots may omit unset properties. Populate defaults
                // so already-mounted Cubits can reload a genuine reset too.
                for (key, value) in [
                    ("font_size","18"),("line_height","1.3"),("paragraph_spacing","24"),
                    ("top_bar_height","56"),("bottom_bar_height","56"),("left_padding","16"),("right_padding","16"),
                    ("app_accent_v1","system"),("reader_type","ReaderType.normal"),
                    ("reader_page_curl_v1","false"),("_volumeControlProperty","false"),
                    ("_screenUpOnReadingProperty","false"),("_screenUpOnScrollProperty","true"),
                    ("litetale.font_settings_v1","{\"version\":1,\"app\":null,\"reader\":null}"),
                    ("reader_background_v1","{\"version\":1,\"enabled\":true,\"builtin\":false,\"opacity\":0.1,\"lightFile\":\"\",\"darkFile\":\"\"}"),
                ] { set_property(transaction,key,value.to_string()).await?; }
            }
        }
        for (key, value) in object(&domain["properties"])? {
            let raw = text(value, 16 * 1024 * 1024)?;
            let merged = if section == "bookshelves" && !overwrite {
                merge_array(
                    &read_property(transaction, key)
                        .await?
                        .unwrap_or_else(|| "[]".into()),
                    raw,
                    key.ends_with("local_shelf"),
                )?
            } else {
                raw.to_string()
            };
            set_property(transaction, key, merged).await?;
        }
    }
    if let Some(reading) = snapshot.get("reading") {
        if overwrite {
            transaction
                .execute(sql("DELETE FROM reading_history", vec![]))
                .await?;
        }
        for row in reading["history"].as_array().context("阅读数据无效")? {
            let h: reading_history::Model = serde_json::from_value(row.clone())?;
            transaction.execute(sql("INSERT INTO reading_history(novel_id,novel_name,volume_id,volume_name,chapter_id,chapter_title,last_read_at,progress,progress_page,cover,author) VALUES(?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(novel_id) DO UPDATE SET novel_name=excluded.novel_name,volume_id=excluded.volume_id,volume_name=excluded.volume_name,chapter_id=excluded.chapter_id,chapter_title=excluded.chapter_title,last_read_at=excluded.last_read_at,progress=excluded.progress,progress_page=excluded.progress_page,cover=excluded.cover,author=excluded.author WHERE excluded.last_read_at >= reading_history.last_read_at", vec![h.novel_id.into(),h.novel_name.into(),h.volume_id.into(),h.volume_name.into(),h.chapter_id.into(),h.chapter_title.into(),h.last_read_at.into(),h.progress.into(),h.progress_page.into(),h.cover.into(),h.author.into()])).await?;
        }
        let statistics = if overwrite {
            reading["statistics"].clone()
        } else {
            let current = read_property(transaction, STATS_KEY)
                .await?
                .map(|raw| serde_json::from_str(&raw))
                .transpose()?
                .unwrap_or_else(|| json!({"version":1,"events":[]}));
            merge_statistics(current, &reading["statistics"])?
        };
        set_property(transaction, STATS_KEY, statistics.to_string()).await?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    fn sample() -> Value {
        json!({"format":"litetale","version":1,"createdAt":"2026-10-02T12:00:00+08:00", "settings":{"properties":{"font_size":"22"}}})
    }
    #[test]
    fn rejects_secret_keys_and_bad_numbers() {
        let mut data = sample();
        validate(&data).unwrap();
        data["settings"]["properties"]["token"] = json!("secret");
        assert!(validate(&data).is_err());
        data["settings"]["properties"]
            .as_object_mut()
            .unwrap()
            .remove("token");
        data["settings"]["properties"]["font_size"] = json!("NaN");
        assert!(validate(&data).is_err());
        data["format"] = json!("lnr");
        assert!(validate(&data).is_err());
    }
    #[tokio::test]
    async fn rolls_back_both_databases_and_preserves_unselected_data() {
        let mut opts = sea_orm::ConnectOptions::new("sqlite::memory:");
        opts.max_connections(1).min_connections(1);
        let db = Database::connect(opts).await.unwrap();
        db.execute(sql(
            "ATTACH DATABASE ':memory:' AS snapshot_properties",
            vec![],
        ))
        .await
        .unwrap();
        db.execute(sql(
            "CREATE TABLE snapshot_properties.property(key TEXT PRIMARY KEY,value TEXT NOT NULL)",
            vec![],
        ))
        .await
        .unwrap();
        set_property(&db, "font_size", "18".into()).await.unwrap();
        set_property(&db, "token", "private".into()).await.unwrap();
        db.execute(sql("CREATE TABLE reading_history(novel_id TEXT PRIMARY KEY,novel_name TEXT,volume_id TEXT,volume_name TEXT,chapter_id TEXT,chapter_title TEXT,last_read_at INTEGER,progress INTEGER,progress_page INTEGER,cover TEXT,author TEXT)",vec![])).await.unwrap();
        let history = json!({"novel_id":"8","novel_name":"Old","volume_id":"1","volume_name":"one","chapter_id":"2","chapter_title":"Chapter","last_read_at":123,"progress":1,"progress_page":1,"cover":"","author":""});
        let mut initial = sample();
        initial["reading"] =
            json!({"history":[history.clone()],"statistics":{"version":1,"events":[]}});
        apply(&db, &initial, false).await.unwrap();
        set_property(&db, "font_size", "18".into()).await.unwrap();
        db.execute(sql("CREATE TRIGGER snapshot_properties.abort_stats BEFORE INSERT ON property WHEN NEW.key='litetale.reading_statistics_v1' BEGIN SELECT RAISE(ABORT, 'stats failure'); END",vec![])).await.unwrap();
        let mut data = sample();
        let mut updated = history.clone();
        updated["novel_name"] = json!("New");
        updated["last_read_at"] = json!(456);
        data["reading"] = json!({"history":[updated],"statistics":{"version":1,"events":[]}});
        assert!(apply(&db, &data, true).await.is_err());
        assert_eq!(
            read_property(&db, "font_size").await.unwrap().unwrap(),
            "18"
        );
        let restored = db
            .query_one(sql(
                "SELECT novel_name,last_read_at FROM reading_history WHERE novel_id='8'",
                vec![],
            ))
            .await
            .unwrap()
            .unwrap();
        assert_eq!(restored.try_get::<String>("", "novel_name").unwrap(), "Old");
        assert_eq!(restored.try_get::<i64>("", "last_read_at").unwrap(), 123);
        apply(&db, &sample(), false).await.unwrap();
        assert_eq!(
            read_property(&db, "font_size").await.unwrap().unwrap(),
            "22"
        );
        assert_eq!(
            read_property(&db, "token").await.unwrap().unwrap(),
            "private"
        );
        db.close().await.unwrap();
    }
    #[test]
    fn bookshelf_source_is_checked() {
        let mut data = sample();
        data["bookshelves"] = json!({"properties":{"litetale.lns.local_shelf":"[{\"id\":\"lnv:8\",\"title\":\"other\"}]"}});
        assert!(validate(&data).is_err());
    }
    #[test]
    fn rejects_nested_unknown_fields_and_invalid_preferences() {
        let mut data = sample();
        data["bookshelves"] = json!({"properties":{"litetale.lns.local_shelf":"[{\"id\":\"lns:8\",\"title\":\"Book\",\"password\":\"secret\"}]"}});
        assert!(validate(&data).is_err());
        data.as_object_mut().unwrap().remove("bookshelves");
        data["settings"]["properties"]["litetale.settings_v1"] =
            json!("{\"version\":1,\"tapToTurn\":\"true\"}");
        assert!(validate(&data).is_err());
        data["settings"]["properties"]["litetale.settings_v1"] =
            json!("{\"version\":1,\"tapToTurn\":false}");
        validate(&data).unwrap();
    }
    #[test]
    fn cumulative_statistics_merge_is_idempotent_and_checks_buckets() {
        let event = json!({"id":"s:20261002:12","sessionId":"s","bookId":"lns:8","source":"lightNovelShelf","title":"Book","kind":"duration","occurredAt":"2026-10-02T12:00:00.000","seconds":30});
        let old = json!({"version":1,"events":[event.clone()]});
        let mut updated = event;
        updated["seconds"] = json!(60);
        updated["occurredAt"] = json!("2026-10-02T12:00:00");
        let next = json!({"version":1,"events":[updated.clone()]});
        let merged = merge_statistics(old, &next).unwrap();
        assert_eq!(merged["events"][0]["seconds"], 60);
        assert_eq!(merge_statistics(merged.clone(), &next).unwrap(), merged);
        updated["occurredAt"] = json!("2026-10-02T12:00:00Z");
        assert!(validate_statistics(&json!({"version":1,"events":[updated.clone()]})).is_err());
        updated["occurredAt"] = json!("2026-10-02T12:01:00");
        assert!(validate_statistics(&json!({"version":1,"events":[updated]})).is_err());
    }

    #[test]
    fn parse_checks_paper_digest_and_decodes_complete_image() {
        fn snapshot_with_paper(bytes: &[u8], filename: String) -> Value {
            let paper = json!({
                "version":1,
                "enabled":true,
                "builtin":false,
                "opacity":0.4,
                "lightFile":filename,
                "darkFile":""
            });
            let mut data = sample();
            data["settings"]["properties"]["reader_background_v1"] = json!(paper.to_string());
            data["settings"]["media"] = json!({"files":{
                "light_reader_background.png":base64::engine::general_purpose::STANDARD.encode(bytes)
            }});
            data
        }

        let mut png = Vec::new();
        image::RgbaImage::from_pixel(1, 1, image::Rgba([255, 255, 255, 255]))
            .write_to(&mut std::io::Cursor::new(&mut png), image::ImageFormat::Png)
            .unwrap();
        let digest = hex::encode(Sha256::digest(&png));
        let valid = snapshot_with_paper(&png, format!("snapshot_{digest}.png"));
        assert!(parse(&valid.to_string()).is_ok());

        let mismatched = snapshot_with_paper(&png, format!("snapshot_{}.png", "0".repeat(64)));
        assert!(parse(&mismatched.to_string()).is_err());

        // A PNG signature and plausible dimensions are not enough: the image
        // has no IHDR/IDAT chunks and must fail the full decoder.
        let mut truncated = vec![0; 24];
        truncated[..8].copy_from_slice(&[137, 80, 78, 71, 13, 10, 26, 10]);
        truncated[12..16].copy_from_slice(b"IHDR");
        truncated[16..20].copy_from_slice(&1_u32.to_be_bytes());
        truncated[20..24].copy_from_slice(&1_u32.to_be_bytes());
        let corrupt = snapshot_with_paper(
            &truncated,
            format!("snapshot_{}.png", hex::encode(Sha256::digest(&truncated))),
        );
        assert!(parse(&corrupt.to_string()).is_err());
    }

    #[test]
    fn bookshelf_merge_keeps_order_updates_metadata_and_search_uses_tuple_keys() {
        let shelves = merge_array(
            r#"[{"id":"a","title":"Old A"},{"id":"b","title":"B"}]"#,
            r#"[{"id":"a","title":"New A"},{"id":"c","title":"C"}]"#,
            true,
        )
        .unwrap();
        let shelves: Value = serde_json::from_str(&shelves).unwrap();
        assert_eq!(shelves[0]["id"], "a");
        assert_eq!(shelves[0]["title"], "New A");
        assert_eq!(shelves[1]["id"], "b");
        assert_eq!(shelves[2]["id"], "c");

        let searches = merge_array(
            r#"[{"type":"a:b","key":"c","time":10},{"type":"reader","key":"same","time":1}]"#,
            r#"[{"type":"a","key":"b:c","time":20},{"type":"reader","key":"same","time":2}]"#,
            false,
        )
        .unwrap();
        let searches: Value = serde_json::from_str(&searches).unwrap();
        assert_eq!(searches.as_array().unwrap().len(), 3);
        assert_eq!(searches[0]["type"], "a");
        assert_eq!(searches[0]["key"], "b:c");
        assert_eq!(searches[1]["type"], "a:b");
        assert_eq!(searches[1]["key"], "c");
        assert_eq!(searches[2]["time"], 2);
    }

    #[test]
    fn duplicate_session_merge_keeps_newer_occurrence() {
        let old = json!({"id":"s:session","sessionId":"s","bookId":"42","source":"wenku8","title":"Old title","kind":"session","occurredAt":"2026-10-02T12:00:00","seconds":0});
        let newer = json!({"id":"s:session","sessionId":"s","bookId":"42","source":"wenku8","title":"New title","kind":"session","occurredAt":"2026-10-02T13:00:00","seconds":0});
        let existing_newer = json!({"version":1,"events":[newer.clone()]});
        let incoming_older = json!({"version":1,"events":[old.clone()]});
        let merged = merge_statistics(existing_newer, &incoming_older).unwrap();
        assert_eq!(merged["events"][0]["title"], "New title");
        assert_eq!(merged["events"][0]["occurredAt"], "2026-10-02T13:00:00");

        let existing_older = json!({"version":1,"events":[old]});
        let incoming_newer = json!({"version":1,"events":[newer]});
        let merged = merge_statistics(existing_older, &incoming_newer).unwrap();
        assert_eq!(merged["events"][0]["title"], "New title");
    }

    #[tokio::test]
    async fn partial_reading_overwrite_replaces_all_sources_and_preserves_unselected_properties() {
        use std::time::{SystemTime, UNIX_EPOCH};

        let unique = format!(
            "{}_{}",
            std::process::id(),
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        );
        let temp = std::env::temp_dir();
        let active_path = temp.join(format!("litetale_snapshot_active_{unique}.sqlite"));
        let properties_path = temp.join(format!("litetale_snapshot_properties_{unique}.sqlite"));
        let active_name = active_path.to_string_lossy().to_string();
        let properties_name = properties_path.to_string_lossy().to_string();

        let mut options = sea_orm::ConnectOptions::new(format!("sqlite:{active_name}?mode=rwc"));
        options.max_connections(1).min_connections(1);
        let db = Database::connect(options).await.unwrap();
        db.execute(sql(
            "ATTACH DATABASE ? AS snapshot_properties",
            vec![properties_name.clone().into()],
        ))
        .await
        .unwrap();
        db.execute(sql(
            "CREATE TABLE snapshot_properties.property(key TEXT PRIMARY KEY,value TEXT NOT NULL)",
            vec![],
        ))
        .await
        .unwrap();
        db.execute(sql(
            "CREATE TABLE reading_history(novel_id TEXT PRIMARY KEY,novel_name TEXT,volume_id TEXT,volume_name TEXT,chapter_id TEXT,chapter_title TEXT,last_read_at INTEGER,progress INTEGER,progress_page INTEGER,cover TEXT,author TEXT)",
            vec![],
        ))
        .await
        .unwrap();

        let untouched_properties = [
            ("font_size", "19"),
            (
                "litetale.lns.local_shelf",
                "[{\"id\":\"lns:7\",\"title\":\"LNS saved\"}]",
            ),
            (
                "litetale.lns.search_history",
                "[{\"key\":\"alpha\",\"type\":\"novel\",\"time\":1}]",
            ),
            (
                "litetale.lnovel.local_shelf",
                "[{\"id\":\"lnv:8\",\"title\":\"LNovel saved\"}]",
            ),
            (
                "litetale.lnovel.search_history",
                "[{\"key\":\"beta\",\"type\":\"novel\",\"time\":2}]",
            ),
            ("api_host", "https://account.example.invalid"),
            ("active_source", "wenku8"),
            ("token", "keep-session-secret"),
        ];
        for (key, value) in untouched_properties {
            set_property(&db, key, value.to_string()).await.unwrap();
        }
        set_property(&db, STATS_KEY, r#"{"version":1,"events":[]}"#.to_string())
            .await
            .unwrap();

        for (novel_id, title, last_read_at) in [
            ("lns:1", "Old LNS", 100_i64),
            ("lnv:2", "Old LNovel", 200_i64),
        ] {
            db.execute(sql(
                "INSERT INTO reading_history(novel_id,novel_name,volume_id,volume_name,chapter_id,chapter_title,last_read_at,progress,progress_page,cover,author) VALUES(?,?,?,?,?,?,?,?,?,?,?)",
                vec![
                    novel_id.into(), title.into(), "1".into(), "Volume".into(),
                    "1".into(), "Chapter".into(), last_read_at.into(),
                    1_i32.into(), 1_i32.into(), "".into(), "Author".into(),
                ],
            ))
            .await
            .unwrap();
        }

        let mut partial = sample();
        partial.as_object_mut().unwrap().remove("settings");
        partial["reading"] = json!({
            "history":[{
                "novel_id":"lns:99",
                "novel_name":"Imported LNS",
                "volume_id":"9",
                "volume_name":"Imported volume",
                "chapter_id":"99",
                "chapter_title":"Imported chapter",
                "last_read_at":999,
                "progress":9,
                "progress_page":3,
                "cover":"",
                "author":"Imported author"
            }],
            "statistics":{"version":1,"events":[]}
        });
        let parsed = parse(&partial.to_string()).unwrap();
        apply(&db, &parsed, true).await.unwrap();

        let histories = db
            .query_all(sql(
                "SELECT novel_id FROM reading_history ORDER BY novel_id",
                vec![],
            ))
            .await
            .unwrap()
            .into_iter()
            .map(|row| row.try_get::<String>("", "novel_id").unwrap())
            .collect::<Vec<_>>();
        assert_eq!(histories, ["lns:99"]);
        assert_eq!(
            serde_json::from_str::<Value>(&read_property(&db, STATS_KEY).await.unwrap().unwrap())
                .unwrap(),
            json!({"version":1,"events":[]})
        );
        for (key, expected) in untouched_properties {
            assert_eq!(
                read_property(&db, key).await.unwrap().as_deref(),
                Some(expected)
            );
        }

        db.close().await.unwrap();
        std::fs::remove_file(active_path).unwrap();
        std::fs::remove_file(properties_path).unwrap();
    }
}
