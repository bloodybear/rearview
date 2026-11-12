#!/usr/bin/env python3
"""Build, execute independent mode trials, method benchmarks and paired reports in order."""
import json,pathlib,subprocess
repo=pathlib.Path(__file__).resolve().parents[2];tools=repo/'notion-fixtures/tools'
def execute(args):
 result=subprocess.run(args,cwd=repo,text=True,capture_output=True)
 print(result.stdout,flush=True)
 if result.returncode: raise RuntimeError(result.stderr)
 return pathlib.Path(result.stdout.strip().splitlines()[-1])
# Fixture contents are checked/restored once before UI experiments.
for fixture in ['layout-stress','rich-document','mixed-language','project-database']:
 execute([str(repo/'notion-fixtures/fixture'),'ensure',fixture])
activation=execute(['python3',str(tools/'run_ax_activation_research.py')])
rows=json.loads((activation/'summary.json').read_text())
mode=next((m for m in ['manual','enhanced','both'] if sum(r['mode']==m and r['status']=='collected' for r in rows)==3),None)
if mode is None:raise RuntimeError('No reproducible activation mode; inspect evidence before proceeding')
review=execute(['python3',str(tools/'run_ax_mode_review.py'),'--mode',mode])
execute(['python3',str(tools/'summarize_ax_mode_review.py'),str(activation),str(review)])

execute(['python3',str(tools/'audit_ax_research.py'),str(activation),str(review)])
