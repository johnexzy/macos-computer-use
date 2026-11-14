#!/usr/bin/env python3
"""Read-only process smoke: native preflight, lifecycle protocol, framing, EOF/signals.

Run after `swift build`: python3 runtime/Tests/process-smoke.py [runtime-binary]
No global input, AX mutations, screenshots, or permission requests are performed.
"""
import json
import os
from pathlib import Path
import select
import signal
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[2]
BINARY = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else ROOT / ".build/debug/cua-runtime"


def launch():
    return subprocess.Popen([str(BINARY)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)


def request(ident, method, params, epoch=None):
    return {"kind": "request", "message": {"version": 1, "id": ident, "epoch": epoch,
            "budgetMs": 1000, "body": {"method": method, "params": params}}}


def send(process, frame):
    process.stdin.write(json.dumps(frame).encode() + b"\n")
    process.stdin.flush()


def call(process, frame):
    send(process, frame)
    assert select.select([process.stdout], [], [], 5)[0], "runtime response timeout"
    line = process.stdout.readline()
    assert line, "runtime exited before response"
    value = json.loads(line)
    assert value["kind"] == "response"
    assert value["message"]["id"] == frame["message"]["id"]
    return value["message"]


def hello(process):
    return call(process, request("hello", "hello", {"clientName": "process-smoke", "supportedVersions": [1],
        "authority": {"grantId": "smoke-grant", "mode": "backgroundRequired"}}))["epoch"]


checks = []
process = launch()
try:
    epoch = hello(process)
    caps = call(process, request("cap", "capabilities", {}, epoch))
    assert caps["epoch"] == epoch
    assert caps["body"]["data"]["mode"] == "backgroundRequired"
    permissions = caps["body"]["data"]["permissions"]
    assert all(isinstance(value, bool) for value in permissions.values())
    assert set(caps["body"]["data"]["actions"]) == ({"setValue", "typeText", "press"} if permissions["accessibility"] else set())
    targets = call(process, request("targets", "targets", {"bundleId": None}, epoch))["body"]["data"]
    assert len(targets["targets"]) <= 256
    filtered = call(process, request("filtered", "targets", {"bundleId": "nonexistent.cua.fixture"}, epoch))
    assert filtered["body"]["data"]["targets"] == []
    # Do not inspect arbitrary user windows in this read-only lifecycle smoke.
    target = {"pid": 2147483647, "windowId": 4294967295}
    rejected = call(process, request("observe", "observe", {"target": target,
        "includeValues": False, "includeScreenshot": False}, epoch))
    assert rejected["body"]["result"] == "error"
    assert rejected["body"]["data"]["code"] == "targetNotFound"
    screenshot = call(process, request("screenshot", "observe", {"target": target,
        "includeValues": False, "includeScreenshot": True}, epoch))
    assert screenshot["body"]["data"]["code"] == "unsupported"
    actions = [{"actionId": name, "operation": {"kind": "press", "params": {"elementRef": "not-a-live-element"}},
                "precondition": None, "expect": None} for name in ("first", "second")]
    rejected_act = call(process, request("act", "act", {"grantId": "smoke-grant", "observationId": "not-a-live-observation",
        "target": target, "steps": actions}, epoch))["body"]
    assert rejected_act["result"] == "error"
    assert rejected_act["data"]["code"] == "staleObservation"
    stale = call(process, request("stale", "capabilities", {}, "old-epoch"))
    assert stale["body"]["data"]["code"] == "staleEpoch"
    process.stdin.close()
    process.wait(timeout=5)
    assert process.returncode == 0 and process.stderr.read() == b""
    checks.append("persistent native preflight/targets/invalid-target/stale-observation refusal/EOF")
finally:
    if process.poll() is None:
        process.kill()
        process.wait()

process = launch()
try:
    assert hello(process) != epoch
    os.kill(process.pid, signal.SIGTERM)
    process.wait(timeout=5)
    assert process.returncode == 0
    checks.append("new epoch on restart; SIGTERM with stdin open")
finally:
    if process.poll() is None:
        process.kill()
        process.wait()

# Signal while the hello frame is buffered/being initialized; stdin remains open.
process = launch()
try:
    send(process, request("hello", "hello", {"clientName": "startup-signal", "supportedVersions": [1],
        "authority": {"grantId": "smoke-grant", "mode": "backgroundRequired"}}))
    time.sleep(0.05)
    os.kill(process.pid, signal.SIGTERM)
    process.wait(timeout=5)
    assert process.returncode == 0
    checks.append("SIGTERM during startup/hello with stdin open")
finally:
    if process.poll() is None:
        process.kill()
        process.wait()

for data in (b'{"kind":"request"', b'not-json-secret-value\n', b'{}\r\n', b'A' * (8 * 1024 * 1024)):
    completed = subprocess.run([str(BINARY)], input=data, capture_output=True, timeout=5)
    assert completed.returncode == 64
    assert completed.stdout == b""
    assert completed.stderr == b"cua-runtime: invalid_input\n"
checks.append("truncated/malformed/CRLF/oversized frames; bounded fixed diagnostics")
print(json.dumps({"checks": checks, "permissions": permissions, "targets": len(targets["targets"]),
                  "mutations": 0, "permissionRequests": 0}))
