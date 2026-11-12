#!/usr/bin/env python3
"""Replay explicit scenarios through the standard pipeline, then probe native AX line ranges."""
import argparse
import json
import subprocess
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('scenarios', nargs='+')
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[2]
    root = repo / 'notion-fixtures'
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    executable = repo / '.build/probe-paragraph-native-lines'
    subprocess.run(['swiftc', str(root / 'tools/probe_paragraph_native_lines.swift'), '-o', str(executable)], cwd=repo, check=True)
    cases, failures = [], []
    for scenario in args.scenarios:
        before = set((root / 'evaluations').glob('batch-*'))
        result = subprocess.run(['python3', str(root / 'tools/run_ax_prototype.py'), scenario, '--reuse-replay-app'], cwd=repo)
        batches = set((root / 'evaluations').glob('batch-*')) - before
        if len(batches) != 1:
            raise RuntimeError(f'Expected one standard batch for {scenario}: {batches}')
        batch = batches.pop()
        summary = json.loads((batch / 'summary.json').read_text())
        row = summary['results'][0]
        if result.returncode or row['status'] != 'ok':
            failures.append({'scenario': scenario, 'batch': str(batch), 'result': row})
            continue
        probe = output / (scenario + '.json')
        subprocess.run([str(executable), str(probe)], cwd=repo, check=True)
        import os
        cases.append({'scenario': scenario, 'probe': probe.name,
                      'report': os.path.relpath(root / 'evaluations' / row['report'], output)})
        (output / 'manifest.json').write_text(json.dumps({'cases': cases, 'failures': failures}, ensure_ascii=False, indent=2))
    (output / 'manifest.json').write_text(json.dumps({'cases': cases, 'failures': failures}, ensure_ascii=False, indent=2))
    subprocess.run(['python3', str(root / 'tools/render_cross_node_lines.py'), str(output / 'manifest.json')], cwd=repo, check=True)
    return 1 if failures else 0


if __name__ == '__main__':
    raise SystemExit(main())
