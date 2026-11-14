#!/usr/bin/env python3
"""Fault-injection peer for cua-client tests. Never touches desktop APIs."""
import json
import os
import subprocess
import sys
import threading
import time

scenario = sys.argv[1]
if len(sys.argv) > 2 and scenario not in {"clean_eof_cleanup", "stdout_held_open"}:
    with open(sys.argv[2], "w", encoding="utf-8") as pid_file:
        pid_file.write(str(os.getpid()))
epoch = "helper-epoch-test"
authority = None
pending = None
calls = 0
write_lock = threading.Lock()


def emit(frame):
    with write_lock:
        sys.stdout.write(json.dumps(frame, separators=(",", ":")) + "\n")
        sys.stdout.flush()


def response(request, result, data):
    return {
        "kind": "response",
        "message": {
            "version": 1,
            "id": request["id"],
            "epoch": epoch,
            "body": {"result": result, "data": data},
        },
    }


def receipt(step):
    expected = step.get("expect")
    return {
        "actionId": step["actionId"],
        "delivery": "dispatched",
        "verification": "confirmed" if expected else "unverified",
        "reason": None,
        "evidence": (
            [{"observationId": "after", "condition": expected, "matched": True}]
            if expected
            else []
        ),
    }


def progress(request, steps):
    return {
        "kind": "progress",
        "message": {
            "version": 1,
            "id": request["id"],
            "epoch": epoch,
            "observationId": request["body"]["params"]["observationId"],
            "steps": steps,
        },
    }


def completed(request):
    params = request["body"]["params"]
    return response(
        request,
        "act",
        {
            "observationId": params["observationId"],
            "steps": [receipt(step) for step in params["steps"]],
            "remainingSteps": 0,
            "stopReason": "completed",
        },
    )


def capabilities(request):
    return response(
        request,
        "capabilities",
        {
            "permissions": {
                "accessibility": False,
                "screenRecording": False,
                "inputPosting": False,
            },
            "mode": authority["mode"],
            "actions": ["press", "setValue", "typeText", "key", "scroll", "click"],
        },
    )


def delayed_reply(request):
    time.sleep(2)
    emit(capabilities(request))


for line in sys.stdin:
    request = json.loads(line)["message"]
    method = request["body"]["method"]
    params = request["body"]["params"]
    if method == "hello":
        authority = params["authority"]
        if scenario == "handshake_hang":
            time.sleep(10)
            continue
        emit(response(request, "hello", {"helperVersion": "test-peer", "selectedVersion": 1}))
        if scenario == "not_reading":
            time.sleep(10)
            continue
        if scenario == "diagnostics":
            sys.stderr.write("sensitive-field-content-DO-NOT-RETAIN\n" * 10000)
            sys.stderr.flush()
        continue
    if method == "cancel":
        if scenario in {"ignore_cancel", "hang_after_prefix", "late", "stdout_held_open"}:
            continue
        if scenario == "final_without_cancel_ack" and pending is not None:
            original, _ = pending
            emit(completed(original))
            pending = None
            continue
        emit(response(request, "cancel", {"requestId": params["requestId"], "status": "requested"}))
        if pending is not None:
            original, prefix = pending
            steps = original["body"]["params"]["steps"]
            next_step = steps[len(prefix)]
            stopped = {
                "actionId": next_step["actionId"],
                "delivery": "not_dispatched",
                "verification": "unverified",
                "reason": "cancelled",
                "evidence": [],
            }
            emit(response(original, "act", {
                "observationId": original["body"]["params"]["observationId"],
                "steps": prefix + [stopped],
                "remainingSteps": len(steps) - len(prefix) - 1,
                "stopReason": "cancelled",
            }))
            pending = None
        continue
    calls += 1
    if scenario == "oversize":
        sys.stdout.write("x" * (8 * 1024 * 1024 + 1))
        sys.stdout.flush()
        time.sleep(10)
        continue
    if scenario == "truncated":
        sys.stdout.write('{"kind":"response","message":')
        sys.stdout.flush()
        os._exit(0)
    if scenario == "eof":
        os._exit(0)
    if scenario == "late":
        threading.Thread(target=delayed_reply, args=(request,), daemon=True).start()
        continue
    if method == "act":
        if params["grantId"] != authority["grantId"]:
            emit(response(request, "error", {"code": "authorityDenied", "message": "wrong grant"}))
            continue
        prefix = [receipt(params["steps"][0])]
        if scenario in {
            "eof_after_prefix", "hang_after_prefix", "ignore_cancel", "cooperative_cancel",
            "corrupt_after_prefix", "regressed_progress", "rewritten_progress", "eof_after_all_progress",
            "final_without_cancel_ack",
            "stdout_held_open",
        }:
            if scenario == "stdout_held_open":
                descendant = subprocess.Popen(
                    [sys.executable, "-c", "import time; time.sleep(0.8)"],
                    stdin=subprocess.DEVNULL, stdout=sys.stdout, stderr=subprocess.DEVNULL,
                )
                with open(sys.argv[2], "w", encoding="utf-8") as descendant_file:
                    descendant_file.write(str(descendant.pid))
            emit(progress(request, prefix))
            if scenario == "eof_after_prefix":
                os._exit(0)
            if scenario == "eof_after_all_progress":
                for count in range(2, len(params["steps"]) + 1):
                    emit(progress(request, [receipt(step) for step in params["steps"][:count]]))
                os._exit(0)
            if scenario == "corrupt_after_prefix":
                bad = completed(request)
                bad["message"]["id"] = "wrong-request"
                emit(bad)
                continue
            if scenario == "regressed_progress":
                emit(progress(request, prefix))
                continue
            if scenario == "rewritten_progress":
                rewritten = receipt(params["steps"][0])
                rewritten["verification"] = "confirmed"
                rewritten["evidence"] = [{
                    "observationId": "after",
                    "condition": {"kind": "enabled", "params": {"elementRef": "element-1", "enabled": True}},
                    "matched": True,
                }]
                emit(progress(request, [rewritten, receipt(params["steps"][1])]))
                continue
            pending = request, prefix
            continue
        reply = completed(request)
        if scenario == "wrong_observation":
            reply["message"]["body"]["data"]["observationId"] = "unrelated-observation"
        if scenario == "wrong_expectation":
            reply["message"]["body"]["data"]["steps"][0]["evidence"][0]["condition"]["params"]["value"] = "wrong"
        emit(reply)
        continue
    if method == "capabilities":
        if scenario == "block_then_success" and calls == 1:
            time.sleep(0.75)
        reply = capabilities(request)
        if scenario == "wrong_id":
            reply["message"]["id"] = "wrong-request"
        if scenario == "wrong_epoch":
            reply["message"]["epoch"] = "old-helper-epoch"
        if scenario == "wrong_method":
            reply = response(request, "targets", {"targets": [], "truncated": False})
        emit(reply)
        if scenario == "duplicate":
            emit(reply)
        continue
    if method == "targets":
        emit(response(request, "targets", {
            "targets": [{
                "key": {"pid": os.getpid(), "windowId": 7},
                "bundleId": "test.helper",
                "title": "call-" + str(calls),
                "bounds": {"x": 0, "y": 0, "width": 100, "height": 100},
            }],
            "truncated": False,
        }))

if scenario == "clean_eof_cleanup":
    with open(sys.argv[2], "w", encoding="utf-8") as cleanup_file:
        cleanup_file.write("clean eof")
