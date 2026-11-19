use cua_client::{Client, ClientErrorKind, Config};
use cua_protocol::*;
use std::{ffi::OsString, path::PathBuf, sync::Arc, time::Duration};
use tokio::time::{Instant, sleep};
use tokio_util::sync::CancellationToken;

fn config(scenario: &str) -> Config {
    let mut config = Config::new(
        "python3",
        Authority {
            grant_id: "configured-host-grant".into(),
            mode: ExecutionMode::BackgroundRequired,
        },
    );
    config.args = vec![
        OsString::from("-u"),
        PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("tests/support/fake_helper.py")
            .into_os_string(),
        scenario.into(),
    ];
    config
}

async fn peer(scenario: &str) -> Client {
    Client::spawn(config(scenario)).await.unwrap()
}

fn act(count: usize) -> RequestBody {
    RequestBody::Act(ActRequest {
        grant_id: "model-must-not-select-this-grant".into(),
        foreground: false,
        feedback: None,
        observation_id: "observation-1".into(),
        target: TargetKey {
            pid: 42,
            window_id: 7,
        },
        steps: (1..=count)
            .map(|index| ActionStep {
                action_id: format!("action-{index}"),
                operation: Operation::Press(ElementOperation {
                    element_ref: "element-1".into(),
                }),
                precondition: None,
                expect: None,
            })
            .collect(),
    })
}

fn act_result(response: Response) -> ActResult {
    match response.body {
        ResponseBody::Act(result) => result,
        other => panic!("expected act receipt, got {other:?}"),
    }
}

async fn call(client: &Client, body: RequestBody) -> Response {
    client
        .call(body, Duration::from_secs(2), CancellationToken::new())
        .await
        .unwrap()
}

fn process_exists(pid: u32) -> bool {
    std::process::Command::new("kill")
        .args(["-0", &pid.to_string()])
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()
        .unwrap()
        .success()
}

async fn assert_reaped(pid: u32) {
    let until = Instant::now() + Duration::from_secs(2);
    while process_exists(pid) && Instant::now() < until {
        sleep(Duration::from_millis(10)).await;
    }
    assert!(!process_exists(pid), "helper {pid} was not reaped");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn one_persistent_peer_uses_host_authority_and_rejects_public_control() {
    let client = peer("good").await;
    assert_eq!(client.epoch(), "helper-epoch-test");
    let pid = client.helper_pid();
    for expected in ["call-1", "call-2"] {
        let ResponseBody::Targets(targets) = call(
            &client,
            RequestBody::Targets(TargetsRequest { bundle_id: None }),
        )
        .await
        .body
        else {
            panic!()
        };
        assert_eq!(targets.targets[0].key.pid, pid);
        assert_eq!(targets.targets[0].title, expected);
    }
    let result = act_result(call(&client, act(3)).await);
    assert_eq!(result.stop_reason, StopReason::Completed);
    assert_eq!(result.steps.len(), 3);
    for body in [
        RequestBody::Hello(HelloRequest {
            client_name: "model".into(),
            supported_versions: vec![VERSION],
            authority: Authority {
                grant_id: "forged".into(),
                mode: ExecutionMode::ForegroundAllowed,
            },
        }),
        RequestBody::Cancel(CancelRequest {
            request_id: "someone-else".into(),
        }),
    ] {
        let error = client
            .call(body, Duration::from_secs(1), CancellationToken::new())
            .await
            .unwrap_err();
        assert_eq!(error.kind, ClientErrorKind::ForbiddenControl);
        assert!(error.uncertainty.is_none());
    }
    client.shutdown().await;
    assert_reaped(pid).await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn malformed_or_uncorrelated_readonly_responses_close_the_peer() {
    for scenario in [
        "wrong_id",
        "wrong_epoch",
        "wrong_method",
        "truncated",
        "oversize",
    ] {
        let client = peer(scenario).await;
        let pid = client.helper_pid();
        let error = client
            .call(
                RequestBody::Capabilities(Empty {}),
                Duration::from_secs(2),
                CancellationToken::new(),
            )
            .await
            .unwrap_err();
        assert_eq!(
            error.kind,
            ClientErrorKind::ProtocolError,
            "{scenario}: {error}"
        );
        assert!(error.uncertainty.is_none());
        let again = client
            .call(
                RequestBody::Capabilities(Empty {}),
                Duration::from_secs(1),
                CancellationToken::new(),
            )
            .await
            .unwrap_err();
        assert_eq!(again.kind, ClientErrorKind::Closed, "{scenario}");
        client.shutdown().await;
        assert_reaped(pid).await;
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn eof_without_a_reply_is_not_a_successful_read() {
    let client = peer("eof").await;
    let pid = client.helper_pid();
    let error = client
        .call(
            RequestBody::Capabilities(Empty {}),
            Duration::from_secs(1),
            CancellationToken::new(),
        )
        .await
        .unwrap_err();
    assert_eq!(error.kind, ClientErrorKind::HelperDied);
    client.shutdown().await;
    assert_reaped(pid).await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn helper_death_drains_settled_progress_before_synthesizing_uncertainty() {
    let client = peer("eof_after_prefix").await;
    let pid = client.helper_pid();
    let result = act_result(call(&client, act(3)).await);
    assert_eq!(result.observation_id, "observation-1");
    assert_eq!(result.stop_reason, StopReason::HelperDied);
    assert_eq!(result.steps.len(), 2);
    assert_eq!(result.steps[0].action_id, "action-1");
    assert_eq!(result.steps[0].delivery, Delivery::Dispatched);
    assert_eq!(result.steps[1].action_id, "action-2");
    assert_eq!(result.steps[1].delivery, Delivery::Unknown);
    assert_eq!(result.remaining_steps, 1);
    client.shutdown().await;
    assert_reaped(pid).await;

    let client = peer("eof_after_all_progress").await;
    let result = act_result(call(&client, act(3)).await);
    assert_eq!(result.steps.len(), 3);
    assert!(
        result
            .steps
            .iter()
            .all(|receipt| receipt.delivery == Delivery::Dispatched)
    );
    assert_eq!(result.remaining_steps, 0);
    client.shutdown().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_correlated_wait_timeout_survives_host_deadline_reconciliation_but_late_success_does_not()
{
    for scenario in ["late_wait_timeout", "late_wait_satisfied"] {
        let client = peer(scenario).await;
        let request = RequestBody::WaitFor(WaitRequest {
            observation_id: "observation-1".into(),
            target: TargetKey {
                pid: 42,
                window_id: 7,
            },
            condition: Condition::ValueEquals(ValueCondition {
                element_ref: "element-1".into(),
                value: "ready".into(),
            }),
        });
        let result = client
            .call(request, Duration::from_millis(25), CancellationToken::new())
            .await;
        if scenario == "late_wait_timeout" {
            let response = result.expect("correlated negative wait receipt was discarded");
            assert!(
                matches!(response.body, ResponseBody::WaitFor(wait) if wait.outcome == WaitOutcome::TimedOut)
            );
        } else {
            assert_eq!(result.unwrap_err().kind, ClientErrorKind::DeadlineExceeded);
        }
        client.shutdown().await;
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn host_deadline_classifies_cooperative_wait_cancellation_without_losing_evidence() {
    let client = peer("cooperative_wait_cancel").await;
    let condition = Condition::ValueEquals(ValueCondition {
        element_ref: "element-1".into(),
        value: "ready".into(),
    });
    let response = client
        .call(
            RequestBody::WaitFor(WaitRequest {
                observation_id: "observation-1".into(),
                target: TargetKey {
                    pid: 42,
                    window_id: 7,
                },
                condition: condition.clone(),
            }),
            Duration::from_millis(50),
            CancellationToken::new(),
        )
        .await
        .unwrap();
    let ResponseBody::WaitFor(wait) = response.body else {
        panic!("expected negative wait receipt");
    };
    assert_eq!(wait.outcome, WaitOutcome::TimedOut);
    assert!(!wait.already_satisfied);
    let observation = wait
        .observation
        .expect("negative observation was discarded");
    assert_eq!(observation.observation_id, "negative-wait-observation");
    assert_eq!(
        observation.target,
        TargetKey {
            pid: 42,
            window_id: 7
        }
    );
    assert_eq!(
        wait.evidence.as_deref(),
        Some(&CheckEvidence {
            observation_id: "negative-wait-check".into(),
            condition,
            matched: false,
            collected: Some(CollectionInterval {
                started_unix_ms: 1,
                finished_unix_ms: 2
            }),
        })
    );
    assert!(matches!(
        call(&client, RequestBody::Capabilities(Empty {}))
            .await
            .body,
        ResponseBody::Capabilities(_)
    ));
    client.shutdown().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn explicit_user_wait_cancellation_remains_cancelled_and_reusable() {
    let client = peer("cooperative_wait_cancel").await;
    let cancellation = CancellationToken::new();
    let trigger = cancellation.clone();
    tokio::spawn(async move {
        sleep(Duration::from_millis(50)).await;
        trigger.cancel();
    });
    let response = client
        .call(
            RequestBody::WaitFor(WaitRequest {
                observation_id: "observation-1".into(),
                target: TargetKey {
                    pid: 42,
                    window_id: 7,
                },
                condition: Condition::ValueEquals(ValueCondition {
                    element_ref: "element-1".into(),
                    value: "ready".into(),
                }),
            }),
            Duration::from_secs(1),
            cancellation,
        )
        .await
        .unwrap();
    assert!(matches!(response.body, ResponseBody::WaitFor(wait)
        if wait.outcome == WaitOutcome::Cancelled && wait.evidence.is_some()));
    assert!(matches!(
        call(&client, RequestBody::Capabilities(Empty {}))
            .await
            .body,
        ResponseBody::Capabilities(_)
    ));
    client.shutdown().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn helper_loss_during_a_pure_wait_preserves_prefix_without_unknown_input() {
    let client = peer("eof_after_prefix").await;
    let mut body = act(3);
    let RequestBody::Act(request) = &mut body else {
        unreachable!()
    };
    request.steps[1].operation = Operation::WaitFor(WaitOperation {
        condition: Condition::ValueEquals(ValueCondition {
            element_ref: "element-1".into(),
            value: "ready".into(),
        }),
    });
    let result = act_result(call(&client, body).await);
    assert_eq!(result.stop_reason, StopReason::HelperDied);
    assert_eq!(result.steps.len(), 2);
    assert_eq!(result.steps[0].delivery, Delivery::Dispatched);
    assert_eq!(result.steps[1].delivery, Delivery::NotDispatched);
    assert_eq!(result.steps[1].reason, Some(ReceiptReason::HelperDied));
    assert_eq!(result.remaining_steps, 1);
    client.shutdown().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn corrupt_or_rewritten_progress_preserves_the_entire_uncertain_suffix() {
    for scenario in [
        "corrupt_after_prefix",
        "regressed_progress",
        "rewritten_progress",
    ] {
        let client = peer(scenario).await;
        let pid = client.helper_pid();
        let error = client
            .call(act(3), Duration::from_secs(1), CancellationToken::new())
            .await
            .unwrap_err();
        assert_eq!(error.kind, ClientErrorKind::ProtocolError, "{scenario}");
        let uncertainty = error
            .uncertainty
            .expect("mutation uncertainty must be retained");
        assert_eq!(uncertainty.observation_id, "observation-1");
        assert_eq!(uncertainty.settled_steps.len(), 1);
        assert_eq!(uncertainty.settled_steps[0].delivery, Delivery::Dispatched);
        assert_eq!(
            uncertainty.unacknowledged_action_ids,
            ["action-2", "action-3"]
        );
        client.shutdown().await;
        assert_reaped(pid).await;
    }
    for scenario in ["wrong_observation", "wrong_expectation"] {
        let client = peer(scenario).await;
        let mut body = act(1);
        if let RequestBody::Act(request) = &mut body {
            request.steps[0].expect = Some(Condition::ValueEquals(ValueCondition {
                element_ref: "element-1".into(),
                value: "expected".into(),
            }));
        }
        let error = client
            .call(body, Duration::from_secs(1), CancellationToken::new())
            .await
            .unwrap_err();
        assert_eq!(error.kind, ClientErrorKind::ProtocolError, "{scenario}");
        let uncertainty = error
            .uncertainty
            .expect("invalid provenance cannot establish delivery");
        assert!(uncertainty.settled_steps.is_empty());
        assert_eq!(uncertainty.unacknowledged_action_ids, ["action-1"]);
        client.shutdown().await;
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn deadline_after_mutation_preserves_prefix_and_never_restarts() {
    let client = peer("hang_after_prefix").await;
    let pid = client.helper_pid();
    let started = Instant::now();
    let result = act_result(
        client
            .call(act(3), Duration::from_millis(75), CancellationToken::new())
            .await
            .unwrap(),
    );
    assert!(started.elapsed() < Duration::from_secs(2));
    assert_eq!(result.stop_reason, StopReason::DeadlineExceeded);
    assert_eq!(result.steps[0].delivery, Delivery::Dispatched);
    assert_eq!(result.steps[1].delivery, Delivery::Unknown);
    assert_eq!(result.remaining_steps, 1);
    assert_eq!(client.helper_pid(), pid);
    let error = client
        .call(
            RequestBody::Capabilities(Empty {}),
            Duration::from_secs(1),
            CancellationToken::new(),
        )
        .await
        .unwrap_err();
    assert_eq!(error.kind, ClientErrorKind::Closed);
    client.shutdown().await;
    assert_reaped(pid).await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn host_deadline_classifies_cooperative_act_cancellation_without_rewriting_prefix() {
    let client = peer("cooperative_cancel").await;
    let condition = Condition::Enabled(EnabledCondition {
        element_ref: "element-1".into(),
        enabled: true,
    });
    let mut body = act(3);
    if let RequestBody::Act(request) = &mut body {
        request.steps[0].expect = Some(condition.clone());
    }
    let response = client
        .call(body, Duration::from_millis(50), CancellationToken::new())
        .await
        .unwrap();
    encode_line(&Frame::Response(response.clone())).expect("terminal receipt must remain valid");
    let result = act_result(response);
    assert_eq!(result.stop_reason, StopReason::DeadlineExceeded);
    assert_eq!(result.steps.len(), 2);
    assert_eq!(
        result.steps[0],
        StepReceipt {
            action_id: "action-1".into(),
            delivery: Delivery::Dispatched,
            verification: Verification::Confirmed,
            reason: None,
            evidence: vec![CheckEvidence {
                observation_id: "after".into(),
                condition,
                matched: true,
                collected: None,
            }],
            route: None,
        }
    );
    assert_eq!(result.steps[1].delivery, Delivery::NotDispatched);
    assert_eq!(result.steps[1].verification, Verification::Unverified);
    assert_eq!(
        result.steps[1].reason,
        Some(ReceiptReason::DeadlineExceeded)
    );
    assert_eq!(result.remaining_steps, 1);
    assert!(matches!(
        call(&client, RequestBody::Capabilities(Empty {}))
            .await
            .body,
        ResponseBody::Capabilities(_)
    ));
    client.shutdown().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn cooperative_cancellation_consumes_both_replies_and_preserves_connection() {
    let client = peer("cooperative_cancel").await;
    let cancellation = CancellationToken::new();
    let trigger = cancellation.clone();
    tokio::spawn(async move {
        sleep(Duration::from_millis(50)).await;
        trigger.cancel();
    });
    let result = act_result(
        client
            .call(act(3), Duration::from_secs(1), cancellation)
            .await
            .unwrap(),
    );
    assert_eq!(result.stop_reason, StopReason::Cancelled);
    assert_eq!(result.steps[0].delivery, Delivery::Dispatched);
    assert_eq!(result.steps[1].delivery, Delivery::NotDispatched);
    assert_eq!(result.remaining_steps, 1);
    assert!(matches!(
        call(&client, RequestBody::Capabilities(Empty {}))
            .await
            .body,
        ResponseBody::Capabilities(_)
    ));
    client.shutdown().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn uncooperative_cancellation_kills_and_reaps_with_unknown_delivery() {
    let client = peer("ignore_cancel").await;
    let pid = client.helper_pid();
    let cancellation = CancellationToken::new();
    let trigger = cancellation.clone();
    tokio::spawn(async move {
        sleep(Duration::from_millis(50)).await;
        trigger.cancel();
    });
    let result = act_result(
        client
            .call(act(3), Duration::from_secs(2), cancellation)
            .await
            .unwrap(),
    );
    assert_eq!(result.stop_reason, StopReason::Cancelled);
    assert_eq!(result.steps[0].delivery, Delivery::Dispatched);
    assert_eq!(result.steps[1].delivery, Delivery::Unknown);
    assert_eq!(result.remaining_steps, 1);
    client.shutdown().await;
    assert_reaped(pid).await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn queued_deadline_expires_without_waiting_for_another_call_or_dispatching() {
    let client = Arc::new(peer("block_then_success").await);
    let active_client = client.clone();
    let active = tokio::spawn(async move {
        active_client
            .call(
                RequestBody::Capabilities(Empty {}),
                Duration::from_secs(2),
                CancellationToken::new(),
            )
            .await
    });
    sleep(Duration::from_millis(30)).await;
    let started = Instant::now();
    let result = act_result(
        client
            .call(act(1), Duration::from_millis(30), CancellationToken::new())
            .await
            .unwrap(),
    );
    assert!(
        started.elapsed() < Duration::from_millis(300),
        "queued deadline waited for active operation"
    );
    assert_eq!(result.steps[0].delivery, Delivery::NotDispatched);
    assert_eq!(result.stop_reason, StopReason::DeadlineExceeded);
    assert!(active.await.unwrap().is_ok());
    let ResponseBody::Targets(targets) = call(
        &client,
        RequestBody::Targets(TargetsRequest { bundle_id: None }),
    )
    .await
    .body
    else {
        panic!()
    };
    assert_eq!(
        targets.targets[0].title, "call-2",
        "expired queued mutation reached helper"
    );
    client.shutdown().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn precancelled_and_invalid_requests_never_reach_native_dispatch() {
    let client = peer("good").await;
    let cancel = CancellationToken::new();
    cancel.cancel();
    let result = act_result(
        client
            .call(act(1), Duration::from_secs(1), cancel)
            .await
            .unwrap(),
    );
    assert_eq!(result.steps[0].delivery, Delivery::NotDispatched);
    assert_eq!(result.stop_reason, StopReason::Cancelled);
    let error = client
        .call(act(0), Duration::from_secs(1), CancellationToken::new())
        .await
        .unwrap_err();
    assert_eq!(error.kind, ClientErrorKind::InvalidRequest);
    assert!(error.uncertainty.is_none());
    let ResponseBody::Targets(targets) = call(
        &client,
        RequestBody::Targets(TargetsRequest { bundle_id: None }),
    )
    .await
    .body
    else {
        panic!()
    };
    assert_eq!(
        targets.targets[0].title, "call-1",
        "rejected requests reached fake helper"
    );
    client.shutdown().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn duplicate_and_late_responses_cannot_attach_to_a_future_request() {
    let client = peer("duplicate").await;
    let _ = client
        .call(
            RequestBody::Capabilities(Empty {}),
            Duration::from_secs(1),
            CancellationToken::new(),
        )
        .await;
    let error = client
        .call(
            RequestBody::Capabilities(Empty {}),
            Duration::from_secs(1),
            CancellationToken::new(),
        )
        .await
        .unwrap_err();
    assert!(matches!(
        error.kind,
        ClientErrorKind::ProtocolError | ClientErrorKind::Closed
    ));
    client.shutdown().await;

    let client = peer("late").await;
    let pid = client.helper_pid();
    let error = client
        .call(
            RequestBody::Capabilities(Empty {}),
            Duration::from_millis(30),
            CancellationToken::new(),
        )
        .await
        .unwrap_err();
    assert_eq!(error.kind, ClientErrorKind::DeadlineExceeded);
    let error = client
        .call(
            RequestBody::Capabilities(Empty {}),
            Duration::from_secs(1),
            CancellationToken::new(),
        )
        .await
        .unwrap_err();
    assert_eq!(error.kind, ClientErrorKind::Closed);
    client.shutdown().await;
    assert_reaped(pid).await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn disconnect_and_dropped_call_reap_the_native_process() {
    let client = peer("good").await;
    let pid = client.helper_pid();
    drop(client);
    assert_reaped(pid).await;

    let client = Arc::new(peer("ignore_cancel").await);
    let pid = client.helper_pid();
    let worker = client.clone();
    let call = tokio::spawn(async move {
        worker
            .call(act(3), Duration::from_secs(2), CancellationToken::new())
            .await
    });
    sleep(Duration::from_millis(50)).await;
    call.abort();
    let _ = call.await;
    assert_reaped(pid).await;
    client.shutdown().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn diagnostics_drain_stderr_and_omit_sensitive_values() {
    let client = peer("diagnostics").await;
    let mut body = act(1);
    if let RequestBody::Act(request) = &mut body {
        request.steps[0].operation = Operation::TypeText(TypeTextOperation {
            element_ref: "element-1".into(),
            text: "private-input-value-DO-NOT-RETAIN".into(),
        });
    }
    call(&client, body).await;
    for _ in 0..80 {
        call(&client, RequestBody::Capabilities(Empty {})).await;
    }
    let diagnostics = client.diagnostics();
    assert!(diagnostics.stderr_bytes > 0);
    assert!(!diagnostics.traces.is_empty());
    assert!(diagnostics.traces.len() <= 64);
    let encoded = serde_json::to_string(&diagnostics).unwrap();
    assert!(!encoded.contains("sensitive-field-content"));
    assert!(!encoded.contains("private-input-value"));
    assert!(!encoded.contains("configured-host-grant"));
    assert!(
        encoded.len() < 64 * 1024,
        "diagnostics retained an unbounded transcript"
    );
    client.shutdown().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn configuration_spawn_and_handshake_failures_are_bounded() {
    let mut invalid = config("good");
    invalid.handshake_budget = Duration::ZERO;
    let error = Client::spawn(invalid)
        .await
        .err()
        .expect("zero handshake budget was accepted");
    assert_eq!(error.kind, ClientErrorKind::InvalidConfig);

    let missing = Config::new(
        "/definitely-missing-cua-test-helper",
        Authority {
            grant_id: "host".into(),
            mode: ExecutionMode::BackgroundRequired,
        },
    );
    let error = Client::spawn(missing)
        .await
        .err()
        .expect("missing helper was accepted");
    assert_eq!(error.kind, ClientErrorKind::SpawnFailed);

    let mut hanging = config("handshake_hang");
    hanging.handshake_budget = Duration::from_millis(75);
    let started = Instant::now();
    let error = Client::spawn(hanging)
        .await
        .err()
        .expect("hung handshake succeeded");
    assert_eq!(error.kind, ClientErrorKind::HandshakeFailed);
    assert!(started.elapsed() < Duration::from_secs(2));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn dropped_spawn_future_reaps_a_child_waiting_for_handshake() {
    struct PidFile(PathBuf);
    impl Drop for PidFile {
        fn drop(&mut self) {
            let _ = std::fs::remove_file(&self.0);
        }
    }
    let nonce = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let pid_file = PidFile(
        std::env::temp_dir().join(format!("cua-handshake-{}-{nonce}.pid", std::process::id())),
    );
    let mut config = config("handshake_hang");
    config.args.push(pid_file.0.clone().into_os_string());
    let spawn = tokio::spawn(async move { Client::spawn(config).await });
    let until = Instant::now() + Duration::from_secs(2);
    let pid = loop {
        if let Ok(text) = std::fs::read_to_string(&pid_file.0)
            && let Ok(pid) = text.parse::<u32>()
        {
            break pid;
        }
        assert!(Instant::now() < until, "test helper never wrote its PID");
        sleep(Duration::from_millis(10)).await;
    };
    spawn.abort();
    let _ = spawn.await;
    assert_reaped(pid).await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn cancelled_startup_returns_only_after_reaping_the_handshaking_child() {
    let nonce = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let pid_file = std::env::temp_dir().join(format!(
        "cua-cancel-startup-{}-{nonce}.pid",
        std::process::id()
    ));
    let mut config = config("handshake_hang");
    config.args.push(pid_file.clone().into_os_string());
    let cancel = CancellationToken::new();
    let trigger = cancel.clone();
    let spawn = tokio::spawn(async move { Client::spawn_with_cancellation(config, cancel).await });
    let until = Instant::now() + Duration::from_secs(2);
    let pid = loop {
        if let Ok(text) = std::fs::read_to_string(&pid_file)
            && let Ok(pid) = text.parse::<u32>()
        {
            break pid;
        }
        assert!(Instant::now() < until, "test helper never wrote its PID");
        sleep(Duration::from_millis(10)).await;
    };
    trigger.cancel();
    let error = spawn
        .await
        .unwrap()
        .err()
        .expect("cancelled startup succeeded");
    assert_eq!(error.kind, ClientErrorKind::Cancelled);
    let alive = std::process::Command::new("kill")
        .args(["-0", &pid.to_string()])
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()
        .unwrap()
        .success();
    assert!(
        !alive,
        "startup returned before its native helper was reaped"
    );
    std::fs::remove_file(pid_file).unwrap();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn missing_cancel_ack_does_not_discard_a_completed_mutation_receipt() {
    let client = peer("final_without_cancel_ack").await;
    let pid = client.helper_pid();
    let cancellation = CancellationToken::new();
    let trigger = cancellation.clone();
    tokio::spawn(async move {
        sleep(Duration::from_millis(50)).await;
        trigger.cancel();
    });
    let result = act_result(
        client
            .call(act(3), Duration::from_secs(2), cancellation)
            .await
            .unwrap(),
    );
    assert_eq!(result.steps.len(), 3);
    assert!(
        result
            .steps
            .iter()
            .all(|step| step.delivery == Delivery::Dispatched)
    );
    assert_eq!(result.remaining_steps, 0);
    let error = client
        .call(
            RequestBody::Capabilities(Empty {}),
            Duration::from_secs(1),
            CancellationToken::new(),
        )
        .await
        .unwrap_err();
    assert_eq!(error.kind, ClientErrorKind::Closed);
    client.shutdown().await;
    assert_reaped(pid).await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn deadline_during_a_large_pipe_write_keeps_delivery_unknown() {
    let client = peer("not_reading").await;
    let pid = client.helper_pid();
    let mut body = act(1);
    if let RequestBody::Act(request) = &mut body {
        request.steps[0].operation = Operation::TypeText(TypeTextOperation {
            element_ref: "element-1".into(),
            // Fill the pipe while leaving time for debug-build JSON encoding.
            text: "x".repeat(256 * 1024),
        });
    }
    let started = Instant::now();
    let result = act_result(
        client
            .call(body, Duration::from_secs(1), CancellationToken::new())
            .await
            .unwrap(),
    );
    assert!(started.elapsed() < Duration::from_secs(3));
    assert_eq!(result.stop_reason, StopReason::DeadlineExceeded);
    assert_eq!(result.steps[0].delivery, Delivery::Unknown);
    assert_eq!(result.remaining_steps, 0);
    client.shutdown().await;
    assert_reaped(pid).await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn shutdown_allows_clean_eof_cleanup_and_is_idempotent() {
    struct Marker(PathBuf);
    impl Drop for Marker {
        fn drop(&mut self) {
            let _ = std::fs::remove_file(&self.0);
        }
    }
    let nonce = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let marker = Marker(std::env::temp_dir().join(format!(
        "cua-clean-eof-{}-{nonce}.marker",
        std::process::id()
    )));
    let mut config = config("clean_eof_cleanup");
    config.args.push(marker.0.clone().into_os_string());
    let client = Client::spawn(config).await.unwrap();
    let pid = client.helper_pid();
    assert!(!marker.0.exists(), "cleanup marker appeared before EOF");
    client.shutdown().await;
    assert_eq!(std::fs::read_to_string(&marker.0).unwrap(), "clean eof");
    let exit = client
        .diagnostics()
        .helper_exit
        .expect("helper exit status was not retained");
    assert!(exit.success);
    assert_eq!(exit.code, Some(0));
    assert_reaped(pid).await;
    client.shutdown().await;
    let exit = client
        .diagnostics()
        .helper_exit
        .expect("repeated shutdown lost exit status");
    assert!(exit.success);
    assert_eq!(exit.code, Some(0));
    assert_eq!(std::fs::read_to_string(&marker.0).unwrap(), "clean eof");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn unfinished_stdout_drain_does_not_claim_an_unacknowledged_suffix_was_unsent() {
    struct Marker(PathBuf);
    impl Drop for Marker {
        fn drop(&mut self) {
            let _ = std::fs::remove_file(&self.0);
        }
    }
    let nonce = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let marker = Marker(std::env::temp_dir().join(format!(
        "cua-held-stdout-{}-{nonce}.pid",
        std::process::id()
    )));
    let mut config = config("stdout_held_open");
    config.args.push(marker.0.clone().into_os_string());
    let client = Client::spawn(config).await.unwrap();
    let pid = client.helper_pid();
    let error = client
        .call(act(3), Duration::from_millis(75), CancellationToken::new())
        .await
        .unwrap_err();
    assert_eq!(error.kind, ClientErrorKind::DeadlineExceeded);
    let uncertainty = error
        .uncertainty
        .expect("incomplete drain needs suffix uncertainty");
    assert_eq!(uncertainty.settled_steps.len(), 1);
    assert_eq!(uncertainty.settled_steps[0].action_id, "action-1");
    assert_eq!(uncertainty.settled_steps[0].delivery, Delivery::Dispatched);
    assert_eq!(
        uncertainty.unacknowledged_action_ids,
        ["action-2", "action-3"]
    );
    let descendant_pid = std::fs::read_to_string(&marker.0)
        .unwrap()
        .parse::<u32>()
        .unwrap();
    client.shutdown().await;
    assert_reaped(pid).await;
    assert_reaped(descendant_pid).await;
}
