use cua_protocol::*;
use std::{fs, path::PathBuf};

fn fixtures(bucket: &str) -> Vec<PathBuf> {
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../protocol/fixtures")
        .join(bucket);
    let mut paths: Vec<_> = fs::read_dir(root)
        .unwrap()
        .map(|v| v.unwrap().path())
        .collect();
    paths.sort();
    paths
}
fn fixture(name: &str) -> Frame {
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../protocol/fixtures/valid")
        .join(format!("{name}.json"));
    decode_line(&fs::read(path).unwrap()).unwrap()
}

#[test]
fn shared_valid_fixtures_decode_and_round_trip() {
    let paths = fixtures("valid");
    assert_eq!(
        paths.len(),
        37,
        "keep the shared fixture inventory deliberate"
    );
    for path in paths {
        let frame = decode_line(&fs::read(&path).unwrap())
            .unwrap_or_else(|e| panic!("{}: {e}", path.display()));
        let encoded = encode_line(&frame).unwrap();
        assert_eq!(encoded.last(), Some(&b'\n'));
        assert_eq!(decode_line(&encoded).unwrap(), frame, "{}", path.display());
    }
}

#[test]
fn shared_invalid_fixtures_are_rejected() {
    let paths = fixtures("invalid");
    assert_eq!(paths.len(), 47);
    for path in paths {
        assert!(
            decode_line(&fs::read(&path).unwrap()).is_err(),
            "accepted {}",
            path.display()
        );
    }
}

#[test]
fn frames_are_bounded_single_line_messages() {
    assert!(decode_line(&vec![b' '; MAX_FRAME_BYTES + 1]).is_err());
    assert!(decode_line(b"{}\n{}\n").is_err());
    assert!(decode_line(b"{}\r\n").is_err());
    assert!(decode_line(b"diagnostic output\n").is_err());
}

#[test]
fn cropped_resized_image_maps_to_negative_origin_display_without_guessing() {
    let Frame::Response(Response {
        body: ResponseBody::Observe(observation),
        ..
    }) = fixture("observe-partial-response")
    else {
        panic!()
    };
    let transform = observation.screenshot.unwrap().image_to_screen;
    assert_eq!(
        transform.to_screen(&Point { x: 20.0, y: 12.0 }).unwrap(),
        Point {
            x: -790.0,
            y: 103.0
        }
    );
    assert!(transform.to_screen(&Point { x: 0.0, y: 12.0 }).is_err());
    assert!(transform.to_screen(&Point { x: 70.0, y: 12.0 }).is_err());
    let overflowing = ImageTransform {
        scale_x: 1e308,
        ..transform
    };
    assert!(overflowing.to_screen(&Point { x: 20.0, y: 12.0 }).is_err());
}

#[test]
fn authority_and_epoch_are_installed_by_host_not_act_arguments() {
    let Frame::Request(mut request) = fixture("act-request") else {
        panic!()
    };
    let session = SessionContext {
        epoch: "helper-epoch-1".into(),
        authority: Authority {
            grant_id: "host-grant-1".into(),
            mode: ExecutionMode::BackgroundRequired,
        },
    };
    session.authorize(&request).unwrap();
    request.epoch = Some("previous-helper-epoch".into());
    assert!(session.authorize(&request).is_err());
    request.epoch = Some(session.epoch.clone());
    if let RequestBody::Act(act) = &mut request.body {
        act.grant_id = "self-granted".into();
    }
    assert!(session.authorize(&request).is_err());
    let Frame::Request(hello) = fixture("hello-request") else {
        panic!()
    };
    assert!(session.authorize(&hello).is_err());
}

#[test]
fn partial_mutation_timeout_and_already_satisfied_are_distinct() {
    let result = |name| match fixture(name) {
        Frame::Response(Response {
            body: ResponseBody::Act(result),
            ..
        }) => result,
        _ => panic!(),
    };
    let partial = result("act-partial-mutation");
    assert_eq!(partial.steps[0].delivery, Delivery::Dispatched);
    assert_eq!(partial.steps[1].delivery, Delivery::NotDispatched);
    assert_eq!(partial.remaining_steps, 1);
    for name in [
        "act-timeout-dispatch-unknown",
        "act-helper-death-dispatch-unknown",
    ] {
        let uncertain = result(name);
        assert_eq!(uncertain.steps[0].delivery, Delivery::Unknown);
        assert_eq!(uncertain.steps[0].verification, Verification::Unverified);
    }
    let existing = result("act-already-satisfied");
    assert_eq!(existing.steps[0].delivery, Delivery::NotDispatched);
    assert_eq!(existing.steps[0].verification, Verification::Confirmed);
    assert_eq!(
        existing.steps[0].reason,
        Some(ReceiptReason::AlreadySatisfied)
    );
}

#[test]
fn replies_cannot_attach_to_another_request_epoch_or_action_prefix() {
    let Frame::Request(request) = fixture("act-request") else {
        panic!()
    };
    let Frame::Response(response) = fixture("act-verified-response") else {
        panic!()
    };
    response.validate_for(&request, "helper-epoch-1").unwrap();
    let mut wrong = response.clone();
    wrong.id = "another-request".into();
    assert!(wrong.validate_for(&request, "helper-epoch-1").is_err());
    assert!(response.validate_for(&request, "restarted-helper").is_err());
    let mut stale_request = request.clone();
    stale_request.epoch = Some("old-epoch".into());
    assert!(
        response
            .validate_for(&stale_request, "helper-epoch-1")
            .is_err()
    );
    let mut wrong = response.clone();
    if let ResponseBody::Act(result) = &mut wrong.body {
        result.steps[0].action_id = "another-action".into();
    }
    assert!(wrong.validate_for(&request, "helper-epoch-1").is_err());
    let Frame::Response(too_long) = fixture("act-partial-mutation") else {
        panic!()
    };
    assert!(too_long.validate_for(&request, "helper-epoch-1").is_err());
    let Frame::Response(wrong_method) = fixture("targets-response") else {
        panic!()
    };
    assert!(
        wrong_method
            .validate_for(&request, "helper-epoch-1")
            .is_err()
    );
}

#[test]
fn observation_privacy_flags_are_checked_at_response_boundary() {
    let Frame::Request(mut request) = fixture("observe-request") else {
        panic!()
    };
    let Frame::Response(mut response) = fixture("observe-partial-response") else {
        panic!()
    };
    response.validate_for(&request, "helper-epoch-1").unwrap();
    if let ResponseBody::Observe(observation) = &mut response.body {
        observation.elements[0].value = Some("private".into());
    }
    assert!(response.validate_for(&request, "helper-epoch-1").is_err());
    if let RequestBody::Observe(observe) = &mut request.body {
        observe.include_values = true;
    }
    response.validate_for(&request, "helper-epoch-1").unwrap();
    if let RequestBody::Observe(observe) = &mut request.body {
        observe.include_screenshot = false;
    }
    assert!(response.validate_for(&request, "helper-epoch-1").is_err());
}

#[test]
fn progress_preserves_settled_prefix_and_unknown_delivery_remains_independent() {
    let Frame::Request(request) = fixture("act-sequence-request") else {
        panic!()
    };
    let Frame::Progress(progress) = fixture("act-progress-prefix") else {
        panic!()
    };
    progress.validate_for(&request, "helper-epoch-1").unwrap();
    assert!(progress.validate_for(&request, "new-helper").is_err());
    let mut wrong = progress.clone();
    wrong.steps[0].action_id = "action-2".into();
    assert!(wrong.validate_for(&request, "helper-epoch-1").is_err());
    let Frame::Response(partial) = fixture("act-partial-mutation") else {
        panic!()
    };
    partial.validate_for(&request, "helper-epoch-1").unwrap();
    let Frame::Response(Response {
        body: ResponseBody::Act(uncertain),
        ..
    }) = fixture("act-unknown-state-confirmed")
    else {
        panic!()
    };
    assert_eq!(uncertain.steps[0].delivery, Delivery::Unknown);
    assert_eq!(uncertain.steps[0].verification, Verification::Confirmed);
    assert_ne!(uncertain.stop_reason, StopReason::Completed);
}

#[test]
fn shared_expectation_correlation_cases_bind_receipts_to_requested_conditions() {
    #[derive(serde::Deserialize)]
    struct Case {
        name: String,
        valid: bool,
        request: Frame,
        reply: Frame,
    }
    let path =
        PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../protocol/fixtures/correlation.json");
    let cases: Vec<Case> = serde_json::from_slice(&fs::read(path).unwrap()).unwrap();
    assert_eq!(cases.len(), 19);
    for case in cases {
        case.request.validate().unwrap();
        case.reply.validate().unwrap();
        let Frame::Request(request) = &case.request else {
            panic!()
        };
        let checked = match &case.reply {
            Frame::Response(response) => response.validate_for(request, "helper-epoch-1"),
            Frame::Progress(progress) => progress.validate_for(request, "helper-epoch-1"),
            _ => panic!(),
        };
        assert_eq!(checked.is_ok(), case.valid, "{}: {checked:?}", case.name);
    }
}

#[test]
fn observations_expose_independent_channel_times_and_capabilities_include_click() {
    let Frame::Response(Response {
        body: ResponseBody::Observe(observation),
        ..
    }) = fixture("observe-partial-response")
    else {
        panic!()
    };
    let ax = observation.accessibility_collected.unwrap();
    let image = observation.screenshot.unwrap();
    assert!(ax.finished_unix_ms < image.collected.started_unix_ms);
    assert!(observation.collected.started_unix_ms <= ax.started_unix_ms);
    assert!(image.collected.finished_unix_ms <= observation.collected.finished_unix_ms);
    let Frame::Response(Response {
        body: ResponseBody::Observe(unavailable),
        ..
    }) = fixture("observe-unavailable-channel")
    else {
        panic!()
    };
    assert!(unavailable.accessibility_collected.is_none());
    let Frame::Response(Response {
        body: ResponseBody::Capabilities(capabilities),
        ..
    }) = fixture("capabilities-response")
    else {
        panic!()
    };
    assert!(capabilities.actions.contains(&ActionKind::Click));
    assert!(serde_json::from_str::<ElementAction>("\"click\"").is_err());
}
