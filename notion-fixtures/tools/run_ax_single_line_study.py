import subprocess,pathlib,json
root=pathlib.Path(__file__).resolve().parents[2]
subprocess.run(['swiftc',str(root/'Sources/NotionAXEvaluation/TextRanges.swift'),str(root/'notion-fixtures/tools/probe_ax_single_line.swift'),'-o','/tmp/probe-ax-single-line'],check=True)
out=root/'notion-fixtures/evaluations/single-line-study-20261112';out.mkdir(exist_ok=True);results=[]
for scenario in ['database-nowrap-left','layout-wrap-1024-pinned','rich-r04']:
 r=subprocess.run(['python3','notion-fixtures/tools/run_ax_prototype.py','--reuse-replay-app',scenario],cwd=root,text=True,capture_output=True);(out/(scenario+'-run.log')).write_text(r.stdout+'\n'+r.stderr);print(scenario,'run',r.returncode,flush=True)
 batch=max((root/'notion-fixtures/evaluations').glob('batch-*'),key=lambda p:p.stat().st_mtime);s=json.loads((batch/'summary.json').read_text());row=s['results'][0]
 if row['status']=='ok':
  folder=root/'notion-fixtures/evaluations'/pathlib.Path(row['report']).parent
  p=subprocess.run(['/tmp/probe-ax-single-line',str(folder)],text=True,capture_output=True);(out/(scenario+'-probe.log')).write_text(p.stdout+'\n'+p.stderr);print(scenario,p.stdout,p.stderr,flush=True)
  row['probeStatus']='ok' if p.returncode == 0 else 'failed'
  if p.returncode == 0: row['probe']=str(folder/'single-line-probe.json')
 results.append(row);(out/'summary.json').write_text(json.dumps(results,ensure_ascii=False,indent=2))
