#!/usr/bin/env python3
"""Audit recorded live evidence without replaying or changing Notion state."""
import argparse
from collections import Counter
from datetime import datetime, timezone
from html.parser import HTMLParser
import json
from pathlib import Path
import struct
from urllib.parse import unquote, urlsplit
from run_ax_prototype import validate_collection


def load(path):
    return json.loads(path.read_text())


class References(HTMLParser):
    def __init__(self):
        super().__init__()
        self.paths = []

    def handle_starttag(self, tag, attrs):
        for key, value in attrs:
            if tag in ('a', 'img') and key in ('href', 'src') and value:
                self.paths.append(value)


def audit(activation, review):
    trials = load(activation / 'summary.json')
    assert len(trials) == 12 and len({r['pid'] for r in trials}) == 12
    for mode in ('none', 'manual', 'enhanced', 'both'):
        subset = [r for r in trials if r['mode'] == mode]
        assert len(subset) == 3
        expected = 'geometry_unavailable' if mode == 'none' else 'collected'
        assert all(r['status'] == expected and r['firstCharacterBefore'] is None for r in subset)
        if mode != 'none':
            assert all(''.join(line['text'] for line in r['lines']) == r['text'] for r in subset)
            assert all(r['statesBefore'] == r['statesAfterRestore'] for r in subset)

    summary = load(review / 'summary.json')
    analysis = load(review / 'analysis.json')
    methods = [r for r in summary if r['tag'].startswith('methods-')]
    assert {r['scenario'] for r in methods} == {'layout-wrap-640-closed', 'layout-wrap-1024-closed'}
    samples = 0
    for group in methods:
        evidence = load(review / group['evidence'])
        measured = evidence['measurements']
        assert len(measured) == 100
        assert all(sum(r['role'] == role and r['method'] == method for r in measured) == 10
                   for role in ('AXStaticText', 'AXTextArea')
                   for method in ('standard', 'marker-indexed', 'markers', 'markers-local', 'characters'))
        reference = next(r['lines'] for r in measured if r['role'] == 'AXStaticText' and r['method'] == 'characters')
        for result in measured:
            if result['role'] == 'AXStaticText' and result['method'] == 'markers-local':
                assert result['complete'] and result['lines'] == reference
                assert ''.join(line['text'] for line in result['lines']) == evidence['text']
                assert result['calls'] == 1 + 3 * len(reference)
        samples += len(measured)

    expected = {'layout-wrap-640-closed', 'layout-wrap-1024-closed', 'rich-r04', 'mixed-m08',
                'layout-toggle-depth-0', 'layout-toggle-depth-1', 'layout-toggle-depth-2',
                'database-nowrap-left', 'database-wrap-left', 'layout-scroll-clipped-top',
                'layout-scroll-clipped-bottom'}
    pairs = analysis['pairs']
    assert len(pairs) == 11 and {r['scenario'] for r in pairs} == expected
    selected, lines, reports = 0, 0, 0
    for pair in pairs:
        signatures = []
        result = load(review.parents[1] / 'runs' / pair['runId'] / 'result.json')
        assert result['documentUnchanged']
        assert all(s['status'] == 'verified' or (s['item'] == 'zoom' and s['status'] == 'unsupported') for s in result['steps'])
        for mode, path in pair['reports'].items():
            folder = review.parent / path
            candidates = load(folder / 'candidate.json')
            validate_collection(folder, candidates)
            metadata = load(folder / 'metadata.json')
            assert metadata['targetAndFrameMatch'] and not metadata['truncated']
            assert metadata['activation'] == mode and metadata['screenshotElapsed'] >= 0
            assert metadata['screenshotSource'] == ('replay' if mode == 'none' else 'activated_window_screencapture')
            actual_size = struct.unpack('>II', (folder / 'screen.png').read_bytes()[16:24])
            assert actual_size == (result['screenshot']['pixelWidth'], result['screenshot']['pixelHeight'])
            signatures.append(Counter((c['text'], c['textSource'], json.dumps(c['box'], sort_keys=True)) for c in candidates))
            assert (folder / 'index.html').exists()
            reports += 1
        assert signatures[0] == signatures[1]
        selected += pair['candidates']['manual']
        lines += pair['lineBoxes']['manual']

    lifetime = {r['tag']: r for r in load(review / 'lifetime.json')}
    pid = lifetime['initial']['pid']
    for tag in ('repeat-0', 'repeat-1', 'repeat-2', 'returned-document', 'recreated-window'):
        assert lifetime[tag]['pid'] == pid
        assert 'w:14.000000 h:19.000000' in lifetime[tag]['firstBounds']
    assert not lifetime['closed-window']['windowIDs']
    assert set(lifetime['initial']['windowIDs']).isdisjoint(lifetime['recreated-window']['windowIDs'])
    assert lifetime['recreated-window']['windowIDs']
    assert lifetime['after-restart']['pid'] != pid
    for tag in ('initial', 'after-restore', 'after-restart'):
        assert 'w:0.000000 h:0.000000' in lifetime[tag]['firstBounds']
    assert len(lifetime['after-restart']['windowIDs']) == 1

    parser = References()
    parser.feed((review / 'index.html').read_text())
    local_links = 0
    for ref in parser.paths:
        url = urlsplit(ref)
        if not url.scheme and url.path:
            assert (review / unquote(url.path)).exists(), ref
            local_links += 1
    output = dict(status='passed', auditedAt=datetime.now(timezone.utc).isoformat(),
                  activationTrials=len(trials), benchmarkSamples=samples, pairedReports=reports,
                  selectedAcrossScreens=selected, lineBoxesAcrossScreens=lines,
                  localReferences=local_links, lifetimeChecks='passed',
                  limitation='Recorded integrity checks; visual inspection and product-wide accuracy are separate.')
    (review / 'audit.json').write_text(json.dumps(output, ensure_ascii=False, indent=2))
    print(json.dumps(output, ensure_ascii=False))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('activation', type=Path)
    parser.add_argument('review', type=Path)
    args = parser.parse_args()
    audit(args.activation, args.review)
