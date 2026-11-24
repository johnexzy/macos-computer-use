#!/usr/bin/env python3
"""Installed-archive smoke. No Node/compiler, UI input, capture or permission requests."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import select
import shutil
import signal
import subprocess
import tarfile
import tempfile
import threading
import time


def alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False


def wait_dead(pid):
    deadline = time.monotonic() + 3
    while alive(pid) and time.monotonic() < deadline:
        time.sleep(0.02)
    assert not alive(pid), "Bundled helper was not reaped"


def read_json(process):
    assert select.select([process.stdout], [], [], 8)[0], "Packaged response exceeded deadline"
    line = process.stdout.readline()
    assert line, "Packaged process exited before response"
    return json.loads(line)


def send(process, value):
    process.stdin.write(json.dumps(value).encode() + b"\n")
    process.stdin.flush()


def stop(process):
    if process.poll() is None:
        process.kill()
    process.wait(timeout=5)


def smoke_host(command, directory, environment, ending):
    process = subprocess.Popen(command, cwd=directory, env=environment,
                               stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    helper = []
    ready = threading.Event()
    def diagnostics():
        for line in process.stderr:
            try:
                value = json.loads(line)
                if value.get("event") == "runtime_started":
                    helper.append(value["helperPid"])
                    ready.set()
            except (ValueError, KeyError):
                pass  # Framework diagnostics never become protocol stdout or a permissions claim.
    thread = threading.Thread(target=diagnostics, daemon=True)
    thread.start()
    try:
        assert ready.wait(8), "Bundled helper handshake failed"
        assert len(helper) == 1 and alive(helper[0])
        def call(ident, method, params):
            send(process, {"jsonrpc": "2.0", "id": ident, "method": method, "params": params})
            reply = read_json(process)
            assert reply.get("id") == ident and "error" not in reply, reply
            return reply["result"]
        result = call(1, "initialize", {"protocolVersion": "2025-11-25", "capabilities": {},
            "clientInfo": {"name": "clean-package-client", "version": "1"}})
        assert result["protocolVersion"] == "2025-11-25"
        send(process, {"jsonrpc": "2.0", "method": "notifications/initialized"})
        tools = call(2, "tools/list", {})["tools"]
        assert {tool["name"] for tool in tools} == {
            "capabilities", "browser", "targets", "open", "clipboard", "observe", "act", "waitFor"
        }
        epochs = set()
        ids = set()
        for ident in range(3, 6):
            result = call(ident, "tools/call", {"name": "capabilities", "arguments": {}})
            assert not result.get("isError", False)
            response = result["structuredContent"]
            caps = response["body"]["data"]
            assert response["body"]["result"] == "capabilities"
            assert caps["mode"] == "backgroundRequired"
            assert all(isinstance(value, bool) for value in caps["permissions"].values())
            epochs.add(response["epoch"])
            ids.add(response["id"])
        assert len(epochs) == 1 and len(ids) == 3 and len(helper) == 1
        if ending is None:
            process.stdin.close()
        else:
            process.send_signal(ending)
        assert process.wait(timeout=5) == 0
        thread.join(timeout=2)
        wait_dead(helper[0])
        return {"termination": "EOF" if ending is None else signal.Signals(ending).name,
                "persistentHelper": True, "helperReaped": True,
                "permissions": caps["permissions"], "mcpPreflightCalls": 3}
    finally:
        stop(process)
        if helper and alive(helper[0]):
            try:
                wait_dead(helper[0])
            except AssertionError:
                os.kill(helper[0], signal.SIGKILL)
                raise


def smoke_runtime(command, directory, environment):
    process = subprocess.Popen(command, cwd=directory, env=environment,
                               stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    try:
        def call(ident, method, params, epoch=None):
            send(process, {"kind": "request", "message": {"version": 1, "id": ident,
                "epoch": epoch, "budgetMs": 1000, "body": {"method": method, "params": params}}})
            reply = read_json(process)
            assert reply["kind"] == "response" and reply["message"]["id"] == ident
            return reply["message"]
        hello = call("hello", "hello", {"clientName": "package-smoke", "supportedVersions": [1],
            "authority": {"grantId": "package-smoke", "mode": "backgroundRequired"}})
        caps = call("caps", "capabilities", {}, hello["epoch"])
        assert caps["body"]["data"]["mode"] == "backgroundRequired"
        process.stdin.close()
        assert process.wait(timeout=5) == 0
    finally:
        stop(process)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive", type=Path)
    parser.add_argument("--architecture", choices=["native", "arm64", "x86_64"], default="native")
    args = parser.parse_args()
    subprocess.run(["/usr/bin/shasum", "-a", "256", "-c", args.archive.name + ".sha256"],
                   cwd=args.archive.resolve().parent, check=True, capture_output=True)
    with tempfile.TemporaryDirectory(prefix="UseUI package smoke ") as temporary:
        temporary = Path(temporary)
        installation = temporary / "Clean Install With Spaces"
        installation.mkdir()
        with tarfile.open(args.archive) as archive:
            for member in archive.getmembers():
                relative = Path(member.name)
                assert not relative.is_absolute() and ".." not in relative.parts
                target = installation / relative
                if member.isdir():
                    target.mkdir(parents=True, exist_ok=True)
                else:
                    assert member.isfile(), "Review archive must contain only directories and regular files"
                    target.parent.mkdir(parents=True, exist_ok=True)
                    with archive.extractfile(member) as source, target.open("wb") as destination:
                        shutil.copyfileobj(source, destination)
                    target.chmod(0o755 if target.parent.name == "bin" else 0o644)
        roots = list(installation.iterdir())
        assert len(roots) == 1
        installed = roots[0]
        manifest = json.loads((installed / "manifest.json").read_text())
        subprocess.run(["/usr/bin/shasum", "-a", "256", "-c", "SHA256SUMS"], cwd=installed, check=True, capture_output=True)
        for name in ("useui", "useui-runtime"):
            binary = installed / "bin" / name
            assert hashlib.sha256(binary.read_bytes()).hexdigest() == manifest["files"][f"bin/{name}"]["sha256"]
            subprocess.run(["/usr/bin/codesign", "--verify", "--strict", "--all-architectures", str(binary)], check=True, capture_output=True)
        work = temporary / "External MCP Client Working Directory"
        work.mkdir()
        home = temporary / "Empty Home"
        home.mkdir()
        environment = {"PATH": "/usr/bin:/bin", "HOME": str(home), "LANG": "en_US.UTF-8"}
        prefix = [] if args.architecture == "native" else ["/usr/bin/arch", f"-{args.architecture}"]
        host = str(installed / "bin/useui")
        runtime = str(installed / "bin/useui-runtime")
        version = subprocess.check_output(prefix + [host, "--version"], cwd=work, env=environment, text=True).strip()
        smoke_runtime(prefix + [runtime], work, environment)
        checks = [smoke_host(prefix + [host], work, environment, ending)
                  for ending in (None, signal.SIGINT, signal.SIGTERM)]
        link = work / "MCP Client Launch Link"
        link.symlink_to(host)
        checks.append({"symlinkLaunch": True, **smoke_host(prefix + [str(link)], work, environment, None)})
        missing = subprocess.Popen(prefix + [host, "--helper", str(work / "missing helper")], env=environment,
                                   cwd=work, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            assert missing.wait(timeout=5) != 0 and missing.stdout.read() == b""
        finally:
            stop(missing)
        print(json.dumps({"version": version, "architecture": args.architecture,
            "sourceRevision": manifest["sourceRevision"], "runtimeDirectPreflight": True, "checks": checks,
            "missingHelperRejected": True, "minimalPath": True, "pathsWithSpaces": True,
            "mutations": 0, "captures": 0, "permissionRequests": 0}))


if __name__ == "__main__":
    main()
