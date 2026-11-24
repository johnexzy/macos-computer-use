//! Non-blocking Unix domain socket telemetry channel from `useui` host to its child `useui-runtime`.
//!
//! Streams lightweight browser activity events (tab opens, parallel batch reads, DOM steps)
//! to the native macOS Menu Bar Live Island without altering the strict v1 AX wire protocol
//! or adding latency to MCP tool execution.

use serde_json::{Value, json};
use std::{
    path::PathBuf,
    time::{Duration, SystemTime, UNIX_EPOCH},
};
use tokio::{io::AsyncWriteExt, net::UnixStream, sync::mpsc};

#[derive(Clone, Default)]
pub struct TelemetryClient {
    tx: Option<mpsc::Sender<Vec<u8>>>,
}

impl TelemetryClient {
    pub fn disabled() -> Self {
        Self { tx: None }
    }

    pub fn new(socket_path: PathBuf) -> Self {
        let (tx, mut rx) = mpsc::channel::<Vec<u8>>(64);
        tokio::spawn(async move {
            while let Some(frame) = rx.recv().await {
                if let Ok(Ok(mut stream)) = tokio::time::timeout(
                    Duration::from_millis(80),
                    UnixStream::connect(&socket_path),
                )
                .await
                {
                    let _ = tokio::time::timeout(Duration::from_millis(80), async {
                        let _ = stream.write_all(&frame).await;
                        let _ = stream.flush().await;
                    })
                    .await;
                }
            }
        });
        Self { tx: Some(tx) }
    }

    pub fn emit_browser(&self, phase: &str, label: &str, detail: Option<&str>) {
        let Some(tx) = &self.tx else {
            return;
        };
        let ts_ms = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_millis() as u64)
            .unwrap_or(0);
        let payload = json!({
            "source": "browser",
            "phase": phase,
            "label": label,
            "detail": detail,
            "tsUnixMs": ts_ms,
        });
        if let Ok(mut bytes) = serde_json::to_vec(&payload) {
            bytes.push(b'\n');
            // Non-blocking: drop if UI queue is saturated; never stall tool calls.
            let _ = tx.try_send(bytes);
        }
    }
}

pub fn telemetry_socket_path() -> PathBuf {
    let home = std::env::var_os("HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/tmp"));
    home.join("Library")
        .join("Caches")
        .join("com.johnoba.useui")
        .join(format!("telemetry-{}.sock", std::process::id()))
}

pub fn describe_browser_call(action: &str, params: &serde_json::Map<String, Value>) -> String {
    match action {
        "openTab" => {
            if let Some(url) = params.get("url").and_then(Value::as_str) {
                format!("Opening {}", short_host(url))
            } else {
                "Opening browser tab".into()
            }
        }
        "navigate" => {
            if let Some(hist) = params.get("history").and_then(Value::as_str) {
                format!("Navigating {hist}")
            } else if let Some(url) = params.get("url").and_then(Value::as_str) {
                format!("Navigating to {}", short_host(url))
            } else {
                "Navigating tab".into()
            }
        }
        "snapshot" => "Inspecting browser page".into(),
        "batchRead" => {
            let n = params
                .get("urls")
                .and_then(Value::as_array)
                .map(|a| a.len())
                .unwrap_or(0);
            format!(
                "Reading {n} page{} in parallel",
                if n == 1 { "" } else { "s" }
            )
        }
        "act" => {
            let steps = params.get("steps").and_then(Value::as_array);
            if let Some(steps) = steps {
                if let Some(first) = steps.first() {
                    let kind = first
                        .get("kind")
                        .and_then(Value::as_str)
                        .unwrap_or("action");
                    if steps.len() == 1 {
                        return match kind {
                            "click" => "Clicking browser element".into(),
                            "type" => "Typing in browser field".into(),
                            "scroll" => "Scrolling browser page".into(),
                            "select" => "Selecting browser option".into(),
                            "pressKey" => "Pressing key in browser".into(),
                            "waitFor" => "Waiting on browser page".into(),
                            _ => format!("Browser {kind}"),
                        };
                    }
                }
                format!("Running {} browser steps", steps.len())
            } else {
                "Acting in browser".into()
            }
        }
        "closeTab" => "Closing browser tab".into(),
        "listTabs" => "Listing browser tabs".into(),
        _ => format!("Browser {action}"),
    }
}

fn short_host(url: &str) -> String {
    let trimmed = url
        .strip_prefix("https://")
        .or_else(|| url.strip_prefix("http://"))
        .unwrap_or(url);
    let host = trimmed.split('/').next().unwrap_or(trimmed);
    host.strip_prefix("www.").unwrap_or(host).to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn describes_browser_actions_cleanly() {
        let mut p = serde_json::Map::new();
        p.insert(
            "url".into(),
            json!("https://www.startuplist.africa/startups"),
        );
        assert_eq!(
            describe_browser_call("openTab", &p),
            "Opening startuplist.africa"
        );

        let mut b = serde_json::Map::new();
        b.insert(
            "urls".into(),
            json!(["https://a.com", "https://b.com", "https://c.com"]),
        );
        assert_eq!(
            describe_browser_call("batchRead", &b),
            "Reading 3 pages in parallel"
        );
    }
}
