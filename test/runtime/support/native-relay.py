#!/usr/bin/env python3
"""Transparent test relay; optionally hold an act final after the real helper produced it."""
import json
import os
from pathlib import Path
import subprocess
import sys
import threading

program, mode, marker_prefix = sys.argv[1:]
child = subprocess.Popen([program], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)

def marker(suffix, value):
    path = Path(marker_prefix + suffix)
    temporary = path.with_suffix(path.suffix + '.tmp')
    temporary.write_text(json.dumps(value))
    temporary.replace(path)

marker('.ready.json', {'childPid': child.pid})

def forward_input():
    try:
        for line in sys.stdin.buffer:
            child.stdin.write(line)
            child.stdin.flush()
            frame = json.loads(line)
            if frame['message']['body']['method'] == 'act':
                marker('.request.json', {'request': frame})
    finally:
        child.stdin.close()


def forward_errors():
    for chunk in iter(lambda: child.stderr.read(4096), b''):
        sys.stderr.buffer.write(chunk)
        sys.stderr.buffer.flush()

threading.Thread(target=forward_input, daemon=True).start()
threading.Thread(target=forward_errors, daemon=True).start()
for line in child.stdout:
    frame = json.loads(line)
    if mode == 'hold-act-final' and frame['kind'] == 'response' and frame['message']['body']['result'] == 'act':
        marker('.response.json', {'childPid': child.pid, 'frame': frame})
        # Killing this relay closes the real helper stdin. No input or replay is added by this relay.
        child.wait()
        break
    sys.stdout.buffer.write(line)
    sys.stdout.buffer.flush()
sys.exit(child.wait())
