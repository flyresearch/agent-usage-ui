import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).with_name('claude-statusline-bridge.py')
spec = importlib.util.spec_from_file_location('bridge', SCRIPT)
bridge = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bridge)


def fixture(session='synthetic-session', duration=100, used=25):
    return json.dumps({'session_id': session, 'cost': {'total_api_duration_ms': duration},
                       'cwd': 'PRIVATE-PATH', 'transcript_path': 'PRIVATE-TRANSCRIPT',
                       'rate_limits': {'five_hour': {'used_percentage': used, 'resets_at': 2000000000},
                                       'seven_day': {'used_percentage': 50, 'resets_at': 2000500000}}}).encode()


class BridgeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)

    def tearDown(self):
        self.temp.cleanup()

    def test_sanitization_and_replay_across_sessions(self):
        bridge.capture(fixture(), self.root, now=1000)
        first = (self.root/'quota.json').read_bytes()
        bridge.capture(fixture(), self.root, now=2000)
        self.assertEqual(first, (self.root/'quota.json').read_bytes())
        bridge.capture(fixture(session='other'), self.root, now=3000)
        second = (self.root/'quota.json').read_bytes()
        bridge.capture(fixture(), self.root, now=4000)
        self.assertEqual(second, (self.root/'quota.json').read_bytes())
        bridge.capture(fixture(duration=101), self.root, now=5000)
        self.assertEqual(json.loads((self.root/'quota.json').read_bytes())['captured_at'], 5000)
        for path in self.root.glob('*.json'):
            self.assertNotIn(b'PRIVATE', path.read_bytes())
            self.assertNotIn(b'synthetic-session', path.read_bytes())
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)

    def test_invalid_numbers_and_missing_windows(self):
        for used in (True, -1, 101, float('nan')):
            with self.assertRaises(ValueError):
                bridge.capture(fixture(used=used), self.root, now=1000)
        value=json.loads(fixture());value.pop('rate_limits')
        bridge.capture(json.dumps(value).encode(), self.root, now=1000)
        self.assertEqual(json.loads((self.root/'quota.json').read_bytes())['windows'], [])

    def test_install_preserves_original_command_and_callback_io(self):
        settings=self.root/'settings.json'; directory=self.root/'private bridge'
        original={'type':'command','command':"cat; printf 'original-stderr' >&2; exit 7",'padding':3,'refreshInterval':10}
        settings.write_text(json.dumps({'statusLine':original,'unrelated':True}))
        raw=settings.read_bytes()
        bridge.install(settings,directory)
        current=json.loads(settings.read_bytes())
        self.assertTrue(current['unrelated'])
        self.assertEqual(current['statusLine']['padding'],3)
        self.assertEqual(current['statusLine']['refreshInterval'],10)
        self.assertEqual((directory/'settings-before.json').read_bytes(),raw)
        self.assertEqual(json.loads((directory/'forward.json').read_bytes())['original'],original)
        bridge.install(settings,directory)
        p=subprocess.run(['/bin/sh','-c',current['statusLine']['command']],input=fixture(),capture_output=True)
        self.assertEqual(p.returncode,7);self.assertEqual(p.stdout,fixture());self.assertEqual(p.stderr,b'original-stderr')
        self.assertEqual(len(json.loads((directory/'quota.json').read_bytes())['windows']),2)
        # Malformed payload invalidates quota but still forwards unchanged stdin.
        p=subprocess.run(['/bin/sh','-c',current['statusLine']['command']],input=b'invalid',capture_output=True)
        self.assertEqual(p.stdout,b'invalid');self.assertEqual(p.returncode,7)
        self.assertEqual(json.loads((directory/'quota.json').read_bytes())['windows'],[])
        oversized=b'x'*(bridge.LIMIT+200)
        p=subprocess.run(['/bin/sh','-c',current['statusLine']['command']],input=oversized,capture_output=True)
        self.assertEqual(p.stdout,oversized);self.assertEqual(p.returncode,7)
        current['statusLine']['command']='changed';settings.write_text(json.dumps(current))
        with self.assertRaises(ValueError):bridge.install(settings,directory)

    def test_without_original_does_not_add_output(self):
        settings=self.root/'settings.json';directory=self.root/'bridge'
        settings.write_text('{}');bridge.install(settings,directory)
        command=json.loads(settings.read_bytes())['statusLine']['command']
        p=subprocess.run(['/bin/sh','-c',command],input=fixture(),capture_output=True)
        self.assertEqual(p.returncode,0);self.assertEqual(p.stdout,b'')


if __name__ == '__main__':
    unittest.main()
