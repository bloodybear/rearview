"""Local schema/persistence checks. Desktop verification is live_scenarios.py."""
import copy
import json
import sys
import tempfile
import unittest
import subprocess
import threading
from concurrent.futures import ThreadPoolExecutor
from unittest.mock import patch
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from fixture_tool.definitions import FixtureError, definitions
from fixture_tool.scenarios import atomic_json, catalog, check_anchors, validate
from fixture_tool.ntn import APIError, Notion
import time
ROOT = Path(__file__).resolve().parents[1]

class ScenarioTests(unittest.TestCase):
    def setUp(self):
        self.value = copy.deepcopy(catalog(ROOT)[0])
    def test_committed_scenarios_pin_current_source(self):
        for s in catalog(ROOT):
            d = definitions(ROOT, s['fixtureId'])[0]
            self.assertEqual(s['fixtureVersion'], d.source_hash)
            check_anchors(s, d)
    def test_coordinate_system_is_explicit(self):
        self.value['state']['coordinateSystem'] = 'pixels'
        with self.assertRaises(FixtureError): validate(self.value)
    def test_unknown_fields_are_not_silently_ignored(self):
        self.value['state']['fullscreen'] = True
        with self.assertRaises(FixtureError): validate(self.value)
    def test_required_missing_request_is_rejected(self):
        del self.value['state']['window']
        with self.assertRaises(FixtureError): validate(self.value)
    def test_invalid_offsets_and_window_sizes(self):
        for n in [float('nan'), float('inf'), -1]:
            s = copy.deepcopy(self.value); s['state']['window']['height'] = n
            with self.assertRaises(FixtureError): validate(s)
    def test_unknown_anchor_and_duplicate_source_rejected(self):
        for text in ['not in source', '確認してください。']:
            self.value['state']['scroll'] = dict(mode='anchor', anchor=dict(text=text), offset=0)
            with self.assertRaises(FixtureError): check_anchors(self.value, definitions(ROOT, 'layout-stress')[0])
    def test_selection_uses_utf16_units(self):
        self.value['state']['focus'] = dict(mode='selection', anchor=dict(text='😀'), location=1, length=2)
        with self.assertRaises(FixtureError): validate(self.value)
        self.value['state']['focus']['location'] = 0
        validate(self.value)
    def test_traversal_ids_rejected(self):
        self.value['id'] = '../escape'
        with self.assertRaises(FixtureError): validate(self.value)
    def test_api_deadline_is_bounded_and_identifiable(self):
        api = object.__new__(Notion)
        api.request_timeout = 10
        api.deadline = time.monotonic() + 2
        self.assertLessEqual(api.remaining_timeout(), 2)
        api.deadline = time.monotonic() - 1
        with self.assertRaises(APIError) as failure: api.remaining_timeout()
        self.assertEqual(failure.exception.code, "timeout")
    def test_rate_limit_uses_retry_after_and_sanitizes_metrics(self):
        api = Notion()
        responses = [subprocess.CompletedProcess([], 1, '{"object":"error","status":429,"code":"rate_limited","additional_data":{"retry_after":"1"}}', ''),
                     subprocess.CompletedProcess([], 0, '{"object":"page","id":"ok"}', '')]
        started = time.monotonic()
        with patch('fixture_tool.ntn.subprocess.run', side_effect=responses):
            self.assertEqual(api.request('GET', 'v1/pages/secret-id')['id'], 'ok')
        self.assertGreaterEqual(time.monotonic() - started, 1.0)
        self.assertEqual(len(api.metrics), 2)
        self.assertEqual(api.metrics[0]['endpoint'], 'v1/pages/{id}')
        self.assertEqual(api.metrics[0]['retryWaitMs'], 1000)
    def test_parallel_requests_are_staggered_and_bounded(self):
        api = Notion()
        lock = threading.Lock()
        starts = []
        active = [0]
        peak = [0]
        def fake_run(*args, **kwargs):
            with lock:
                starts.append(time.monotonic())
                active[0] += 1
                peak[0] = max(peak[0], active[0])
            time.sleep(.55)
            with lock:
                active[0] -= 1
            return subprocess.CompletedProcess([], 0, '{"object":"view","id":"ok"}', '')
        with patch('fixture_tool.ntn.subprocess.run', side_effect=fake_run):
            with ThreadPoolExecutor(max_workers=2) as pool:
                list(pool.map(lambda i: api.request('GET', f'v1/views/{i}'), range(3)))
        self.assertEqual(peak[0], 2)
        self.assertTrue(all(b - a >= .34 for a, b in zip(sorted(starts), sorted(starts)[1:])))
        self.assertEqual(len(api.metrics), 3)
    def test_atomic_write_preserves_definition(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)/'scenario.json'
            atomic_json(path,self.value)
            self.assertEqual(json.loads(path.read_text()),self.value)
            self.assertEqual(list(Path(directory).iterdir()),[path])

if __name__ == '__main__': unittest.main()
