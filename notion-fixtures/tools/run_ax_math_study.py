#!/usr/bin/env python3
"""Replay just the math research screens, generate normal reports, then probe AX.

The separate issue artifacts do not replace the standard extraction reports.
No default active-suite membership or final extraction policy is changed.
"""
import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import subprocess
import sys


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('scenarios', nargs='*')
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[2]
    root = repo / 'notion-fixtures'
    scenarios = args.scenarios or ['rich-tab-checks', 'navigation-both-middle', 'math-research-top', 'math-research-bottom']
    output = root / 'evaluations' / ('math-study-' + datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ'))
    output.mkdir()
    sources = ['Sources/NotionAXEvaluation/AXTextAccess.swift', 'Sources/NotionAXEvaluation/TextRanges.swift',
               'Sources/NotionAXEvaluation/ParagraphLines.swift', 'notion-fixtures/tools/probe_ax_math.swift']
    binary = output / 'probe-ax-math'
    built = subprocess.run(['swiftc', *sources, '-o', str(binary)], cwd=repo, capture_output=True, text=True)
    (output / 'build.log').write_text(built.stdout + '\n' + built.stderr)
    built.check_returncode()
    summary = {'scope': 'AX-only math boundary and surrounding-text feasibility; production policy unchanged', 'results': []}
    for scenario in scenarios:
        before = set((root / 'evaluations').glob('batch-*'))
        run = subprocess.run([sys.executable, 'notion-fixtures/tools/run_ax_prototype.py', scenario], cwd=repo, capture_output=True, text=True)
        (output / f'{scenario}-run.log').write_text(run.stdout + '\n' + run.stderr)
        batches = set((root / 'evaluations').glob('batch-*')) - before
        if len(batches) != 1:
            raise RuntimeError('Expected exactly one batch from this sequential run')
        batch = batches.pop()
        result = json.loads((batch / 'summary.json').read_text())['results'][0]
        row = {'scenario': scenario, 'batch': batch.name, 'runExit': run.returncode, **result}
        summary['results'].append(row)
        if result['status'] == 'ok' and run.returncode == 0:
            folder = root / 'evaluations' / Path(result['report']).parent
            raw = json.loads((folder / 'rawAx.json').read_text())
            units = json.loads((folder / 'paragraphs.json').read_text())['units']
            # Selection here only identifies fixture samples for the opt-in probe.
            # This is not a formula classifier or a translation rule.
            ids = [u['node'] for u in units if raw[u['node']]['role'] == 'AXTextArea' and
                   (scenario.startswith('math-research-') or '残額\n' in u['text'])]
            if scenario.startswith('math-research-'):
                ids += [n['id'] for n in raw if 'notion-equation-block' in n.get('domClasses', []) and n['frame']['height'] > 1]
            if not ids:
                raise RuntimeError(f'No requested study paragraphs captured: {scenario}')
            probe = subprocess.run([str(binary), str(folder), *map(str, ids)], cwd=repo, capture_output=True, text=True)
            (output / f'{scenario}-probe.log').write_text(probe.stdout + '\n' + probe.stderr)
            row['probeExit'] = probe.returncode
            row['study'] = str((folder / 'math-study.json').relative_to(root / 'evaluations'))
            row['paragraphs'] = ids
        (output / 'summary.json').write_text(json.dumps(summary, ensure_ascii=False, indent=2) + '\n')
        print(scenario, row['status'], 'probe=', row.get('probeExit'), flush=True)
    print(output, flush=True)
    if any(r.get('probeExit') != 0 or r['runExit'] != 0 for r in summary['results']):
        return 1
    subprocess.run([sys.executable, str(root / 'tools/summarize_ax_math_study.py'), str(output), '--translate'], cwd=repo, check=True)
    subprocess.run([sys.executable, str(root / 'tools/run_math_attributed_study.py'), str(output)], cwd=repo, check=True)
    subprocess.run([sys.executable, str(root / 'tools/summarize_ax_math_study.py'), str(output)], cwd=repo, check=True)
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
