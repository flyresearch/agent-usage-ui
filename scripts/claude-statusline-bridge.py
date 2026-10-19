#!/usr/bin/env python3
"""Opt-in local statusLine bridge. No credentials, transcript reads or network.

Install explicitly with --install --settings FILE --directory PRIVATE_DIRECTORY.
The original command, stdin, stdout, stderr, cwd and environment are preserved.
Only validated quota fields and opaque replay fingerprints are persisted.
"""
import argparse
import fcntl
import hashlib
import json
import math
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile
import time

LIMIT = 2 * 1024 * 1024


def atomic(path, data):
    fd, name = tempfile.mkstemp(prefix='.bridge-', dir=path.parent)
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, 'wb') as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def encode(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), allow_nan=False).encode()


def number(value):
    return type(value) in (int, float) and math.isfinite(value)


def capture(raw, directory, now=None):
    now = time.time() if now is None else now
    payload = json.loads(raw)
    session = payload.get('session_id')
    duration = payload.get('cost', {}).get('total_api_duration_ms')
    if not isinstance(session, str) or not session or len(session) > 256:
        raise ValueError('invalid_input')
    if not number(duration) or duration < 0:
        raise ValueError('invalid_input')
    limits = payload.get('rate_limits') or {}
    if not isinstance(limits, dict):
        raise ValueError('invalid_input')
    windows = []
    for key in ('five_hour', 'seven_day'):
        value = limits.get(key)
        if value is None:
            continue
        if not isinstance(value, dict):
            raise ValueError('invalid_input')
        used, reset = value.get('used_percentage'), value.get('resets_at')
        if not number(used) or not 0 <= used <= 100 or not number(reset) or reset <= 0:
            raise ValueError('invalid_input')
        windows.append({'window': key, 'used_percentage': used, 'resets_at': reset})
    # Timers and unchanged callbacks must not make an old provider sample fresh.
    identity = hashlib.sha256(session.encode()).hexdigest()
    fingerprint = hashlib.sha256(encode([duration, windows])).hexdigest()
    with (directory / 'capture.lock').open('a+b') as lock:
        os.chmod(directory / 'capture.lock', 0o600)
        fcntl.flock(lock, fcntl.LOCK_EX)
        state_path = directory / 'replay.json'
        state = json.loads(state_path.read_bytes()) if state_path.exists() else {}
        if state.get(identity) == fingerprint:
            return
        if identity not in state and len(state) >= 4096:
            raise ValueError('session_capacity')
        state[identity] = fingerprint
        # Commit replay detection first: interrupted writes can lose a sample,
        # but cannot renew freshness from a repeated callback after a crash.
        atomic(state_path, encode(state))
        atomic(directory / 'quota.json', encode({'schema_version': 1, 'captured_at': now, 'windows': windows}))


def install(settings, directory):
    directory.mkdir(parents=True, mode=0o700, exist_ok=True)
    os.chmod(directory, 0o700)
    raw = settings.read_bytes() if settings.exists() else b'{}'
    value = json.loads(raw)
    original = value.get('statusLine')
    config_path = directory / 'forward.json'
    script = directory / 'statusline.py'
    command = shlex.join([sys.executable, str(script), '--directory', str(directory)])
    if config_path.exists():
        config = json.loads(config_path.read_bytes())
        if original != config['installed']:
            raise ValueError('configuration_changed')
        atomic(script, Path(__file__).read_bytes())
        return
    if original is not None and (not isinstance(original, dict) or original.get('type') != 'command' or not isinstance(original.get('command'), str)):
        raise ValueError('unsupported_statusline')
    installed = dict(original or {'type': 'command'})
    installed['command'] = command
    config = {'original': original, 'installed': installed}
    atomic(directory / 'settings-before.json', raw)
    atomic(script, Path(__file__).read_bytes())
    atomic(config_path, encode(config))
    value['statusLine'] = installed
    if (settings.read_bytes() if settings.exists() else b'{}') != raw:
        raise ValueError('configuration_changed')
    atomic(settings, encode(value))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--directory', required=True, type=Path)
    parser.add_argument('--settings', type=Path)
    parser.add_argument('--install', action='store_true')
    args = parser.parse_args()
    if args.install:
        if args.settings is None or not args.directory.is_absolute() or not args.settings.is_absolute():
            raise ValueError('invalid_path')
        install(args.settings, args.directory)
        print('Claude status-line bridge installed; original settings backed up.')
        return 0
    raw = sys.stdin.buffer.read(LIMIT + 1)
    try:
        if len(raw) > LIMIT:
            raise ValueError('input_too_large')
        capture(raw, args.directory)
    except Exception:
        # Clear the published sample rather than retain a misleading balance.
        try:
            atomic(args.directory / 'quota.json', encode({'schema_version': 1, 'captured_at': time.time(), 'windows': []}))
        except Exception:
            pass
        print('agent_usage_claude_quota_unavailable', file=sys.stderr)
    config = json.loads((args.directory / 'forward.json').read_bytes())
    original = config.get('original')
    if original:
        # Never interpret or log the existing user command ourselves.
        if len(raw) > LIMIT:
            with tempfile.TemporaryFile() as forwarded:
                forwarded.write(raw)
                shutil.copyfileobj(sys.stdin.buffer, forwarded)
                forwarded.seek(0)
                return subprocess.run(['/bin/sh', '-c', original['command']], stdin=forwarded).returncode
        return subprocess.run(['/bin/sh', '-c', original['command']], input=raw).returncode
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except Exception:
        print('agent_usage_claude_bridge_failed', file=sys.stderr)
        sys.exit(1)
