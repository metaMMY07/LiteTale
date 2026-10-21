//! Per-origin admission for Wenku8 reads. A 429 never becomes another request
//! on a different transport; Retry-After is carried across the Dart boundary.
use crate::request_policy::{self, RequestPolicy};
use anyhow::{anyhow, Result};
use once_cell::sync::Lazy;
use reqwest::{RequestBuilder, Response};
use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

#[derive(Default)]
struct State {
    next_start: Option<Instant>,
    retry_at: Option<Instant>,
}

static HOSTS: Lazy<Mutex<HashMap<String, Arc<tokio::sync::Mutex<State>>>>> =
    Lazy::new(|| Mutex::new(HashMap::new()));

fn rate_error(seconds: u64) -> anyhow::Error {
    anyhow!("wenku8_rate_limited HTTP 429 retry_after_seconds={}", seconds.max(1))
}

fn retry_seconds(value: Option<&str>, now: chrono::DateTime<chrono::Utc>) -> u64 {
    let value = value.unwrap_or("").trim();
    value.parse::<u64>().ok().or_else(|| {
        chrono::DateTime::parse_from_rfc2822(value).ok().map(|date| {
            date.with_timezone(&chrono::Utc).signed_duration_since(now).num_seconds().max(1) as u64
        })
    }).unwrap_or(30).clamp(1, 604800)
}

pub(super) async fn send(request: RequestBuilder, policy: RequestPolicy) -> Result<Response> {
    let clone = request.try_clone().ok_or_else(|| anyhow!("Wenku8 read cannot be cloned"))?;
    let origin = clone.build()?.url().origin().ascii_serialization();
    let gate = {
        let mut hosts = HOSTS.lock().map_err(|_| anyhow!("Wenku8 request gate unavailable"))?;
        if hosts.len() >= 8 {
            hosts.retain(|_, gate| Arc::strong_count(gate) > 1 ||
                gate.try_lock().map_or(true, |state|
                    state.retry_at.is_some_and(|until| until > Instant::now())));
        }
        // Configuration allows only a handful of site origins. Never evict a
        // cooling origin and accidentally let new work bypass its deadline.
        if !hosts.contains_key(&origin) && hosts.len() >= 8 {
            return Err(anyhow!("Wenku8 request origin limit reached"));
        }
        hosts.entry(origin).or_default().clone()
    };
    tokio::time::timeout(policy.operation_timeout, async {
        let mut state = gate.lock().await;
        if let Some(until) = state.retry_at {
            if let Some(left) = until.checked_duration_since(Instant::now()) {
                return Err(rate_error(left.as_secs() + u64::from(left.subsec_nanos() > 0)));
            }
            state.retry_at = None;
        }
        if let Some(next) = state.next_start {
            tokio::time::sleep(next.saturating_duration_since(Instant::now())).await;
        }
        state.next_start = Some(Instant::now() + Duration::from_millis(350));
        let response = request_policy::send_idempotent_get(request, policy).await?;
        if response.status() == reqwest::StatusCode::TOO_MANY_REQUESTS {
            let seconds = retry_seconds(
                response.headers().get(reqwest::header::RETRY_AFTER).and_then(|v| v.to_str().ok()),
                chrono::Utc::now(),
            );
            state.retry_at = Some(Instant::now() + Duration::from_secs(seconds));
            return Err(rate_error(seconds));
        }
        Ok(response)
    }).await.map_err(|_| anyhow!("Wenku8 read admission/request timed out"))?
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn respects_delta_seconds_http_dates_and_missing_headers() {
        let now = chrono::DateTime::parse_from_rfc3339("2026-10-21T02:00:00Z").unwrap().with_timezone(&chrono::Utc);
        assert_eq!(retry_seconds(Some("45"), now), 45);
        assert_eq!(retry_seconds(Some("Wed, 21 Oct 2026 02:01:00 GMT"), now), 60);
        assert_eq!(retry_seconds(None, now), 30);
        assert_eq!(retry_seconds(Some("garbage"), now), 30);
        assert_eq!(retry_seconds(Some("0"), now), 1);
        assert_eq!(retry_seconds(Some("999999999999"), now), 604800);
    }

    #[tokio::test]
    async fn throttled_response_stops_queued_reads_without_a_second_get() {
        use std::io::{Read, Write};
        let server = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        server.set_nonblocking(true).unwrap();
        let url = format!("http://{}/book.htm", server.local_addr().unwrap());
        let count = Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let seen = count.clone();
        let thread = std::thread::spawn(move || {
            let deadline = Instant::now() + Duration::from_secs(2);
            while Instant::now() < deadline {
                if let Ok((mut stream, _)) = server.accept() {
                    stream.set_read_timeout(Some(Duration::from_secs(1))).unwrap();
                    let mut bytes = [0; 4096];
                    let _ = stream.read(&mut bytes);
                    seen.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
                    stream.write_all(b"HTTP/1.1 429 Too Many Requests\r\nRetry-After: 60\r\nContent-Length: 0\r\nConnection: close\r\n\r\n").unwrap();
                } else { std::thread::sleep(Duration::from_millis(5)); }
            }
        });
        let client = reqwest::Client::builder().no_proxy().build().unwrap();
        let (first, queued) = tokio::join!(send(client.get(&url), RequestPolicy::READ), send(client.get(&url), RequestPolicy::READ));
        for error in [first.unwrap_err(), queued.unwrap_err()] {
            let message = error.to_string();
            assert!(message.contains("HTTP 429") && message.contains("retry_after_seconds=60"), "{message}");
        }
        thread.join().unwrap();
        assert_eq!(count.load(std::sync::atomic::Ordering::SeqCst), 1);
    }
}
