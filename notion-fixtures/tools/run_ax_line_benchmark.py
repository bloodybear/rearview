#!/usr/bin/env python3
"""Run explicit affected scenarios and benchmark both AX line paths on live shared handles."""
import argparse
import json
import os
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
    executable = repo / '.build/benchmark-ax-line-methods'
    subprocess.run(['swiftc', '-O', str(root / 'tools/benchmark_ax_line_methods.swift'), '-o', str(executable)], cwd=repo, check=True)
    cases, failures = [], []
    for scenario in args.scenarios:
        before = set((root / 'evaluations').glob('batch-*'))
        result = subprocess.run(['python3', str(root / 'tools/run_ax_prototype.py'), scenario, '--reuse-replay-app'], cwd=repo)
        batches = set((root / 'evaluations').glob('batch-*')) - before
        if len(batches) != 1:
            raise RuntimeError(f'Expected one standard batch for {scenario}: {batches}')
        batch = batches.pop()
        row = json.loads((batch / 'summary.json').read_text())['results'][0]
        if result.returncode or row['status'] != 'ok':
            failures.append({'scenario': scenario, 'batch': str(batch), 'result': row})
        else:
            report = root / 'evaluations' / row['report']
            target = output / (scenario + '.json')
            measured = subprocess.run([str(executable), str(report.parent), str(target)], cwd=repo)
            if measured.returncode:
                failures.append({'scenario': scenario, 'reason': 'benchmark_failed', 'report': str(report)})
            else:
                cases.append({'scenario': scenario, 'benchmark': target.name, 'report': os.path.relpath(report, output)})
        (output / 'manifest.json').write_text(json.dumps({'cases': cases, 'failures': failures}, ensure_ascii=False, indent=2))
    if not failures:
        subprocess.run(['python3', str(root / 'tools/summarize_ax_line_benchmark.py'), str(output)], cwd=repo, check=True)
    return 1 if failures else 0


if __name__ == '__main__':
    raise SystemExit(main())
