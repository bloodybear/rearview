import base64
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('native_report', Path(__file__).resolve().parents[1] / 'tools/render_ax_report.py')
report = importlib.util.module_from_spec(spec)
spec.loader.exec_module(report)


class NativeAXReportTests(unittest.TestCase):
    def test_native_units_and_live_frame_are_authoritative_and_translation_can_be_skipped(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / 'tools').mkdir()
            (root / 'tools/ax_report.html').write_text('__PAYLOAD__')
            run = root / 'runs/replay'
            run.mkdir(parents=True)
            (run / 'result.json').write_text(json.dumps({'scenarioId': 'example', 'fixtureId': 'fixture',
                                                       'screenshot': {'frame': {'x': 0}}}))
            folder = root / 'evaluations/replay/evaluation'
            folder.mkdir(parents=True)
            frame = dict(x=10, y=20, width=100, height=200)
            for name, value in [('rawAx', []), ('candidate', []),
                                ('metadata', {'runId': 'replay', 'windowFrame': frame, 'skipTranslation': True}),
                                ('native-paragraphs', {'units': [{'node': 1, 'text': '日本語', 'members': [],
                                                                 'lineRanges': [], 'box': frame, 'protectNonSourceText': False}], 'unresolved': []})]:
                (folder / (name + '.json')).write_text(json.dumps(value))
            with patch.object(report, '__file__', str(root / 'tools/render_ax_report.py')), \
                 patch.object(report, 'translation_policy_id', return_value='test'), \
                 patch.object(report, 'build_paragraphs', side_effect=AssertionError('legacy grouping called')):
                result = report.render(folder)
            payload = json.loads(base64.b64decode((folder / 'index.html').read_text()))
            self.assertEqual(result['paragraphs'], 1)
            self.assertEqual(payload['frame'], frame)
            self.assertEqual(payload['paragraphs'][0]['text'], '日本語')
            self.assertEqual(payload['paragraphs'][0]['translationResult']['status'], 'not_translated')

    def test_app_results_override_old_cache_and_preserve_failure_and_exclusion(self):
        for missing in (False, True):
            with self.subTest(missing=missing), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                (root/'tools').mkdir()
                (root/'tools/ax_report.html').write_text('__PAYLOAD__')
                (root/'runs/replay').mkdir(parents=True)
                (root/'runs/replay/result.json').write_text(json.dumps({'scenarioId':'example','fixtureId':'fixture','screenshot':{'frame':{}}}))
                folder = root/'evaluations/replay/evaluation'
                folder.mkdir(parents=True)
                units = [dict(node=i,text='日本語',members=[],lineRanges=[],box={},protectNonSourceText=False) for i in [1,2,3]]
                for name, value in [('rawAx',[]),('candidate',[]),
                                    ('metadata',dict(runId='replay',frameID=42,translationSource='rearview-session')),
                                    ('native-paragraphs',dict(units=units,unresolved=[]))]:
                    (folder/(name+'.json')).write_text(json.dumps(value))
                (root/'evaluations/paragraph-translations-ko.json').write_text(json.dumps({'policyId':'test','entries':[
                    dict(source='日本語',protectNonSourceText=False,status='translated',translation='STALE')]}))
                if not missing:
                    (folder/'native-translations.json').write_text(json.dumps(dict(frameID=42,entries=[
                        dict(node=1,source='日本語',status='failed',error='provider failure'),
                        dict(node=2,source='日本語',status='skipped_non_source_language') ])))
                with patch.object(report,'__file__',str(root/'tools/render_ax_report.py')), patch.object(report,'translation_policy_id',return_value='test'):
                    report.render(folder)
                    payload = json.loads(base64.b64decode((folder/'index.html').read_text()))
                    results = [unit['translationResult'] for unit in payload['paragraphs']]
                    self.assertEqual([r['status'] for r in results], ['not_translated']*3 if missing else ['failed','skipped_non_source_language','not_translated'])
                    self.assertNotIn('STALE',json.dumps(results))
                    if not missing:
                        (folder/'native-translations.json').write_text(json.dumps(dict(frameID=999,entries=[])))
                        with self.assertRaisesRegex(ValueError,'frame mismatch'):
                            report.render(folder)

    def test_app_render_images_are_exposed_and_bound_to_frame(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root/'tools').mkdir()
            (root/'tools/ax_report.html').write_text('<style></style>__PAYLOAD__')
            (root/'runs/replay').mkdir(parents=True)
            (root/'runs/replay/result.json').write_text(json.dumps({'scenarioId':'example','fixtureId':'fixture','screenshot':{'frame':{}}}))
            folder = root/'evaluations/replay/evaluation'
            folder.mkdir(parents=True)
            metadata = dict(runId='replay',frameID=42,renderFrameID=42,skipTranslation=True)
            for name, value in [('rawAx',[]),('candidate',[]),('metadata',metadata),('render-layout',[]),('native-paragraphs',dict(units=[],unresolved=[]))]:
                (folder/(name+'.json')).write_text(json.dumps(value))
            (folder/'render-translated.png').write_bytes(b'fixture')
            with patch.object(report,'__file__',str(root/'tools/render_ax_report.py')), patch.object(report,'translation_policy_id',return_value='test'):
                report.render(folder)
                page = (folder/'index.html').read_text()
                self.assertIn('id="axRenderImage"',page)
                self.assertIn('render-source.png',page)
                self.assertIn('render-debug.png',page)
                metadata['renderFrameID'] = 43
                (folder/'metadata.json').write_text(json.dumps(metadata))
                with self.assertRaisesRegex(ValueError,'rendering frame mismatch'):
                    report.render(folder)
