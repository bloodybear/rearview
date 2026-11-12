#!/usr/bin/env python3
"""Independent activation trials; normal Notion termination only, never force quit."""
import argparse, json, pathlib, subprocess, time
from datetime import datetime, timezone
repo=pathlib.Path(__file__).resolve().parents[2]
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--resume',type=pathlib.Path)
args=parser.parse_args()
out=args.resume or repo/'notion-fixtures/evaluations'/('activation-'+datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ'))
out.mkdir(parents=True,exist_ok=True)
def run(args):
    r=subprocess.run(args,cwd=repo,text=True,capture_output=True)
    return r
r=run(['swiftc','notion-fixtures/tools/read_ax_research_state.swift','-o','/tmp/ax-research-state'])
if r.returncode: raise RuntimeError(r.stderr)
r=run(['swiftc','notion-fixtures/tools/probe_paragraph_lines.swift','-o','/tmp/probe-paragraph-lines'])
if r.returncode: raise RuntimeError(r.stderr)
rows=[]
for trial in range(3):
 for mode in ['none','manual','enhanced','both']:
    existing=out/f'{trial}-{mode}.json'
    if existing.exists():
        rows.append(json.loads(existing.read_text()))
        continue
    print(f'Trial {trial+1} {mode}',flush=True)
    quit_result=run(['osascript','-e','tell application id "notion.id" to quit'])
    for _ in range(50):
        alive=run(['pgrep','-x','Notion']).returncode==0
        if not alive: break
        time.sleep(.2)
    if alive or quit_result.returncode:
        raise RuntimeError('Normal quit blocked; no force termination attempted')
    run(['open','-b','notion.id']);time.sleep(3)
    run(['open','notion://www.notion.so/406aeee4075f810aac6fdc7085c93553']);time.sleep(3)
    # Read-only warm-up of native AX, without either accessibility-mode setter.
    for attempt in range(10):
        state = run(['/tmp/ax-research-state'])
        if 'https://app.notion.com/406aeee4075f810aac6fdc7085c93553' in state.stdout: break
        time.sleep(.5)
    (out/f'{trial}-{mode}-bootstrap.log').write_text(state.stdout+state.stderr)
    replay=run(['python3','notion-fixtures/tools/run_ax_prototype.py','--skip-ensure','layout-wrap-640-closed'])
    (out/f'{trial}-{mode}-replay.log').write_text(replay.stdout+'\n'+replay.stderr)
    if replay.returncode: raise RuntimeError('Replay failed; inspect log')
    path=out/f'{trial}-{mode}.json'
    probe=run(['/tmp/probe-paragraph-lines',str(path),mode])
    (out/f'{trial}-{mode}-probe.log').write_text(probe.stdout+'\n'+probe.stderr)
    if probe.returncode: raise RuntimeError('Probe failed; inspect log')
    rows.append(json.loads(path.read_text()))
    (out/'summary.json').write_text(json.dumps(rows,ensure_ascii=False,indent=2))
print(out,flush=True)
