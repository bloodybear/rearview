#!/usr/bin/env python3
"""Compare native formula protection on saved AX-derived sources, opt-in only."""
import argparse
import json
from pathlib import Path
import platform
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('study', type=Path)
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[2]
    study = args.study.resolve()
    findings = json.loads((study / 'findings.json').read_text())
    unique = {c['placeholderSource']: {'key': c['placeholderSource'], 'parts': c['parts']} for c in findings['cases']}
    source = study / 'attributed-input.json'
    source.write_text(json.dumps(list(unique.values()), ensure_ascii=False, indent=2) + '\n')
    debug = repo / '.build/debug'
    objects = sorted(p for p in (debug / 'Rearview.build').glob('*.o') if p.name != 'main.swift.o')
    if not objects:
        raise RuntimeError('Run standard reports first to build the read-only product translation objects')
    binary = study / 'probe-math-attributed'
    command = ['swiftc', '-parse-as-library', '-swift-version', '6', '-module-name', 'AXMathAttributedResearch',
        '-I', str(debug / 'Modules'), '-F', str(debug), '-framework', 'Sparkle', '-Xlinker', '-rpath',
        '-Xlinker', str(debug.resolve()), '-o', str(binary), 'notion-fixtures/tools/probe_math_attributed_translation.swift',
        *map(str, objects)]
    result = subprocess.run(command, cwd=repo, capture_output=True, text=True)
    (study / 'build-attributed.log').write_text(result.stdout + '\n' + result.stderr)
    result.check_returncode()
    summary = {'runtimeMacOS': platform.mac_ver()[0], 'sources': len(unique),
               'scope': 'native API candidate, not current production broker; no cache changes, no model downloads', 'results': []}
    for label, filename, flags in [('lowLatency', 'attributed-output.json', []),
            ('lowLatencyBatch', 'attributed-output-batch.json', ['--batch']),
            ('highFidelity', 'attributed-output-high-fidelity.json', ['--high-fidelity'])]:
        output = study / filename
        # A failed new attempt must not be confused with an older successful file.
        if output.exists():
            output.rename(study / (filename + '.previous'))
        run = subprocess.run([str(binary), str(source), str(output), *flags], cwd=repo,
                             text=True, capture_output=True, timeout=120)
        (study / f'attributed-{label}.log').write_text(run.stdout + '\n' + run.stderr)
        summary['results'].append({'strategy': label, 'exit': run.returncode, 'file': filename})
        (study / 'native-translation-summary.json').write_text(json.dumps(summary, ensure_ascii=False, indent=2) + '\n')
        print(label, run.returncode, flush=True)
    return int(any(r['exit'] != 0 for r in summary['results']))


if __name__ == '__main__':
    raise SystemExit(main())
