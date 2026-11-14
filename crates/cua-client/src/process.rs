use crate::{ClientError, ClientErrorKind, Config, HelperExit};
use cua_protocol::{Frame, MAX_FRAME_BYTES, decode_line};
use std::{
    process::Stdio,
    sync::{
        Arc,
        atomic::{AtomicU64, Ordering},
    },
    time::Duration,
};
use tokio::{
    io::{AsyncBufReadExt, AsyncReadExt, BufReader},
    process::{Child, ChildStdin, Command},
    sync::mpsc,
    task::JoinHandle,
};

// Four bounded queue slots; keep decoded frames inline instead of boxing every message.
#[allow(clippy::large_enum_variant)]
pub(crate) enum Event {
    Frame(Frame),
    Eof,
    Invalid,
}

pub(crate) struct Transport {
    pub child: Option<Child>,
    pub stdin: Option<ChildStdin>,
    events: mpsc::Receiver<Event>,
    pub eof_drained: bool,
    reader: Option<JoinHandle<()>>,
    stderr: Option<JoinHandle<()>>,
    exit: Option<HelperExit>,
}

impl Transport {
    pub fn spawn(config: &Config, stderr_bytes: Arc<AtomicU64>) -> Result<Self, ClientError> {
        let mut child = Command::new(&config.program)
            .args(&config.args)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .kill_on_drop(true)
            .spawn()
            .map_err(|_| {
                ClientError::new(
                    ClientErrorKind::SpawnFailed,
                    "could not start native helper",
                )
            })?;
        let stdin = child.stdin.take();
        let stdout = child.stdout.take().expect("piped stdout");
        let mut stderr_pipe = child.stderr.take().expect("piped stderr");
        let (sender, events) = mpsc::channel(4);
        let reader = tokio::spawn(async move {
            let mut reader = BufReader::new(stdout);
            loop {
                match read_frame(&mut reader).await {
                    Ok(Some(frame)) => {
                        if sender.send(Event::Frame(frame)).await.is_err() {
                            return;
                        }
                    }
                    Ok(None) => {
                        let _ = sender.send(Event::Eof).await;
                        return;
                    }
                    Err(()) => {
                        let _ = sender.send(Event::Invalid).await;
                        return;
                    }
                }
            }
        });
        let stderr = tokio::spawn(async move {
            let mut bytes = [0; 1024];
            while let Ok(count) = stderr_pipe.read(&mut bytes).await {
                if count == 0 {
                    break;
                }
                // Count diagnostics without retaining potentially sensitive helper output.
                stderr_bytes.fetch_add(count as u64, Ordering::Relaxed);
            }
        });
        Ok(Self {
            child: Some(child),
            stdin,
            events,
            eof_drained: false,
            reader: Some(reader),
            stderr: Some(stderr),
            exit: None,
        })
    }

    pub fn pid(&self) -> u32 {
        self.child
            .as_ref()
            .and_then(Child::id)
            .expect("running helper")
    }

    pub async fn next_event(&mut self) -> Option<Event> {
        let event = self.events.recv().await;
        if matches!(event, Some(Event::Eof)) {
            self.eof_drained = true;
        }
        event
    }

    pub fn stop(&mut self) {
        self.stdin.take();
        if let Some(child) = self.child.as_mut() {
            let _ = child.start_kill();
        }
    }

    pub async fn shutdown(&mut self) -> Option<HelperExit> {
        // Normal disconnect lets Swift observe EOF and clean up its retained state.
        // Forced fault paths call stop() before entering this method.
        self.stdin.take();
        if let Some(mut child) = self.child.take() {
            let status = match tokio::time::timeout(Duration::from_millis(250), child.wait()).await
            {
                Ok(status) => status.ok(),
                Err(_) => {
                    let _ = child.start_kill();
                    match tokio::time::timeout(Duration::from_secs(1), child.wait()).await {
                        Ok(status) => status.ok(),
                        Err(_) => {
                            tokio::spawn(async move {
                                let _ = child.wait().await;
                            });
                            None
                        }
                    }
                }
            };
            self.exit = status.map(|status| HelperExit {
                success: status.success(),
                code: status.code(),
            });
        }
        if let Some(reader) = self.reader.take() {
            reader.abort();
            let _ = reader.await;
        }
        if let Some(stderr) = self.stderr.take() {
            stderr.abort();
            let _ = stderr.await;
        }
        self.exit.clone()
    }
}

impl Drop for Transport {
    fn drop(&mut self) {
        self.stop();
        if let Some(reader) = &self.reader {
            reader.abort();
        }
        if let Some(stderr) = &self.stderr {
            stderr.abort();
        }
        if let (Some(mut child), Ok(runtime)) =
            (self.child.take(), tokio::runtime::Handle::try_current())
        {
            runtime.spawn(async move {
                let _ = child.wait().await;
            });
        }
    }
}

async fn read_frame(
    reader: &mut BufReader<tokio::process::ChildStdout>,
) -> Result<Option<Frame>, ()> {
    let mut line = Vec::new();
    loop {
        let available = reader.fill_buf().await.map_err(|_| ())?;
        if available.is_empty() {
            return if line.is_empty() { Ok(None) } else { Err(()) };
        }
        let end = available
            .iter()
            .position(|byte| *byte == b'\n')
            .map(|n| n + 1);
        let count = end.unwrap_or(available.len());
        if line.len() + count > MAX_FRAME_BYTES {
            return Err(());
        }
        line.extend_from_slice(&available[..count]);
        reader.consume(count);
        if end.is_some() {
            return decode_line(&line).map(Some).map_err(|_| ());
        }
    }
}
