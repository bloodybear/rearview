#!/usr/bin/env python3
"""Real macOS Notion replay check. Changes screen state, never document content.
Requires a ready layout-stress fixture, native app, AX and Screen Recording access.
"""
import json
import subprocess
import sys
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
IDS = ['layout-default', 'layout-narrow', 'layout-zoom', 'layout-clipped', 'layout-toggle-open', 'layout-toggle-closed']

def main():
    runs = []
    for identifier in IDS:
        pair = []
        for repeat in range(2):
            p = subprocess.run([str(ROOT/'fixture'), 'scenario', 'apply', identifier, '--json'], capture_output=True, text=True, timeout=180)
            if not p.stdout.strip():
                raise AssertionError(p.stderr)
            r = json.loads(p.stdout)
            print(identifier, repeat + 1, r['status'], r['runDirectory'], flush=True)
            assert r['status'] == 'partial', r
            assert r.get('documentUnchanged') is True, r
            assert r.get('screenshot') and (Path(r['runDirectory'])/'screen.png').is_file(), r
            assert all(s['status'] == ('unsupported' if s['item'] == 'zoom' else 'verified') for s in r['steps']), r['steps']
            assert 'zoomPercent' not in r['observed'], 'Never infer numeric zoom'
            pair.append(r)
            runs.append(dict(scenarioId=identifier, runId=r['runId'], status=r['status'], runDirectory=r['runDirectory']))
        a, b = [r['observed'] for r in pair]
        assert a['window'] == b['window'] and a['sidebarOpen'] == b['sidebarOpen']
        assert a.get('toggles') == b.get('toggles')
        if a['scroll']['mode'] == 'anchor':
            assert abs(a['scroll']['offset'] - b['scroll']['offset']) <= 2
        else:
            assert a['scroll'] == b['scroll']
    output = ROOT/'runs'/'live-scenarios-summary.json'
    output.write_text(json.dumps(runs, ensure_ascii=False, indent=2)+'\n')
    print('Passed: 12 real desktop runs, zoom explicitly unsupported. Summary:',output)

if __name__ == '__main__': main()
