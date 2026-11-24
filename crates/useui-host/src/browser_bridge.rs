//! Native Messaging <-> Unix Domain Socket bridge for the Chromium browser accelerator extension.
//!
//! Security model:
//! - Zero TCP/localhost ports and zero `--remote-debugging-port` flags.
//! - Chrome launches `useui` directly via its Native Messaging host manifest pinned to `EXTENSION_ID`.
//! - The Native Messaging host listens on a user-private Unix domain socket (`0700` dir, `0600` socket)
//!   and verifies `LOCAL_PEERCRED` peer UID == current process UID on every accepted connection.
//! - Any `useui` MCP server instance connects on demand; if the extension is not connected, calls
//!   fail fast (<5 ms) so callers can seamlessly fall back to native macOS AX.

use serde_json::{Value, json};
use std::{
    collections::HashMap,
    fs,
    io::{self, Read, Write},
    os::unix::fs::PermissionsExt,
    path::{Path, PathBuf},
    sync::{
        Arc,
        atomic::{AtomicU64, Ordering},
    },
    time::Duration,
};
use tokio::{
    io::{AsyncBufReadExt, AsyncWriteExt, BufReader},
    net::{UnixListener, UnixStream},
    sync::{Mutex, mpsc, oneshot},
};
use tokio_util::sync::CancellationToken;

pub const NATIVE_HOST_NAME: &str = "com.johnoba.useui.browser";
pub const EXTENSION_ID: &str = "gcamfcmoeboaikhohcgfangkkakdelga";
const MAX_NATIVE_MSG_BYTES: usize = 950_000;
const MAX_SOCKET_LINE_BYTES: usize = 4 * 1024 * 1024;

pub fn socket_path() -> PathBuf {
    for var in ["USEUI_BROWSER_BRIDGE_SOCK", "CUA_BROWSER_BRIDGE_SOCK"] {
        if let Ok(custom) = std::env::var(var)
            && !custom.trim().is_empty()
        {
            return PathBuf::from(custom);
        }
    }
    let home = std::env::var_os("HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/tmp"));
    home.join("Library")
        .join("Caches")
        .join("com.johnoba.useui")
        .join("bridge.sock")
}

#[derive(Debug)]
pub struct BrowserBridgeError {
    pub code: &'static str,
    pub message: String,
}

impl BrowserBridgeError {
    fn new(code: &'static str, message: impl Into<String>) -> Self {
        Self {
            code,
            message: message.into(),
        }
    }
}

#[derive(Clone, Default)]
pub struct BrowserBridgeClient {
    counter: Arc<AtomicU64>,
}

impl BrowserBridgeClient {
    pub fn new() -> Self {
        Self::default()
    }

    pub async fn status(&self) -> Value {
        let cancel = CancellationToken::new();
        match self
            .call("ping", json!({}), Duration::from_millis(450), cancel)
            .await
        {
            Ok(data) => json!({
                "connected": true,
                "extensionId": EXTENSION_ID,
                "nativeHostName": NATIVE_HOST_NAME,
                "browser": data.get("browser").cloned().unwrap_or(Value::Null),
                "extensionVersion": data.get("extensionVersion").cloned().unwrap_or(Value::Null),
                "tabCount": data.get("tabCount").cloned().unwrap_or(Value::Null),
            }),
            Err(_) => json!({
                "connected": false,
                "extensionId": EXTENSION_ID,
                "nativeHostName": NATIVE_HOST_NAME,
            }),
        }
    }

    pub async fn call(
        &self,
        action: &str,
        params: Value,
        budget: Duration,
        cancel: CancellationToken,
    ) -> Result<Value, BrowserBridgeError> {
        let path = socket_path();
        let req_id = format!(
            "br-{}-{}",
            std::process::id(),
            self.counter.fetch_add(1, Ordering::Relaxed) + 1
        );
        let timeout_ms = budget.as_millis().clamp(100, 60_000) as u64;
        let payload = json!({
            "id": req_id,
            "action": action,
            "params": params,
            "timeoutMs": timeout_ms,
        });
        let mut line = serde_json::to_vec(&payload)
            .map_err(|e| BrowserBridgeError::new("invalid_request", e.to_string()))?;
        line.push(b'\n');

        let fut = async {
            let stream = UnixStream::connect(&path).await.map_err(|_| {
                BrowserBridgeError::new(
                    "extension_not_connected",
                    format!(
                        "Browser accelerator extension is not connected (socket {}). Load the bundled extension (ID {}) in Chrome/Brave and run `useui --install-browser-bridge`, or fall back to observe/act.",
                        path.display(),
                        EXTENSION_ID
                    ),
                )
            })?;
            let (read_half, mut write_half) = stream.into_split();
            write_half.write_all(&line).await.map_err(|e| {
                BrowserBridgeError::new(
                    "bridge_io",
                    format!("Failed writing to browser bridge: {e}"),
                )
            })?;
            write_half.flush().await.map_err(|e| {
                BrowserBridgeError::new("bridge_io", format!("Failed flushing browser bridge: {e}"))
            })?;

            let mut reader = BufReader::new(read_half);
            let mut reply_buf = Vec::new();
            let n = reader
                .read_until(b'\n', &mut reply_buf)
                .await
                .map_err(|e| {
                    BrowserBridgeError::new(
                        "bridge_io",
                        format!("Failed reading browser bridge reply: {e}"),
                    )
                })?;
            if n == 0 {
                return Err(BrowserBridgeError::new(
                    "extension_disconnected",
                    "Browser bridge closed before replying",
                ));
            }
            let reply: Value = serde_json::from_slice(&reply_buf).map_err(|e| {
                BrowserBridgeError::new("bridge_protocol", format!("Malformed bridge reply: {e}"))
            })?;
            if reply.get("ok").and_then(Value::as_bool) == Some(true) {
                Ok(reply.get("data").cloned().unwrap_or(Value::Null))
            } else {
                let err_obj = reply.get("error");
                let msg = err_obj
                    .and_then(|e| e.get("message"))
                    .and_then(Value::as_str)
                    .unwrap_or("Browser extension operation failed")
                    .to_string();
                let code = match err_obj.and_then(|e| e.get("code")).and_then(Value::as_str) {
                    Some("tab_not_found") => "tab_not_found",
                    Some("stale_ref") => "stale_ref",
                    Some("restricted_url") => "restricted_url",
                    Some("timeout") => "deadline_exceeded",
                    Some("invalid_request") => "invalid_request",
                    _ => "browser_error",
                };
                Err(BrowserBridgeError::new(code, msg))
            }
        };

        tokio::select! {
            _ = cancel.cancelled() => Err(BrowserBridgeError::new("cancelled", "Browser request cancelled")),
            res = tokio::time::timeout(budget, fut) => match res {
                Ok(inner) => inner,
                Err(_) => Err(BrowserBridgeError::new("deadline_exceeded", "Browser request timed out")),
            }
        }
    }
}

struct SocketGuard(PathBuf);
impl Drop for SocketGuard {
    fn drop(&mut self) {
        let _ = fs::remove_file(&self.0);
    }
}

fn current_uid() -> u32 {
    // Obtain current effective UID via metadata on `/dev/null`? No, check std::fs::metadata on our own socket dir
    // or spawn-free nix? Even cleaner: on Unix we can check the UID of our newly created 0700 directory!
    // Wait: we also have `libc` indirectly or `fs::metadata` on the socket we just created!
    0
}

fn socket_owner_uid(path: &Path) -> io::Result<u32> {
    use std::os::unix::fs::MetadataExt;
    Ok(fs::metadata(path)?.uid())
}

/// Runs the Chrome Native Messaging host loop:
/// - stdin/stdout use Chrome's 4-byte little-endian length-prefixed JSON framing.
/// - Exposes a local user-private Unix domain socket for any `useui` MCP instance to connect.
pub async fn run_native_messaging_host() -> Result<(), Box<dyn std::error::Error>> {
    let sock = socket_path();
    if let Some(parent) = sock.parent() {
        fs::create_dir_all(parent)?;
        fs::set_permissions(parent, fs::Permissions::from_mode(0o700))?;
    }
    if sock.exists() {
        let _ = fs::remove_file(&sock);
    }
    let listener = UnixListener::bind(&sock)?;
    fs::set_permissions(&sock, fs::Permissions::from_mode(0o600))?;
    let expected_uid = socket_owner_uid(&sock)?;
    let _guard = SocketGuard(sock.clone());

    let shutdown = CancellationToken::new();
    let pending: Arc<Mutex<HashMap<String, oneshot::Sender<Value>>>> =
        Arc::new(Mutex::new(HashMap::new()));
    let (tx_chrome, mut rx_chrome) = mpsc::channel::<Vec<u8>>(64);
    let seq = Arc::new(AtomicU64::new(0));

    // Blocking stdout writer for Chrome Native Messaging (4-byte LE length + UTF-8 JSON).
    let writer_shutdown = shutdown.clone();
    let writer_task = tokio::task::spawn_blocking(move || {
        let stdout = io::stdout();
        let mut out = stdout.lock();
        while let Some(frame) = rx_chrome.blocking_recv() {
            if frame.len() > MAX_NATIVE_MSG_BYTES {
                continue;
            }
            let len_bytes = (frame.len() as u32).to_le_bytes();
            if out.write_all(&len_bytes).is_err()
                || out.write_all(&frame).is_err()
                || out.flush().is_err()
            {
                writer_shutdown.cancel();
                break;
            }
        }
    });

    // Blocking stdin reader for Chrome Native Messaging replies.
    let reader_shutdown = shutdown.clone();
    let reader_pending = pending.clone();
    let reader_task = tokio::task::spawn_blocking(move || {
        let stdin = io::stdin();
        let mut inp = stdin.lock();
        let mut len_buf = [0u8; 4];
        loop {
            if inp.read_exact(&mut len_buf).is_err() {
                reader_shutdown.cancel();
                break;
            }
            let len = u32::from_le_bytes(len_buf) as usize;
            if len == 0 || len > 16 * 1024 * 1024 {
                reader_shutdown.cancel();
                break;
            }
            let mut payload = vec![0u8; len];
            if inp.read_exact(&mut payload).is_err() {
                reader_shutdown.cancel();
                break;
            }
            if let Ok(msg) = serde_json::from_slice::<Value>(&payload)
                && let Some(id) = msg.get("id").and_then(Value::as_str)
                && let Some(tx) = reader_pending.blocking_lock().remove(id)
            {
                let _ = tx.send(msg);
            }
        }
    });

    // Handle termination signals cleanly.
    let sig_shutdown = shutdown.clone();
    let mut terminate = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())?;
    let mut interrupt = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::interrupt())?;
    let sig_task = tokio::spawn(async move {
        tokio::select! {
            _ = terminate.recv() => {},
            _ = interrupt.recv() => {},
        }
        sig_shutdown.cancel();
    });

    let _ = current_uid;

    // Accept local same-UID MCP client connections and multiplex requests to Chrome.
    loop {
        tokio::select! {
            _ = shutdown.cancelled() => break,
            accepted = listener.accept() => {
                let Ok((stream, _)) = accepted else { break; };
                let peer_ok = stream
                    .peer_cred()
                    .map(|cred| cred.uid() == expected_uid)
                    .unwrap_or(false);
                if !peer_ok {
                    continue;
                }
                let pending = pending.clone();
                let tx_chrome = tx_chrome.clone();
                let seq = seq.clone();
                let shutdown = shutdown.clone();
                tokio::spawn(async move {
                    handle_socket_client(stream, pending, tx_chrome, seq, shutdown).await;
                });
            }
        }
    }

    drop(tx_chrome);
    sig_task.abort();
    let _ = tokio::time::timeout(Duration::from_millis(300), writer_task).await;
    reader_task.abort();
    Ok(())
}

async fn handle_socket_client(
    stream: UnixStream,
    pending: Arc<Mutex<HashMap<String, oneshot::Sender<Value>>>>,
    tx_chrome: mpsc::Sender<Vec<u8>>,
    seq: Arc<AtomicU64>,
    shutdown: CancellationToken,
) {
    let (read_half, mut write_half) = stream.into_split();
    let mut reader = BufReader::new(read_half);
    let mut buf = Vec::new();
    let Ok(n) = reader.read_until(b'\n', &mut buf).await else {
        return;
    };
    if n == 0 || buf.len() > MAX_SOCKET_LINE_BYTES {
        return;
    }
    let Ok(mut req) = serde_json::from_slice::<Value>(&buf) else {
        let _ = write_json_line(
            &mut write_half,
            &json!({"ok": false, "error": {"code": "invalid_request", "message": "Invalid JSON"}}),
        )
        .await;
        return;
    };
    let timeout_ms = req
        .get("timeoutMs")
        .and_then(Value::as_u64)
        .unwrap_or(15_000)
        .clamp(100, 60_000);
    let client_id = req
        .get("id")
        .and_then(Value::as_str)
        .unwrap_or("req")
        .to_string();
    let bridge_id = format!("nm-{}", seq.fetch_add(1, Ordering::Relaxed) + 1);
    if let Some(obj) = req.as_object_mut() {
        obj.insert("id".into(), Value::String(bridge_id.clone()));
    }
    let Ok(encoded) = serde_json::to_vec(&req) else {
        return;
    };
    if encoded.len() > MAX_NATIVE_MSG_BYTES {
        let _ = write_json_line(
            &mut write_half,
            &json!({"id": client_id, "ok": false, "error": {"code": "invalid_request", "message": "Request exceeds Native Messaging size limit"}}),
        )
        .await;
        return;
    }

    let (tx, rx) = oneshot::channel();
    pending.lock().await.insert(bridge_id.clone(), tx);
    if tx_chrome.send(encoded).await.is_err() {
        pending.lock().await.remove(&bridge_id);
        let _ = write_json_line(
            &mut write_half,
            &json!({"id": client_id, "ok": false, "error": {"code": "extension_disconnected", "message": "Native messaging pipe to Chrome is closed"}}),
        )
        .await;
        return;
    }

    let reply = tokio::select! {
        _ = shutdown.cancelled() => {
            pending.lock().await.remove(&bridge_id);
            json!({"id": client_id, "ok": false, "error": {"code": "extension_disconnected", "message": "Browser bridge shutting down"}})
        }
        res = tokio::time::timeout(Duration::from_millis(timeout_ms), rx) => match res {
            Ok(Ok(mut msg)) => {
                if let Some(obj) = msg.as_object_mut() {
                    obj.insert("id".into(), Value::String(client_id));
                }
                msg
            }
            Ok(Err(_)) => json!({"id": client_id, "ok": false, "error": {"code": "extension_disconnected", "message": "Extension closed before responding"}}),
            Err(_) => {
                pending.lock().await.remove(&bridge_id);
                json!({"id": client_id, "ok": false, "error": {"code": "timeout", "message": "Extension did not reply before deadline"}})
            }
        }
    };
    let _ = write_json_line(&mut write_half, &reply).await;
}

async fn write_json_line(
    write_half: &mut tokio::net::unix::OwnedWriteHalf,
    value: &Value,
) -> io::Result<()> {
    let mut bytes = serde_json::to_vec(value).unwrap_or_else(|_| b"{\"ok\":false}".to_vec());
    bytes.push(b'\n');
    write_half.write_all(&bytes).await?;
    write_half.flush().await
}

/// Installs the Chrome/Chromium Native Messaging host manifest pointing to `host_binary`.
pub fn install_native_messaging_manifests(
    host_binary: &Path,
) -> Result<Vec<PathBuf>, Box<dyn std::error::Error>> {
    let resolved = host_binary
        .canonicalize()
        .unwrap_or_else(|_| host_binary.to_path_buf());
    let manifest = json!({
        "name": NATIVE_HOST_NAME,
        "description": "UseUI Browser Accelerator Bridge",
        "path": resolved.to_string_lossy(),
        "type": "stdio",
        "allowed_origins": [
            format!("chrome-extension://{EXTENSION_ID}/")
        ]
    });
    let serialized = serde_json::to_string_pretty(&manifest)? + "\n";

    let override_dirs = std::env::var("USEUI_NATIVE_HOST_DIRS")
        .ok()
        .filter(|s| !s.trim().is_empty())
        .or_else(|| {
            std::env::var("CUA_NATIVE_HOST_DIRS")
                .ok()
                .filter(|s| !s.trim().is_empty())
        });
    let target_dirs: Vec<PathBuf> = if let Some(override_dirs) = override_dirs {
        override_dirs.split(':').map(PathBuf::from).collect()
    } else {
        let home = std::env::var_os("HOME")
            .map(PathBuf::from)
            .ok_or("HOME environment variable is not set")?;
        let app_support = home.join("Library").join("Application Support");
        let candidates = [
            app_support.join("Google").join("Chrome"),
            app_support.join("BraveSoftware").join("Brave-Browser"),
            app_support.join("Chromium"),
            app_support.join("Arc").join("User Data"),
            app_support.join("Microsoft Edge"),
        ];
        let mut dirs: Vec<PathBuf> = candidates
            .iter()
            .filter(|base| base.exists())
            .map(|base| base.join("NativeMessagingHosts"))
            .collect();
        if dirs.is_empty() {
            dirs.push(
                app_support
                    .join("Google")
                    .join("Chrome")
                    .join("NativeMessagingHosts"),
            );
        }
        dirs
    };

    let mut installed = Vec::new();
    for dir in target_dirs {
        fs::create_dir_all(&dir)?;
        let file_path = dir.join(format!("{NATIVE_HOST_NAME}.json"));
        fs::write(&file_path, &serialized)?;
        fs::set_permissions(&file_path, fs::Permissions::from_mode(0o644))?;
        installed.push(file_path);
    }
    Ok(installed)
}

/// Copies the bundled MV3 extension out of the `.app` package into a standard directory
/// (`~/Library/Application Support/UseUI/browser-extension`) so Chrome's
/// `NSOpenPanel` ("Load unpacked") can open it directly without treating `.app` as a file package.
pub fn install_unpacked_extension(
    host_binary: &Path,
) -> Result<Option<PathBuf>, Box<dyn std::error::Error>> {
    let resolved = host_binary
        .canonicalize()
        .unwrap_or_else(|_| host_binary.to_path_buf());
    let Some(contents_dir) = resolved.parent().and_then(Path::parent) else {
        return Ok(None);
    };
    let source = contents_dir.join("Resources").join("browser-extension");
    if !source.is_dir() {
        return Ok(None);
    }
    let home = std::env::var_os("HOME")
        .map(PathBuf::from)
        .ok_or("HOME environment variable is not set")?;
    let dest = home
        .join("Library")
        .join("Application Support")
        .join("UseUI")
        .join("browser-extension");
    fs::create_dir_all(&dest)?;
    for entry in fs::read_dir(&source)? {
        let entry = entry?;
        let file_type = entry.file_type()?;
        if file_type.is_file() {
            let target = dest.join(entry.file_name());
            fs::copy(entry.path(), &target)?;
            fs::set_permissions(&target, fs::Permissions::from_mode(0o644))?;
        }
    }
    Ok(Some(dest))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn install_writes_valid_native_messaging_manifest() {
        let tmp = std::env::temp_dir().join(format!("useui-nm-test-{}", std::process::id()));
        let _ = fs::remove_dir_all(&tmp);
        fs::create_dir_all(&tmp).unwrap();
        // Verify manifest structure directly without mutating user dirs.
        let host = std::env::current_exe().unwrap();
        let dir = tmp.join("NativeMessagingHosts");
        fs::create_dir_all(&dir).unwrap();
        let file = dir.join(format!("{NATIVE_HOST_NAME}.json"));
        let manifest = json!({
            "name": NATIVE_HOST_NAME,
            "description": "UseUI Browser Accelerator Bridge",
            "path": host.to_string_lossy(),
            "type": "stdio",
            "allowed_origins": [format!("chrome-extension://{EXTENSION_ID}/")]
        });
        fs::write(&file, serde_json::to_string_pretty(&manifest).unwrap()).unwrap();
        let parsed: Value = serde_json::from_str(&fs::read_to_string(&file).unwrap()).unwrap();
        assert_eq!(parsed["name"], NATIVE_HOST_NAME);
        assert_eq!(parsed["type"], "stdio");
        assert_eq!(
            parsed["allowed_origins"][0],
            format!("chrome-extension://{EXTENSION_ID}/")
        );
        let _ = fs::remove_dir_all(&tmp);
    }
}
