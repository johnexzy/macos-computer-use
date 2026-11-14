use crate::{
    ACTIVE, Call, ClientError, ClientErrorKind, Config, QUEUED, Shared, UncertainAct, next_id,
    process::{Event, Transport},
};
use cua_protocol::*;
use std::{
    sync::{
        Arc,
        atomic::{AtomicU64, Ordering},
    },
    time::Duration,
};
use tokio::{io::AsyncWriteExt, sync::mpsc, time::Instant};
use tokio_util::sync::CancellationToken;

const GRACE: Duration = Duration::from_millis(250);

pub(crate) async fn handshake(
    transport: &mut Transport,
    config: &Config,
) -> Result<String, ClientError> {
    let request = Request {
        version: VERSION,
        id: "host-1".into(),
        epoch: None,
        budget_ms: config.handshake_budget.as_millis() as u32,
        body: RequestBody::Hello(HelloRequest {
            client_name: "cua-client".into(),
            supported_versions: vec![VERSION],
            authority: config.authority.clone(),
        }),
    };
    let bytes = encode_line(&Frame::Request(request.clone())).map_err(|_| {
        ClientError::new(
            ClientErrorKind::InvalidConfig,
            "invalid host authority configuration",
        )
    })?;
    let result = tokio::time::timeout(config.handshake_budget, async {
        transport
            .stdin
            .as_mut()
            .expect("helper stdin")
            .write_all(&bytes)
            .await
            .map_err(|_| ())?;
        match transport.next_event().await {
            Some(Event::Frame(Frame::Response(response))) => {
                response
                    .validate_for(&request, &response.epoch)
                    .map_err(|_| ())?;
                if !matches!(response.body, ResponseBody::Hello(_)) {
                    return Err(());
                }
                Ok(response.epoch)
            }
            _ => Err(()),
        }
    })
    .await;
    result.unwrap_or(Err(())).map_err(|_| {
        ClientError::new(
            ClientErrorKind::HandshakeFailed,
            "native helper handshake failed",
        )
    })
}

pub(crate) async fn run(
    mut transport: Transport,
    mut calls: mpsc::Receiver<Call>,
    stop: CancellationToken,
    shared: Arc<Shared>,
    authority: Authority,
    ids: Arc<AtomicU64>,
) {
    loop {
        let call = tokio::select! { biased;
            _ = stop.cancelled() => break,
            _ = transport.next_event() => break, // Any unsolicited frame or EOF closes this session.
            call = calls.recv() => match call { Some(call) => call, None => break },
        };
        if call
            .admission
            .compare_exchange(QUEUED, ACTIVE, Ordering::SeqCst, Ordering::SeqCst)
            .is_err()
        {
            continue;
        }
        let (result, close) = exchange(
            &mut transport,
            &call.request,
            call.deadline,
            &call.cancel,
            &stop,
            &authority,
            &ids,
        )
        .await;
        shared.record(&call.request, call.started, &result);
        let _ = call.reply.send(result);
        if close || stop.is_cancelled() {
            break;
        }
    }
    shared.closed.store(true, Ordering::Release);
    calls.close();
    while let Ok(call) = calls.try_recv() {
        if call
            .admission
            .compare_exchange(QUEUED, ACTIVE, Ordering::SeqCst, Ordering::SeqCst)
            .is_ok()
        {
            let result = interrupted(&call.request, &[], ClientErrorKind::Closed, false);
            shared.record(&call.request, call.started, &result);
            let _ = call.reply.send(result);
        }
    }
    let exit = transport.shutdown().await;
    *shared.helper_exit.lock().expect("exit mutex") = exit;
}

async fn exchange(
    transport: &mut Transport,
    original: &Request,
    deadline: Instant,
    cancel: &CancellationToken,
    stop: &CancellationToken,
    authority: &Authority,
    ids: &AtomicU64,
) -> (Result<Response, ClientError>, bool) {
    if stop.is_cancelled() {
        return (
            interrupted(original, &[], ClientErrorKind::Closed, false),
            true,
        );
    }
    if cancel.is_cancelled() {
        return (
            interrupted(original, &[], ClientErrorKind::Cancelled, false),
            false,
        );
    }
    let remaining = deadline
        .saturating_duration_since(Instant::now())
        .as_millis();
    if remaining == 0 {
        return (
            interrupted(original, &[], ClientErrorKind::DeadlineExceeded, false),
            false,
        );
    }
    let mut request = original.clone();
    request.budget_ms = remaining as u32;
    let bytes = match encode_line(&Frame::Request(request.clone())) {
        Ok(bytes) => bytes,
        Err(_) => {
            return (
                Err(ClientError::new(
                    ClientErrorKind::InvalidRequest,
                    "request violates native contract",
                )),
                false,
            );
        }
    };
    let mut started_write = false;
    let write_result = {
        let write = async {
            started_write = true;
            transport
                .stdin
                .as_mut()
                .expect("helper stdin")
                .write_all(&bytes)
                .await
        };
        tokio::select! { biased;
            _ = stop.cancelled() => Err(ClientErrorKind::Closed),
            _ = cancel.cancelled() => Err(ClientErrorKind::Cancelled),
            _ = tokio::time::sleep_until(deadline) => Err(ClientErrorKind::DeadlineExceeded),
            result = write => result.map_err(|_| ClientErrorKind::HelperDied),
        }
    };
    let mut prefix = Vec::new();
    if let Err(kind) = write_result {
        if !started_write {
            return (
                interrupted(&request, &prefix, kind, false),
                kind == ClientErrorKind::Closed,
            );
        }
        return terminate(transport, &request, &mut prefix, kind, true, authority).await;
    }
    loop {
        let event = tokio::select! { biased;
            _ = stop.cancelled() => Err(ClientErrorKind::Closed),
            _ = cancel.cancelled() => Err(ClientErrorKind::Cancelled),
            _ = tokio::time::sleep_until(deadline) => Err(ClientErrorKind::DeadlineExceeded),
            event = transport.next_event() => Ok(event),
        };
        match event {
            Ok(Some(Event::Frame(Frame::Progress(progress)))) => {
                if accept_progress(&request, &mut prefix, progress).is_err() {
                    return terminate(
                        transport,
                        &request,
                        &mut prefix,
                        ClientErrorKind::ProtocolError,
                        true,
                        authority,
                    )
                    .await;
                }
            }
            Ok(Some(Event::Frame(Frame::Response(response)))) => {
                if accept_final(&request, &prefix, &response, authority).is_err() {
                    return terminate(
                        transport,
                        &request,
                        &mut prefix,
                        ClientErrorKind::ProtocolError,
                        true,
                        authority,
                    )
                    .await;
                }
                return (Ok(response), false);
            }
            Ok(Some(Event::Frame(Frame::Request(_))) | Some(Event::Invalid)) => {
                return terminate(
                    transport,
                    &request,
                    &mut prefix,
                    ClientErrorKind::ProtocolError,
                    true,
                    authority,
                )
                .await;
            }
            Ok(None | Some(Event::Eof)) => {
                // The reader sends complete frames in order before EOF.
                return terminate(
                    transport,
                    &request,
                    &mut prefix,
                    ClientErrorKind::HelperDied,
                    true,
                    authority,
                )
                .await;
            }
            Err(kind) => {
                let control = Request {
                    version: VERSION,
                    id: next_id(ids),
                    epoch: request.epoch.clone(),
                    budget_ms: GRACE.as_millis() as u32,
                    body: RequestBody::Cancel(CancelRequest {
                        request_id: request.id.clone(),
                    }),
                };
                match cancel_and_collect(transport, &request, &control, &mut prefix, authority)
                    .await
                {
                    Ok((Some(response), reusable)) => {
                        if !reusable {
                            let _ = transport.shutdown().await;
                        }
                        return (
                            interrupted_final(&request, response, kind),
                            !reusable || kind == ClientErrorKind::Closed,
                        );
                    }
                    Ok((None, _)) => {
                        return terminate(transport, &request, &mut prefix, kind, true, authority)
                            .await;
                    }
                    Err(()) => {
                        return terminate(
                            transport,
                            &request,
                            &mut prefix,
                            ClientErrorKind::ProtocolError,
                            true,
                            authority,
                        )
                        .await;
                    }
                }
            }
        }
    }
}

fn accept_progress(
    request: &Request,
    prefix: &mut Vec<StepReceipt>,
    progress: Progress,
) -> Result<(), ()> {
    progress
        .validate_for(request, request.epoch.as_deref().expect("active epoch"))
        .map_err(|_| ())?;
    if progress.steps.len() != prefix.len() + 1 || !progress.steps.starts_with(prefix) {
        return Err(());
    }
    *prefix = progress.steps;
    Ok(())
}

fn accept_final(
    request: &Request,
    prefix: &[StepReceipt],
    response: &Response,
    authority: &Authority,
) -> Result<(), ()> {
    response
        .validate_for(request, request.epoch.as_deref().expect("active epoch"))
        .map_err(|_| ())?;
    match &response.body {
        ResponseBody::Act(result) if !result.steps.starts_with(prefix) => Err(()),
        ResponseBody::Error(_) if !prefix.is_empty() => Err(()),
        ResponseBody::Capabilities(caps) if caps.mode != authority.mode => Err(()),
        _ => Ok(()),
    }
}

async fn cancel_and_collect(
    transport: &mut Transport,
    request: &Request,
    control: &Request,
    prefix: &mut Vec<StepReceipt>,
    authority: &Authority,
) -> Result<(Option<Response>, bool), ()> {
    let bytes = encode_line(&Frame::Request(control.clone())).map_err(|_| ())?;
    let deadline = Instant::now() + GRACE;
    let write = tokio::time::timeout_at(
        deadline,
        transport
            .stdin
            .as_mut()
            .expect("helper stdin")
            .write_all(&bytes),
    )
    .await;
    if !matches!(write, Ok(Ok(()))) {
        return Ok((None, false));
    }
    let mut ack = false;
    let mut final_response = None;
    loop {
        let event = match tokio::time::timeout_at(deadline, transport.next_event()).await {
            Ok(event) => event,
            Err(_) => return Ok((final_response, false)),
        };
        match event {
            Some(Event::Frame(Frame::Progress(progress))) if final_response.is_none() => {
                accept_progress(request, prefix, progress)?
            }
            Some(Event::Frame(Frame::Response(response))) if response.id == control.id && !ack => {
                response
                    .validate_for(control, control.epoch.as_deref().expect("control epoch"))
                    .map_err(|_| ())?;
                ack = true;
            }
            Some(Event::Frame(Frame::Response(response))) if final_response.is_none() => {
                accept_final(request, prefix, &response, authority)?;
                final_response = Some(response);
            }
            Some(Event::Eof) | None => return Ok((final_response, false)),
            _ => return Err(()),
        }
        if ack && final_response.is_some() {
            return Ok((final_response, true));
        }
    }
}

async fn terminate(
    transport: &mut Transport,
    request: &Request,
    prefix: &mut Vec<StepReceipt>,
    mut kind: ClientErrorKind,
    may_have_dispatched: bool,
    authority: &Authority,
) -> (Result<Response, ClientError>, bool) {
    transport.stop();
    let until = Instant::now() + GRACE;
    let mut final_response = None;
    if kind != ClientErrorKind::ProtocolError {
        loop {
            match tokio::time::timeout_at(until, transport.next_event()).await {
                Ok(Some(Event::Frame(Frame::Progress(progress)))) if final_response.is_none() => {
                    if accept_progress(request, prefix, progress).is_err() {
                        kind = ClientErrorKind::ProtocolError;
                        break;
                    }
                }
                Ok(Some(Event::Frame(Frame::Response(response)))) if final_response.is_none() => {
                    if accept_final(request, prefix, &response, authority).is_err() {
                        kind = ClientErrorKind::ProtocolError;
                        break;
                    }
                    final_response = Some(response);
                }
                Ok(Some(Event::Eof) | None) | Err(_) => break,
                _ => {
                    kind = ClientErrorKind::ProtocolError;
                    break;
                }
            }
        }
    }
    let _ = transport.shutdown().await;
    if kind == ClientErrorKind::ProtocolError {
        return (Err(protocol_failure(request, prefix)), true);
    }
    if let Some(response) = final_response {
        return (interrupted_final(request, response, kind), true);
    }
    if !transport.eof_drained && may_have_dispatched && matches!(request.body, RequestBody::Act(_))
    {
        return (
            Err(uncertain_failure(
                request,
                prefix,
                kind,
                "native output did not settle; action suffix remains uncertain",
            )),
            true,
        );
    }
    (
        interrupted(request, prefix, kind, may_have_dispatched),
        true,
    )
}

fn interrupted_final(
    request: &Request,
    mut response: Response,
    kind: ClientErrorKind,
) -> Result<Response, ClientError> {
    if let ResponseBody::Act(result) = &mut response.body {
        if result.stop_reason == StopReason::Completed {
            result.stop_reason = terminal(kind).1;
        }
        return Ok(response);
    }
    // A validated pre-dispatch native rejection remains useful evidence that no input was sent.
    if matches!(request.body, RequestBody::Act(_)) {
        return Ok(response);
    }
    Err(interruption_error(kind))
}

fn terminal(kind: ClientErrorKind) -> (ReceiptReason, StopReason) {
    match kind {
        ClientErrorKind::DeadlineExceeded => (
            ReceiptReason::DeadlineExceeded,
            StopReason::DeadlineExceeded,
        ),
        ClientErrorKind::HelperDied => (ReceiptReason::HelperDied, StopReason::HelperDied),
        _ => (ReceiptReason::Cancelled, StopReason::Cancelled),
    }
}

pub(crate) fn interrupted(
    request: &Request,
    prefix: &[StepReceipt],
    kind: ClientErrorKind,
    may_have_dispatched: bool,
) -> Result<Response, ClientError> {
    let RequestBody::Act(act) = &request.body else {
        return Err(interruption_error(kind));
    };
    let mut steps = prefix.to_vec();
    let (reason, stop_reason) = terminal(kind);
    if let Some(step) = act.steps.get(steps.len()) {
        steps.push(StepReceipt {
            route: None,
            action_id: step.action_id.clone(),
            delivery: if may_have_dispatched && !matches!(step.operation, Operation::WaitFor(_)) {
                Delivery::Unknown
            } else {
                Delivery::NotDispatched
            },
            verification: Verification::Unverified,
            reason: Some(reason),
            evidence: Vec::new(),
        });
    }
    let remaining_steps = (act.steps.len() - steps.len()) as u16;
    Ok(Response {
        version: VERSION,
        id: request.id.clone(),
        epoch: request.epoch.clone().expect("active epoch"),
        body: ResponseBody::Act(ActResult {
            observation_id: act.observation_id.clone(),
            steps,
            remaining_steps,
            stop_reason,
            feedback: None,
        }),
    })
}

fn interruption_error(kind: ClientErrorKind) -> ClientError {
    ClientError::new(
        kind,
        match kind {
            ClientErrorKind::DeadlineExceeded => "native request deadline exceeded",
            ClientErrorKind::Cancelled => "native request cancelled",
            ClientErrorKind::HelperDied => "native helper exited before replying",
            _ => "native connection closed",
        },
    )
}

fn protocol_failure(request: &Request, prefix: &[StepReceipt]) -> ClientError {
    uncertain_failure(
        request,
        prefix,
        ClientErrorKind::ProtocolError,
        "native helper violated the wire contract",
    )
}

fn uncertain_failure(
    request: &Request,
    prefix: &[StepReceipt],
    kind: ClientErrorKind,
    message: &'static str,
) -> ClientError {
    let mut error = ClientError::new(kind, message);
    if let RequestBody::Act(act) = &request.body {
        error.uncertainty = Some(UncertainAct {
            observation_id: act.observation_id.clone(),
            settled_steps: prefix.to_vec(),
            unacknowledged_action_ids: act.steps[prefix.len()..]
                .iter()
                .map(|step| step.action_id.clone())
                .collect(),
        });
    }
    error
}

pub(crate) fn lost_coordinator(request: &Request) -> ClientError {
    let mut error = protocol_failure(request, &[]);
    error.kind = ClientErrorKind::Closed;
    error.message = "native coordinator stopped without a receipt";
    error
}
