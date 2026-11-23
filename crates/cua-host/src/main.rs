use cua_client::{Client, Config};
use cua_host::Host;
use cua_protocol::{Authority, ExecutionMode};
use rmcp::ServiceExt;
use std::{
    io,
    path::PathBuf,
    pin::Pin,
    sync::Arc,
    task::{Context, Poll},
    time::{Duration, SystemTime, UNIX_EPOCH},
};
use tokio::io::{AsyncRead, ReadBuf};
use tokio_util::sync::CancellationToken;

struct ConnectionReader<R> {
    inner: R,
    disconnected: CancellationToken,
    service: CancellationToken,
    line_bytes: usize,
}
impl<R: AsyncRead + Unpin> AsyncRead for ConnectionReader<R> {
    fn poll_read(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &mut ReadBuf<'_>,
    ) -> Poll<io::Result<()>> {
        let before = buf.filled().len();
        let capacity = buf.remaining();
        let result = Pin::new(&mut self.inner).poll_read(cx, buf);
        if matches!(&result, Poll::Ready(Ok(()))) {
            for byte in &buf.filled()[before..] {
                self.line_bytes += 1;
                if self.line_bytes > cua_protocol::MAX_FRAME_BYTES {
                    self.disconnected.cancel();
                    self.service.cancel();
                    return Poll::Ready(Err(io::Error::new(
                        io::ErrorKind::InvalidData,
                        "MCP frame exceeds limit",
                    )));
                }
                if *byte == b'\n' {
                    self.line_bytes = 0;
                }
            }
        }
        if matches!(&result, Poll::Ready(Err(_)))
            || matches!(&result, Poll::Ready(Ok(())) if capacity > 0 && before == buf.filled().len())
        {
            self.disconnected.cancel();
            self.service.cancel();
        }
        result
    }
}

fn main() {
    let runtime = tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()
        .expect("Tokio runtime");
    let result = runtime.block_on(run());
    // macOS stdin uses a blocking Tokio read. Native cleanup has completed before this bound.
    runtime.shutdown_timeout(Duration::from_millis(200));
    if let Err(error) = result {
        eprintln!("{error}");
        std::process::exit(1);
    }
}

async fn run() -> Result<(), Box<dyn std::error::Error>> {
    let raw_args: Vec<std::ffi::OsString> = std::env::args_os().skip(1).collect();
    // Chrome launches Native Messaging hosts with `chrome-extension://<id>/` as argv[1].
    if raw_args.iter().any(|arg| {
        arg.to_str()
            .is_some_and(|s| s == "--native-messaging-host" || s.starts_with("chrome-extension://"))
    }) {
        return cua_host::browser_bridge::run_native_messaging_host().await;
    }

    // MCP clients may launch a symlink outside the archive. Resolve its real
    // location before selecting the sibling helper, independently of cwd/PATH.
    let self_exe = std::env::current_exe()?.canonicalize()?;
    let mut helper = self_exe.with_file_name("cua-runtime");
    let mut mode = ExecutionMode::BackgroundRequired;
    let mut args = raw_args.into_iter();
    while let Some(arg) = args.next() {
        match arg.to_str() {
            Some("--helper") => {
                helper = PathBuf::from(args.next().ok_or("--helper requires a path")?)
            }
            Some("--allow-foreground") => mode = ExecutionMode::ForegroundAllowed,
            Some("--install-browser-bridge") => {
                let installed =
                    cua_host::browser_bridge::install_native_messaging_manifests(&self_exe)?;
                for path in installed {
                    println!("Installed Native Messaging manifest: {}", path.display());
                }
                if let Some(ext_dir) =
                    cua_host::browser_bridge::install_unpacked_extension(&self_exe)?
                {
                    println!("Installed Unpacked Extension: {}", ext_dir.display());
                }
                println!(
                    "Extension ID: {}",
                    cua_host::browser_bridge::EXTENSION_ID
                );
                return Ok(());
            }
            Some("--version") => {
                println!("cua-host {}", env!("CARGO_PKG_VERSION"));
                return Ok(());
            }
            Some("--help") => {
                println!(
                    "cua-host [--helper PATH] [--allow-foreground] [--native-messaging-host] [--install-browser-bridge]\nMCP stdio server; execution mode is installed by the operator."
                );
                return Ok(());
            }
            _ => return Err("Unknown host argument; use --help".into()),
        }
    }
    let authority = Authority {
        grant_id: format!(
            "host-{}-{}",
            std::process::id(),
            SystemTime::now().duration_since(UNIX_EPOCH)?.as_nanos()
        ),
        mode,
    };
    let disconnected = CancellationToken::new();
    let service_token = CancellationToken::new();
    let signal_disconnect = disconnected.clone();
    let signal_service = service_token.clone();
    #[cfg(unix)]
    let mut terminate = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())?;
    #[cfg(unix)]
    let mut interrupt = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::interrupt())?;
    let signals = tokio::spawn(async move {
        #[cfg(unix)]
        {
            tokio::select! { _ = interrupt.recv() => {}, _ = terminate.recv() => {} }
        }
        #[cfg(not(unix))]
        {
            let _ = tokio::signal::ctrl_c().await;
        }
        signal_disconnect.cancel();
        signal_service.cancel();
    });
    // Monitor stdin before native hello. The bounded pipe also preserves input read ahead.
    let (input, mut feed) = tokio::io::duplex(64 * 1024);
    let mut reader = ConnectionReader {
        inner: tokio::io::stdin(),
        disconnected: disconnected.clone(),
        service: service_token.clone(),
        line_bytes: 0,
    };
    let input_disconnect = disconnected.clone();
    let input_service = service_token.clone();
    let input_pump = tokio::spawn(async move {
        let _ = tokio::io::copy(&mut reader, &mut feed).await;
        input_disconnect.cancel();
        input_service.cancel();
    });
    let client =
        match Client::spawn_with_cancellation(Config::new(helper, authority), disconnected.clone())
            .await
        {
            Ok(client) => Arc::new(client),
            Err(_) if disconnected.is_cancelled() => {
                signals.abort();
                input_pump.abort();
                return Ok(());
            }
            Err(error) => return Err(error.into()),
        };
    eprintln!(
        "{}",
        serde_json::json!({"event":"runtime_started","helperPid":client.helper_pid(),"epoch":client.epoch(),"mode":mode})
    );
    let transport = (input, tokio::io::stdout());
    let result = match Host::new(client.clone(), disconnected.clone())
        .serve_with_ct(transport, service_token)
        .await
    {
        Ok(service) => service
            .waiting()
            .await
            .map(|_| ())
            .map_err(|_| "MCP transport failed"),
        Err(_) => Err("MCP transport failed"),
    };
    disconnected.cancel();
    client.shutdown().await;
    signals.abort();
    input_pump.abort();
    result.map_err(Into::into)
}
