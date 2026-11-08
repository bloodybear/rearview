#!/usr/bin/env python3
"""Build, replay and collect both prototype screens; produce a local report index."""
import html
import json
from pathlib import Path
import subprocess

repo = Path(__file__).resolve().parents[2]
root = repo / 'notion-fixtures'
subprocess.run(['swift', 'build', '--product', 'NotionAXEvaluation'], cwd=repo, check=True)
links = []
for scenario in ('layout-wrap-1024-closed', 'layout-wrap-640-closed'):
    replay = subprocess.run([str(root / 'fixture'), 'scenario', 'apply', scenario, '--json'], cwd=repo, text=True, capture_output=True)
    if replay.returncode not in (0, 2):
        raise RuntimeError(replay.stderr + replay.stdout)
    result = json.loads(replay.stdout)
    unexpected = [s for s in result['steps'] if s['status'] != 'verified' and not (s['item'] == 'zoom' and s['status'] == 'unsupported')]
    if unexpected:
        raise RuntimeError(str(unexpected))
    collected = subprocess.run([str(repo / '.build/debug/NotionAXEvaluation'), 'collect', '--root', str(root), '--run-id', result['runId']], cwd=repo, text=True, capture_output=True, check=True)
    folder = Path(collected.stdout.strip())
    links.append(f'<li><a href="{html.escape(str((folder / "index.html").relative_to(root / "evaluations")))}">{html.escape(scenario)}</a></li>')
index = root / 'evaluations/index.html'
index.write_text('<meta charset="utf-8"><h1>AX prototype reports</h1><p>현재 규칙의 출력이며 정확성은 미검증입니다.</p><ul>' + ''.join(links) + '</ul>')
print(index)
