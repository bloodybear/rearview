"""Local schema/persistence checks. Desktop verification is live_scenarios.py."""
import copy
import json
import sys
import tempfile
import unittest
import subprocess
import threading
import argparse
import contextlib
import io
from concurrent.futures import ThreadPoolExecutor
from types import SimpleNamespace
from unittest.mock import patch
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from fixture_tool.definitions import FixtureError, definitions
from fixture_tool.scenarios import ScenarioError, atomic_json, catalog, check_anchors, dispatch, execute, fixture_for_page, fixture_title, validate
from fixture_tool.ntn import APIError, Notion
import time
ROOT = Path(__file__).resolve().parents[1]

class ScenarioTests(unittest.TestCase):
    def setUp(self):
        self.value = copy.deepcopy(catalog(ROOT)[0])
    def test_committed_scenarios_pin_current_source(self):
        manifest=json.loads((ROOT/'scenario-catalog.json').read_text())
        for s in catalog(ROOT):
            d = definitions(ROOT, s['fixtureId'])[0]
            self.assertEqual(s['fixtureVersion'], d.source_hash)
            check_anchors(s, d)
            self.assertTrue(s['name'].isascii(), s['id'])
            if manifest['cases'].get(s['id'],{}).get('suite')=='core':
                self.assertTrue(s['name'].startswith('[core] '), s['id'])
    def test_replay_policy_blocks_source_fixtures_but_allows_the_sandboxes(self):
        from fixture_tool.replay_policy import rejection
        definitions_by_name={d.name:d for d in definitions(ROOT)}
        cases={s['id']:s for s in catalog(ROOT)}
        self.assertIn('Mermaid', rejection(cases['media-i04-source'],definitions_by_name['media-diagrams']))
        self.assertIn('Timeline', rejection(cases['database-timeline-left'],definitions_by_name['project-database']))
        self.assertIsNone(rejection(cases['media-i04-source'],definitions_by_name['sandbox-media-diagrams']))
        self.assertIsNone(rejection(cases['database-timeline-left'],definitions_by_name['sandbox-project-database']))
        self.assertIsNone(rejection(cases['database-wrap-left'],definitions_by_name['project-database']))
        self.assertIsNone(rejection(cases['media-i01'],definitions_by_name['media-diagrams']))
    def test_saved_presentation_rejection_precedes_state_and_native_launch(self):
        scenario=copy.deepcopy(next(s for s in catalog(ROOT) if s['id']=='database-timeline-left'))
        source=definitions(ROOT,'project-database')[0]
        scenario['fixtureId']=source.name
        scenario['fixtureVersion']=source.source_hash
        scenario['fixtureVersions'][source.name]=source.source_hash
        scenario['fixtureVersions'].pop('sandbox-project-database',None)
        with patch('fixture_tool.scenarios.State', side_effect=AssertionError('must not read Notion state')):
            report=execute(ROOT,scenario,'apply')
        self.assertEqual(report['status'],'failed')
        self.assertFalse(report['nativeInvoked'])
        self.assertEqual(report['apiRequests'],[])
        self.assertTrue(any(step.get('code')=='persistent_presentation_unsupported' for step in report['steps']))

    def test_sandbox_fixtures_are_selected_by_ensure_group(self):
        sandboxes=[d.name for d in definitions(ROOT) if d.mutable_presentation]
        self.assertEqual(sandboxes,['sandbox-media-diagrams','sandbox-project-database'])
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
    def test_list_includes_fixture_titles_from_manifests(self):
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            dispatch(ROOT, argparse.Namespace(scenario_command='list', json=True))
        value = json.loads(output.getvalue())
        listed = {fixture['id']: fixture for fixture in value['fixtures']}
        for definition in definitions(ROOT):
            self.assertEqual(listed[definition.name]['title'], fixture_title(definition))
            self.assertEqual(listed[definition.name]['version'], definition.source_hash)

    def test_focused_page_must_map_to_exactly_one_ready_current_fixture(self):
        page_id = '12345678-1234-1234-1234-123456789abc'
        first = SimpleNamespace(name='one', source_hash='a' * 64)
        second = SimpleNamespace(name='two', source_hash='b' * 64)
        with self.assertRaises(ScenarioError) as missing:
            fixture_for_page([first], {}, page_id)
        self.assertEqual(missing.exception.code, 'current_page_unregistered')

        entries = {
            'one': {'pageId': page_id, 'status': 'ready', 'sourceHash': first.source_hash},
            'two': {'pageId': page_id.upper(), 'status': 'ready', 'sourceHash': second.source_hash},
        }
        with self.assertRaises(ScenarioError) as ambiguous:
            fixture_for_page([first, second], entries, page_id)
        self.assertEqual(ambiguous.exception.code, 'current_page_ambiguous')

        with self.assertRaises(ScenarioError) as not_ready:
            fixture_for_page([first], {'one': {'pageId': page_id, 'status': 'incomplete', 'sourceHash': first.source_hash}}, page_id)
        self.assertEqual(not_ready.exception.code, 'fixture_not_ready')

        with self.assertRaises(ScenarioError) as stale:
            fixture_for_page([first], {'one': {'pageId': page_id, 'status': 'ready', 'sourceHash': 'c' * 64}}, page_id)
        self.assertEqual(stale.exception.code, 'fixture_version_mismatch')

        self.assertIs(fixture_for_page([first], {'one': {'pageId': page_id.upper(), 'status': 'ready', 'sourceHash': first.source_hash}}, page_id), first)

    def test_full_page_record_maps_to_its_ready_host_and_rejects_duplicate_registration(self):
        host = SimpleNamespace(name='database', source_hash='a' * 64)
        other = SimpleNamespace(name='other', source_hash='b' * 64)
        record_id = '12345678-1234-1234-1234-123456789abc'
        entries = {'database': dict(pageId='87654321-1234-1234-1234-123456789abc',
                                    rowIds=[record_id.upper()], status='ready', sourceHash=host.source_hash)}
        self.assertIs(fixture_for_page([host], entries, record_id), host)
        entries['other'] = dict(pageId=record_id, status='ready', sourceHash=other.source_hash)
        with self.assertRaises(ScenarioError) as error:
            fixture_for_page([host, other], entries, record_id)
        self.assertEqual(error.exception.code, 'current_page_ambiguous')

    def test_unregistered_capture_records_failure_without_saving_scenario(self):
        page_id = '12345678-1234-1234-1234-123456789abc'
        definition = SimpleNamespace(name='one', source_hash='a' * 64, manifest={})
        args = argparse.Namespace(scenario_command='capture-current', id='unregistered-capture', name=None, json=True)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'state.json').write_text(json.dumps({'version': 1, 'fixtures': {}}), encoding='utf-8')
            output = io.StringIO()
            with patch('fixture_tool.scenarios.catalog', return_value=[]), \
                 patch('fixture_tool.scenarios.definitions', return_value=[definition]), \
                 patch('fixture_tool.scenarios.resolve_current_page_id', return_value=page_id), \
                 contextlib.redirect_stdout(output):
                status = dispatch(root, args)
            report = json.loads(output.getvalue())
            self.assertEqual(status, 3)
            self.assertEqual(report['steps'][0]['code'], 'current_page_unregistered')
            self.assertNotIn('savedScenario', report)
            self.assertFalse((root / 'scenarios').exists())

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
        self.assertEqual(api._burst_limit, 1.0)
    def test_parallel_gets_use_a_small_burst(self):
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
            time.sleep(.9)
            with lock:
                active[0] -= 1
            return subprocess.CompletedProcess([], 0, '{"object":"view","id":"ok"}', '')
        with patch('fixture_tool.ntn.subprocess.run', side_effect=fake_run):
            with ThreadPoolExecutor(max_workers=5) as pool:
                list(pool.map(lambda i: api.request('GET', f'v1/views/{i}'), range(5)))
        self.assertEqual(peak[0], 5)
        self.assertLess(max(starts) - min(starts), .25)
        self.assertEqual(len(api.metrics), 5)

    def test_query_requests_keep_their_separate_spacing(self):
        api = Notion()
        starts = []
        def fake_run(*args, **kwargs):
            starts.append(time.monotonic())
            return subprocess.CompletedProcess([], 0, '{"object":"list","results":[],"has_more":false}', '')
        with patch('fixture_tool.ntn.subprocess.run', side_effect=fake_run):
            with ThreadPoolExecutor(max_workers=2) as pool:
                list(pool.map(lambda _: api.request('POST', 'v1/data_sources/test/query', {}), range(2)))
        self.assertGreaterEqual(max(starts) - min(starts), .34)
    def test_connection_minute_budget_blocks_new_request(self):
        api = Notion()
        api._starts.extend([time.monotonic()] * 180)
        api.deadline = time.monotonic() + .05
        with patch('fixture_tool.ntn.subprocess.run') as run:
            with self.assertRaises(APIError) as failure:
                api.request('GET', 'v1/views/test')
        self.assertEqual(failure.exception.code, 'timeout')
        run.assert_not_called()
    def test_atomic_write_preserves_definition(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)/'scenario.json'
            atomic_json(path,self.value)
            self.assertEqual(json.loads(path.read_text()),self.value)
            self.assertEqual(list(Path(directory).iterdir()),[path])
    def test_atomic_create_only_never_overwrites_existing_definition(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)/'scenario.json'
            original = copy.deepcopy(self.value)
            atomic_json(path, original, create_only=True)
            replacement = copy.deepcopy(original)
            replacement['name'] = 'replacement'
            with self.assertRaises(FileExistsError):
                atomic_json(path, replacement, create_only=True)
            self.assertEqual(json.loads(path.read_text()), original)
            self.assertEqual(list(Path(directory).iterdir()), [path])

    def test_save_renames_selected_scenario_and_preserves_version_history(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            original = copy.deepcopy(self.value)
            old_id = original['id']
            old_path = root / 'scenarios' / original['fixtureId'] / f'{old_id}.json'
            atomic_json(old_path, original)
            edited = copy.deepcopy(original)
            edited['id'] = 'renamed-scenario'
            input_path = root / 'edited.json'
            input_path.write_text(json.dumps(edited), encoding='utf-8')
            args = argparse.Namespace(scenario_command='save', definition=input_path,
                                      create_only=False, replace_id=old_id)
            with patch('fixture_tool.scenarios.definitions', return_value=[SimpleNamespace(source_hash=original['fixtureVersion'])]), \
                 patch('fixture_tool.scenarios.check_anchors'), contextlib.redirect_stdout(io.StringIO()):
                dispatch(root, args)
            saved = catalog(root)
            self.assertEqual(len(saved), 1)
            self.assertEqual(saved[0]['id'], 'renamed-scenario')
            self.assertEqual(saved[0]['version'], original['version'] + 1)
            self.assertFalse(old_path.exists())

    def test_save_rename_rejects_existing_id_without_changing_files(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            original = copy.deepcopy(self.value)
            target = copy.deepcopy(original)
            target['id'] = 'taken-scenario'
            for value in (original, target):
                atomic_json(root / 'scenarios' / value['fixtureId'] / f"{value['id']}.json", value)
            input_path = root / 'edited.json'
            input_path.write_text(json.dumps(target), encoding='utf-8')
            args = argparse.Namespace(scenario_command='save', definition=input_path,
                                      create_only=False, replace_id=original['id'])
            with patch('fixture_tool.scenarios.definitions', return_value=[SimpleNamespace(source_hash=original['fixtureVersion'])]), \
                 patch('fixture_tool.scenarios.check_anchors'):
                with self.assertRaises(FixtureError):
                    dispatch(root, args)
            self.assertEqual(catalog(root), sorted([original, target], key=lambda v: v['id']))

if __name__ == '__main__': unittest.main()
