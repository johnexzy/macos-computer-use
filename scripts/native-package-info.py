#!/usr/bin/env python3
"""Validate native slices/signatures and write non-secret build provenance."""
import hashlib
import json
import re
import subprocess
import sys
from pathlib import Path


def run(*args):
    return subprocess.check_output(args, text=True, stderr=subprocess.STDOUT).strip()


stage, root = map(Path, sys.argv[1:])
files = {}
for name in ("useui", "useui-runtime"):
    binary = stage / "bin" / name
    architectures = run("xcrun", "lipo", "-archs", str(binary)).split()
    assert set(architectures) == {"arm64", "x86_64"}, architectures
    run("codesign", "--verify", "--strict", "--all-architectures", str(binary))
    signature = run("codesign", "-d", "--verbose=4", str(binary))
    identifier = re.search(r"^Identifier=(.+)$", signature, re.M).group(1)
    assert identifier == f"com.johnoba.useui.{name}", identifier
    assert "adhoc" in signature, "Review package must be explicitly ad-hoc signed"
    slices = {}
    for architecture in architectures:
        load = run("xcrun", "vtool", "-arch", architecture, "-show-build", str(binary))
        minimum = re.search(r"\bminos\s+(\S+)", load).group(1)
        assert minimum in {"13.0", "13.0.0"}, minimum
        libraries = []
        for line in run("otool", "-arch", architecture, "-L", str(binary)).splitlines()[1:]:
            if not line.startswith("\t"):
                continue
            library = line.strip().split(" (", 1)[0]
            assert library.startswith(("/System/Library/", "/usr/lib/")), library
            libraries.append(library)
        slices[architecture] = {"minimumMacOS": minimum, "linkedLibraries": libraries}
    files[f"bin/{name}"] = {"sha256": hashlib.sha256(binary.read_bytes()).hexdigest(),
                            "architectures": architectures, "identifier": identifier,
                            "signing": "ad-hoc", "notarized": False, "slices": slices}

print(json.dumps({"schemaVersion": 1, "sourceRevision": run("git", "-C", str(root), "rev-parse", "HEAD"),
    "sourceDirty": bool(run("git", "-C", str(root), "status", "--porcelain")),
    "deploymentTarget": "13.0", "wireVersion": 1,
    "toolchain": {"rust": run("rustc", "--version"), "swift": run("swift", "--version"),
                  "xcode": run("xcodebuild", "-version"), "sdk": run("xcrun", "--sdk", "macosx", "--show-sdk-version")},
    "files": files,
    "limits": "Deployment metadata is not a runtime test on every older macOS version. Ad-hoc signing is not Developer ID or Gatekeeper approval."}, indent=2))
