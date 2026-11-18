import copy
import json
from pathlib import Path
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from fixture_tool.definitions import definitions, FixtureError
from fixture_tool.scenarios import validate, participant_definitions, ScenarioError, native_command
from fixture_tool.screen_state import capture_candidates


def scenario():
    ds = {d.name: d for d in definitions(ROOT)}
    return dict(schemaVersion=2, id='preview-case', name='preview', version=1,
                fixtureId='page-navigation', fixtureVersion=ds['page-navigation'].source_hash,
                fixtureVersions={name: d.source_hash for name, d in ds.items()},
                state=dict(coordinateSystem='screen-top-left-points',
                           presentation=dict(mode='side', fixtureId='rich-document', widthFraction=.4),
                           required=['target', 'screenshot', 'presentation']))


class ScreenStateTests(unittest.TestCase):
    def test_popup_replay_requires_pixel_witness_and_semantic_target(self):
        value = scenario()
        value['state']['overlay'] = dict(kind='hover', text='Document outline', targetClass='notion-floating-table-of-contents', expectedText='N01')
        value['state']['required'].append('overlay')
        validate(value)
        for change in [dict(expectedText=''), dict(targetClass='x1n2onr6')]:
            broken = copy.deepcopy(value)
            broken['state']['overlay'].update(change)
            with self.assertRaises(FixtureError): validate(broken)

    def test_required_presentation_and_source_versions(self):
        value = scenario()
        validate(value)
        value['state']['required'].remove('presentation')
        with self.assertRaises(FixtureError): validate(value)
        value = scenario()
        del value['fixtureVersions']['rich-document']
        with self.assertRaises(FixtureError): validate(value)

    def test_invalid_preview_references_and_nonfinite_width(self):
        for change in [dict(widthFraction=float('nan')), dict(widthFraction=1), dict(rowIndex=-1), dict(rowIndex=True)]:
            value = scenario(); value['state']['presentation'].update(change)
            with self.assertRaises(FixtureError): validate(value)

    def test_utf16_scroll_range_and_duplicate_container_axis(self):
        value = scenario()
        scroll = dict(scope='preview', axis='y', mode='anchor', anchor={'text': '😀a'}, offset=80,
                      rangeLocation=2, rangeLength=1)
        value['state'].update(scrolls=[scroll], required=['target', 'screenshot', 'presentation', 'scroll.0'])
        validate(value)
        scroll['rangeLength'] = 2
        with self.assertRaises(FixtureError): validate(value)
        scroll['rangeLength'] = 1
        value['state']['scrolls'].append(copy.deepcopy(scroll))
        value['state']['required'].append('scroll.1')
        with self.assertRaises(FixtureError): validate(value)

    def test_region_cannot_exceed_window(self):
        value = scenario()
        value['state'].update(window=dict(x=0,y=60,width=1024,height=700),
                              captureRegion=dict(rect=dict(x=900,y=0,width=200,height=100)))
        value['state']['required'].append('captureRegion')
        with self.assertRaises(FixtureError): validate(value)

    def test_participant_changes_fail_before_native_input(self):
        value = scenario()
        ds = {d.name: d for d in definitions(ROOT)}
        entries = {name: dict(status='ready', sourceHash=d.source_hash, pageId=name) for name, d in ds.items()}
        self.assertEqual(set(participant_definitions(ROOT,value,entries)), set(ds))
        entries['rich-document']['sourceHash'] = '0' * 64
        with self.assertRaises(ScenarioError): participant_definitions(ROOT,value,entries)
        entries['rich-document']['sourceHash'] = ds['rich-document'].source_hash
        del value['fixtureVersions']['mixed-language']
        with self.assertRaises(ScenarioError): participant_definitions(ROOT,value,entries)

    def test_packaged_runner_uses_launch_services(self):
        from unittest.mock import patch
        with patch('fixture_tool.scenarios.sys.platform', 'darwin'):
            command = native_command(Path('/tmp/My Tool.app/Contents/MacOS/Tool'), ['--request','/tmp/a b.json'])
            self.assertEqual(command, ['/usr/bin/open','-g','-n','-W','/tmp/My Tool.app','--args','--request','/tmp/a b.json'])
            self.assertEqual(native_command(Path('/tmp/Tool'), ['--inspect']), ['/tmp/Tool','--inspect'])

    def test_capture_candidates_are_tied_to_authored_tabs_and_mermaid_headings(self):
        ds = {d.name:d for d in definitions(ROOT)}
        tabs, _ = capture_candidates(ds['rich-document'], 'preview')
        self.assertEqual([t['selectedText'] for t in tabs], ['概要','確認事項','対象外'])
        self.assertTrue(all(t['scope']=='preview' and t['anchor']['text']=='R10｜タブの切り替え' for t in tabs))
        _, displays = capture_candidates(ds['media-diagrams'])
        self.assertEqual([d['anchor']['text'].split('｜')[0] for d in displays], ['I04','I05'])

    def test_bitmap_crop_requires_a_source_anchor_and_known_target(self):
        value = scenario()
        value['state']['required'].append('captureRegion')
        value['state']['captureRegion'] = dict(scope='main',target='followingImage')
        with self.assertRaises(FixtureError): validate(value)
        value['state']['captureRegion'].update(anchor={'text':'I02'},cutEdge='bottom',fraction=.5)
        validate(value)
        value['state']['captureRegion']['target'] = 'anyImage'
        with self.assertRaises(FixtureError): validate(value)

    def test_pixel_advance_requires_a_fixed_window_and_verified_reference(self):
        value = scenario()
        value['state'].update(scrolls=[dict(scope='code',axis='x',mode='start',advancePixels=240)])
        value['state']['required'].append('scroll.0')
        with self.assertRaises(FixtureError): validate(value)
        value['state']['window']=dict(x=0,y=60,width=1024,height=700)
        validate(value)
        value['state']['scrolls'][0]['mode']='end'
        with self.assertRaises(FixtureError): validate(value)
