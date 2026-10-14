use anyhow::anyhow;
use reqwest::{Client, ClientBuilder, RequestBuilder, Response};
use std::future::Future;
use std::time::Duration;

pub(crate) const CONNECT_TIMEOUT: Duration = Duration::from_secs(5);
pub(crate) const DEFAULT_REQUEST_TIMEOUT: Duration = Duration::from_secs(14);
pub(crate) const READ_OPERATION_TIMEOUT: Duration = Duration::from_secs(16);
pub(crate) const IMAGE_REQUEST_TIMEOUT: Duration = Duration::from_secs(25);
pub(crate) const IMAGE_OPERATION_TIMEOUT: Duration = Duration::from_secs(30);
pub(crate) const DOWNLOAD_REQUEST_TIMEOUT: Duration = Duration::from_secs(120);
pub(crate) const DOWNLOAD_OPERATION_TIMEOUT: Duration = Duration::from_secs(150);

#[derive(Clone, Copy, Debug)]
pub(crate) struct RequestPolicy {
    pub(crate) request_timeout: Duration,
    pub(crate) operation_timeout: Duration,
}

impl RequestPolicy {
    pub(crate) const CAPTCHA: Self = Self {
        request_timeout: Duration::from_secs(12),
        operation_timeout: READ_OPERATION_TIMEOUT,
    };

    pub(crate) const READ: Self = Self {
        request_timeout: DEFAULT_REQUEST_TIMEOUT,
        operation_timeout: READ_OPERATION_TIMEOUT,
    };

    pub(crate) const DOWNLOAD: Self = Self {
        request_timeout: DOWNLOAD_REQUEST_TIMEOUT,
        operation_timeout: DOWNLOAD_OPERATION_TIMEOUT,
    };

    pub(crate) const IMAGE: Self = Self {
        request_timeout: IMAGE_REQUEST_TIMEOUT,
        operation_timeout: IMAGE_OPERATION_TIMEOUT,
    };

    #[cfg(test)]
    const fn for_test(request_timeout: Duration, operation_timeout: Duration) -> Self {
        Self {
            request_timeout,
            operation_timeout,
        }
    }
}

pub(crate) fn default_client_builder() -> ClientBuilder {
    Client::builder()
        .connect_timeout(CONNECT_TIMEOUT)
        .timeout(DEFAULT_REQUEST_TIMEOUT)
}

/// Bound a compound HTTP operation that contains more than one request.
pub(crate) async fn with_operation_timeout<T, F>(
    operation: F,
    budget: Duration,
    name: &'static str,
) -> anyhow::Result<T>
where
    F: Future<Output = anyhow::Result<T>>,
{
    tokio::time::timeout(budget, operation)
        .await
        .map_err(|_| anyhow!("{name} timed out after {} ms", budget.as_millis()))?
}

/// Send a retryable GET with one deadline shared by all attempts.
/// The per-request timeout also covers reading the eventual response body, so
/// returning the Response does not restart the budget for a slow body.
pub(crate) async fn send_idempotent_get(
    mut request: RequestBuilder,
    policy: RequestPolicy,
) -> reqwest::Result<Response> {
    let started = tokio::time::Instant::now();
    let mut last_error = None;

    for attempt in 0..3 {
        let elapsed = started.elapsed();
        let remaining = policy.operation_timeout.saturating_sub(elapsed);
        if remaining.is_zero() {
            return Err(last_error.expect("budget only expires after a retryable request error"));
        }

        let retry_request = request.try_clone();
        request = request.timeout(remaining.min(policy.request_timeout));
        match request.send().await {
            Ok(response) => return Ok(response),
            Err(error) => {
                if attempt == 2 || !is_retryable_get_error(&error) {
                    return Err(error);
                }

                let Some(next_request) = retry_request else {
                    return Err(error);
                };

                let elapsed = started.elapsed();
                let remaining = policy.operation_timeout.saturating_sub(elapsed);
                let backoff = Duration::from_millis(150 * (attempt + 1));
                if remaining <= backoff {
                    return Err(error);
                }
                tokio::time::sleep(backoff).await;
                last_error = Some(error);
                request = next_request;
            }
        }
    }

    Err(last_error.expect("the retry loop can only finish after a request error"))
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

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Instant;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    use tokio::net::TcpListener;

    async fn local_server<F, Fut>(handler: F) -> String
    where
        F: FnOnce(tokio::net::TcpStream) -> Fut + Send + 'static,
        Fut: std::future::Future<Output = ()> + Send + 'static,
    {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        tokio::spawn(async move {
            let (mut socket, _) = listener.accept().await.unwrap();
            let mut request = vec![0; 4096];
            let _ = socket.read(&mut request).await;
            handler(socket).await;
        });
        format!("http://{address}")
    }

    fn test_client() -> Client {
        Client::builder()
            .connect_timeout(Duration::from_millis(100))
            .timeout(Duration::from_secs(1))
            .build()
            .unwrap()
    }

    #[test]
    fn defaults_bound_connect_request_and_retryable_read_budget() {
        assert_eq!(CONNECT_TIMEOUT, Duration::from_secs(5));
        assert_eq!(DEFAULT_REQUEST_TIMEOUT, Duration::from_secs(14));
        assert_eq!(READ_OPERATION_TIMEOUT, Duration::from_secs(16));
        assert_eq!(DOWNLOAD_REQUEST_TIMEOUT, Duration::from_secs(120));
        assert_eq!(DOWNLOAD_OPERATION_TIMEOUT, Duration::from_secs(150));
    }

    #[tokio::test]
    async fn slow_response_hits_total_get_budget() {
        let url = local_server(|mut socket| async move {
            tokio::time::sleep(Duration::from_millis(180)).await;
            let _ = socket
                .write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok")
                .await;
        })
        .await;
        let policy = RequestPolicy::for_test(Duration::from_millis(300), Duration::from_millis(60));
        let started = Instant::now();
        let result = send_idempotent_get(test_client().get(url), policy).await;
        assert!(result.is_err(), "slow response unexpectedly succeeded");
        assert!(started.elapsed() < Duration::from_millis(160));
    }

    #[tokio::test]
    async fn disconnect_ends_request_and_normal_response_still_succeeds() {
        let url = local_server(|mut socket| async move {
            let _ = socket
                .write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 4\r\nConnection: close\r\n\r\nx")
                .await;
        })
        .await;
        let client = test_client();
        let response = send_idempotent_get(
            client.get(url),
            RequestPolicy::for_test(Duration::from_millis(150), Duration::from_millis(350)),
        )
        .await;
        let response = response.expect("response headers arrive before the server disconnects");
        assert!(
            response.bytes().await.is_err(),
            "truncated body was accepted"
        );

        let url = local_server(|mut socket| async move {
            let _ = socket
                .write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok")
                .await;
        })
        .await;
        let response = send_idempotent_get(
            client.get(url),
            RequestPolicy::for_test(Duration::from_millis(150), Duration::from_millis(350)),
        )
        .await
        .unwrap();
        assert_eq!(response.status(), reqwest::StatusCode::OK);
        assert_eq!(response.bytes().await.unwrap().as_ref(), b"ok");
    }

    #[tokio::test]
    async fn server_error_is_returned_without_retry() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let request_count = std::sync::Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let count = request_count.clone();
        tokio::spawn(async move {
            let (mut socket, _) = listener.accept().await.unwrap();
            count.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
            let mut request = vec![0; 4096];
            let _ = socket.read(&mut request).await;
            let _ = socket
                .write_all(b"HTTP/1.1 502 Bad Gateway\r\nContent-Length: 3\r\nConnection: close\r\n\r\nbad")
                .await;
        });

        let response = send_idempotent_get(
            test_client().get(format!("http://{address}")),
            RequestPolicy::for_test(Duration::from_millis(150), Duration::from_millis(350)),
        )
        .await
        .unwrap();
        assert_eq!(response.status(), reqwest::StatusCode::BAD_GATEWAY);
        assert_eq!(request_count.load(std::sync::atomic::Ordering::SeqCst), 1);
    }

    #[tokio::test]
    async fn long_download_policy_accepts_response_beyond_interactive_budget() {
        let url = local_server(|mut socket| async move {
            tokio::time::sleep(Duration::from_millis(100)).await;
            let _ = socket
                .write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok")
                .await;
        })
        .await;
        let response = send_idempotent_get(
            test_client().get(url),
            RequestPolicy::for_test(Duration::from_millis(300), Duration::from_millis(500)),
        )
        .await
        .unwrap();
        assert_eq!(response.bytes().await.unwrap().as_ref(), b"ok");
    }

    #[tokio::test]
    async fn body_timeout_is_enforced_after_headers_arrive() {
        let url = local_server(|mut socket| async move {
            let _ = socket
                .write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\n")
                .await;
            tokio::time::sleep(Duration::from_millis(180)).await;
            let _ = socket.write_all(b"ok").await;
        })
        .await;
        let response = send_idempotent_get(
            test_client().get(url),
            RequestPolicy::for_test(Duration::from_millis(50), Duration::from_millis(100)),
        )
        .await
        .unwrap();
        assert!(response.bytes().await.is_err());
    }

    #[tokio::test]
    async fn compound_operation_budget_cancels_nested_waits() {
        let started = Instant::now();
        let result = with_operation_timeout(
            async {
                tokio::time::sleep(Duration::from_millis(180)).await;
                Ok(())
            },
            Duration::from_millis(60),
            "fixture",
        )
        .await;
        assert!(result.is_err());
        assert!(started.elapsed() < Duration::from_millis(160));
    }
}
