#!/usr/bin/env python3
"""Reproduce line-method benchmarks and paired mode observations. No product policy changes."""
import argparse, json, pathlib, subprocess, time
from datetime import datetime,timezone
from run_ax_prototype import validate_collection
repo=pathlib.Path(__file__).resolve().parents[2];root=repo/'notion-fixtures'
parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--resume',type=pathlib.Path);parser.add_argument('--mode',choices=['manual','enhanced','both'],default='manual');args=parser.parse_args()
out=args.resume or root/'evaluations'/('mode-review-'+datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ'));out.mkdir(parents=True,exist_ok=True)
def run(command,name):
 r=subprocess.run(command,cwd=repo,text=True,capture_output=True)
 (out/(name+'.log')).write_text(r.stdout+'\n'+r.stderr)
 return r
def check(command,name):
 r=run(command,name)
 if r.returncode: raise RuntimeError(name+': '+r.stderr[-1000:])
 return r
for source,binary in [('read_ax_research_state.swift','ax-research-state'),('compare_paragraph_lines.swift','compare-paragraph-lines'),('ax_mode_control.swift','ax-mode-control')]:
 check(['swiftc',str(root/'tools'/source),'-o','/tmp/'+binary],'build-'+binary)
check(['swift','build','--product','NotionAXEvaluation'],'build-collector')
check([str(repo/'scripts/package_notion_scenarios.sh')],'build-replay')
state=json.loads((root/'state.json').read_text())
def start(scenario,tag):
 check(['osascript','-e','tell application id "notion.id" to quit'],tag+'-quit')
 for _ in range(50):
  if subprocess.run(['pgrep','-x','Notion'],capture_output=True).returncode:break
  time.sleep(.2)
 else:raise RuntimeError('Normal quit blocked; refusing force quit')
 check(['open','-b','notion.id'],tag+'-open');time.sleep(3)
 definition=json.loads(next((root/'scenarios').glob('*/'+scenario+'.json')).read_text())
 page=state['fixtures'][definition['fixtureId']]['pageId'].replace('-','')
 check(['open','notion://www.notion.so/'+page],tag+'-page');time.sleep(3)
 for _ in range(20):
  r=check(['/tmp/ax-research-state'],tag+'-bootstrap')
  if page in r.stdout.replace('-',''):break
  time.sleep(.5)
 replay=run([str(root/'fixture'),'scenario','apply',scenario,'--json'],tag+'-replay')
 if replay.returncode not in [0,2]:raise RuntimeError(tag+' replay failed')
 result=json.loads(replay.stdout)
 bad=[s for s in result['steps'] if s['status']!='verified' and not(s['item']=='zoom' and s['status']=='unsupported')]
 if bad:raise RuntimeError(str(bad))
 return result
rows=json.loads((out/'summary.json').read_text()) if (out/'summary.json').exists() else []
def save(): (out/'summary.json').write_text(json.dumps(rows,ensure_ascii=False,indent=2))
for scenario in ['layout-wrap-640-closed','layout-wrap-1024-closed']:
 tag='methods-'+scenario
 if any(r['tag']==tag for r in rows):continue
 print(tag,flush=True);result=start(scenario,tag)
 evidence=out/(tag+'.json');check(['/tmp/compare-paragraph-lines',str(evidence),args.mode],tag+'-measure')
 rows.append({'tag':tag,'scenario':scenario,'runId':result['runId'],'evidence':evidence.name});save()
scenarios=['layout-wrap-640-closed','layout-wrap-1024-closed','rich-r04','mixed-m08','layout-toggle-depth-0','layout-toggle-depth-1','layout-toggle-depth-2','database-nowrap-left','database-wrap-left','layout-scroll-clipped-top','layout-scroll-clipped-bottom']
for scenario in scenarios:
 tag='pair-'+scenario
 if any(r['tag']==tag for r in rows):continue
 print(tag,flush=True);result=start(scenario,tag);reports={}
 for mode in ['none',args.mode]:
  r=check([str(repo/'.build/debug/NotionAXEvaluation'),'collect','--root',str(root),'--run-id',result['runId'],'--activation',mode],tag+'-'+mode)
  folder=pathlib.Path(r.stdout.strip());c=json.loads((folder/'candidate.json').read_text());validate_collection(folder,c)
  m=json.loads((folder/'metadata.json').read_text())
  if not m['targetAndFrameMatch']:raise RuntimeError('Frame/page mismatch')
  reports[mode]=str(folder.relative_to(root/'evaluations'))
 rows.append({'tag':tag,'scenario':scenario,'runId':result['runId'],'reports':reports});save()
if not (out/'lifetime.json').exists():
 print('lifetime observations',flush=True)
 start('layout-wrap-640-closed','lifetime')
 lifetime=[]
 def observe(tag,action=[]):
  r=check(['/tmp/ax-mode-control',*action],'lifetime-'+tag)
  lifetime.append({'tag':tag,**json.loads(r.stdout)})
  (out/'lifetime-progress.json').write_text(json.dumps(lifetime,ensure_ascii=False,indent=2))
 observe('initial')
 try:
  observe('enable',['set','true']);time.sleep(2.5)
  for i in range(3): observe('repeat-'+str(i))
  rich=state['fixtures']['rich-document']['pageId'].replace('-','')
  check(['open','notion://www.notion.so/'+rich],'lifetime-away');time.sleep(3);observe('other-document')
  page=state['fixtures']['layout-stress']['pageId'].replace('-','')
  check(['open','notion://www.notion.so/'+page],'lifetime-back');time.sleep(3);observe('returned-document')
  old_window_ids=lifetime[-1].get('windowIDs',[])
  observe('close-window',['close-window']);time.sleep(1)
  observe('closed-window')
  if lifetime[-1].get('windowIDs'): raise RuntimeError('Window close not verified; refusing to claim recreation')
  observe('create-new-window',['new-window']);time.sleep(1)
  check(['open','notion://www.notion.so/'+page],'lifetime-new-window');time.sleep(3);observe('recreated-window')
  if not lifetime[-1].get('windowIDs') or set(lifetime[-1]['windowIDs']) & set(old_window_ids): raise RuntimeError('New window identity not verified')
 finally:
  observe('restore',['set','false']);time.sleep(2.5);observe('after-restore')
 # Remove the research-created window before testing process restart. Notion
 # may otherwise restore duplicate document windows and make replay ambiguous.
 observe('cleanup-created-window',['close-window']);time.sleep(1);observe('after-window-cleanup')
 check(['osascript','-e','tell application id "notion.id" to quit'],'lifetime-restart-quit')
 for _ in range(50):
  if subprocess.run(['pgrep','-x','Notion'],capture_output=True).returncode:break
  time.sleep(.2)
 else:raise RuntimeError('Normal quit blocked')
 check(['open','-b','notion.id'],'lifetime-restart-open');time.sleep(3)
 page=state['fixtures']['layout-stress']['pageId'].replace('-','')
 check(['open','notion://www.notion.so/'+page],'lifetime-restart-page');time.sleep(3)
 check(['/tmp/ax-research-state'],'lifetime-restart-bootstrap');observe('after-restart')
 (out/'lifetime.json').write_text(json.dumps(lifetime,ensure_ascii=False,indent=2))
print(out,flush=True)
