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
