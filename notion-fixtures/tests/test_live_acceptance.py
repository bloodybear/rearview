import base64
from pathlib import Path
import tempfile
import unittest

from live_scenarios import acceptance


class LiveAcceptanceTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        # A real 1x1 PNG, rather than an existence-only placeholder.
        (self.directory/'screen.png').write_bytes(base64.b64decode(
            'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScLbtAAAAABJRU5ErkJggg=='))
        self.scenario = dict(version=4,fixtureVersion='source',state=dict(required=['target','screenshot','finalState']))
        self.case = dict(allowedUnsupported=['zoom'])
        self.result = dict(status='partial',documentUnchanged=True,scenarioVersion=4,fixtureVersion='source',
                           runDirectory=str(self.directory),screenshot=dict(file='screen.png',pixelWidth=1,pixelHeight=1),
                           steps=[dict(item=item,status='verified') for item in ('target','screenshot','finalState','preflight','documentIntegrity')])

    def test_missing_final_proof_or_unsupported_preview_cannot_pass(self):
        self.assertEqual(acceptance(self.case,self.scenario,self.result),[])
        del self.result['steps'][2]
        self.assertTrue(acceptance(self.case,self.scenario,self.result))
        self.result['steps'].append(dict(item='presentation',status='unsupported'))
        self.case['allowedUnsupported'].append('presentation')
        self.assertTrue(any('presentation' in e for e in acceptance(self.case,self.scenario,self.result)))

    def test_wrong_png_size_and_changed_source_are_rejected(self):
        self.result['screenshot']['pixelWidth']=2
        self.assertIn('PNG dimensions do not match screenshot',acceptance(self.case,self.scenario,self.result))
        self.result['screenshot']['pixelWidth']=1
        self.result['scenarioVersion']=3
        self.assertTrue(any('versions' in e for e in acceptance(self.case,self.scenario,self.result)))

    def test_zoom_exception_requires_the_actual_size_command_evidence(self):
        self.scenario['state']['zoomPercent']=100
        self.result['steps'].append(dict(item='zoom',status='unsupported'))
        self.assertTrue(any('zoom command' in e for e in acceptance(self.case,self.scenario,self.result)))
        self.result['environment']=dict(zoomCommandsApplied='Actual Size')
        self.assertEqual(acceptance(self.case,self.scenario,self.result),[])
        self.result['documentUnchanged']=False
        self.assertIn('target/document integrity failed',acceptance(self.case,self.scenario,self.result))
