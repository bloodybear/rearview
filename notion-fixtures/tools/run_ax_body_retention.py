#!/usr/bin/env python3
"""Exercise retained AX bodies in one signed Rearview session; fixed reports only.

Uses Orca solely as the external test UI driver. Product collection never sends
input. Run after packaging dist/Rearview-dev.app with the development signature.
"""
import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import re
import subprocess
import sys
import time

from run_ax_prototype import replay_with_repair, validate_collection, write_batch_index
from render_ax_report import render


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--baseline',default='database-popup-body-baseline')
    parser.add_argument('--orca',default='orca')
    parser.add_argument('--nested-share',action='store_true',help='Also open the sharing access dropdown without selecting an option')
    args=parser.parse_args()
    root=Path(__file__).resolve().parents[1]
    repo=root.parent
    batch=root/'evaluations'/('batch-'+datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S.%fZ'))
    batch.mkdir(parents=True)
    control=batch/'sequence-control';control.mkdir()
    phases=[('body',None),('settings','Settings'),('layout','Layout Table'),
            ('layout-closed','Escape'),('filter','Filter'),('filter-closed','Escape'),('share','Share'),('share-closed','Escape')]
    if args.nested_share:
        phases[-1:-1]=[('share-access','Only people invited'),('share-access-closed','Escape')]
    (control/'phases.json').write_text(json.dumps([p[0]for p in phases]))
    def run(command,name):
        p=subprocess.run(command,cwd=repo,capture_output=True,text=True)
        (batch/(name+'.log')).write_text(p.stdout+'\n'+p.stderr)
        return p
    rows=[]
    process=None
    previous_folder=None
    try:
        run([args.orca,'skills','get','computer-use','--json'],'orca-guide').check_returncode()
        run([str(root/'fixture'),'ensure','project-database'],'ensure').check_returncode()
        replay=replay_with_repair(root,args.baseline,['project-database'],run,{})
        replay_data=json.loads(replay.stdout)
        invalid=[s for s in replay_data['steps']if s['status']!='verified' and not(s['item']=='zoom' and s['status']=='unsupported')]
        if invalid:raise RuntimeError('Replay failed: '+str(invalid))
        launch=['/usr/bin/open','-n','-g','-W','-a',str(repo/'dist/Rearview-dev.app'),
                '--stdout',str(batch/'collector.stdout'),'--stderr',str(batch/'collector.stderr'),'--args',
                '--collect-ax-report','--root',str(root),'--run-id',replay_data['runId'],'--ax-repeat','1',
                '--ax-report-sequence-control',str(control),'--command-status-file',str(batch/'collector.status')]
        process=subprocess.Popen(launch,cwd=repo)
        for index,(name,action) in enumerate(phases):
            if action:
                if action=='Escape':
                    result=run([args.orca,'computer','press-key','--app','notion.id','--key','Escape','--json'],name+'-action')
                else:
                    state=run([args.orca,'computer','get-app-state','--app','notion.id','--query',action,'--json'],name+'-target')
                    tree=json.loads(state.stdout)['result']['snapshot']['treeText']
                    matches=re.findall(r'^\s*(\d+) (?:버튼|팝업 버튼|메뉴 항목|button|pop up button|menu item) '+re.escape(action)+r'\s*$',tree,re.M)
                    if len(matches)!=1:raise RuntimeError('Ambiguous/missing popup trigger: '+action)
                    # Native AXPress scrolls Notion's parent scroller into view.
                    # A pointer click models the user's click without that AX side effect.
                    observed=json.loads((previous_folder/'rawAx.json').read_text())
                    def normalized(s):return ''.join(s.split())
                    targets=[n for n in observed if normalized(n.get('title',''))==normalized(action) and n.get('frame') and n['role'] in ['AXButton','AXPopUpButton','AXMenuItem']]
                    if len(targets)>1:
                        targets.sort(key=lambda n:n['frame']['width']*n['frame']['height'])
                        inner=targets[0]['frame']
                        if all(n['frame']['x']<=inner['x'] and n['frame']['y']<=inner['y'] and n['frame']['x']+n['frame']['width']>=inner['x']+inner['width'] and n['frame']['y']+n['frame']['height']>=inner['y']+inner['height'] for n in targets):
                            targets=targets[:1]
                    if len(targets)!=1:raise RuntimeError('Missing unique observed control frame: '+action)
                    f=targets[0]['frame']
                    window=json.loads((previous_folder/'metadata.json').read_text())['windowFrame']
                    command=[args.orca,'computer','click','--app','notion.id','--x',str(f['x']+f['width']/2-window['x']),
                             '--y',str(f['y']+f['height']/2-window['y']),'--json']
                    result=run(command,name+'-action')
                    d=json.loads(result.stdout)
                    if d.get('error',{}).get('code')=='background_unavailable':
                        result=run(command+['--restore-window'],name+'-foreground-action')
                d=json.loads(result.stdout)
                if not d.get('ok'):raise RuntimeError(str(d.get('error')))
                expected_text={'Settings':'View settings','Layout Table':'Load limit','Filter':'Add advanced filter','Share':'General access'}.get(action)
                if expected_text:
                    def opened():
                        proof=run([args.orca,'computer','get-app-state','--app','notion.id','--query',expected_text,'--json'],name+'-proof')
                        tree=json.loads(proof.stdout)['result']['snapshot']['treeText']
                        return any(re.match(r'^\s*\d+ ',line) and expected_text in line for line in tree.splitlines())
                    if not opened():
                        retry=run(command+['--restore-window'],name+'-retry-foreground')
                        if not json.loads(retry.stdout).get('ok') or not opened():raise RuntimeError('Popup did not open: '+action)
                (control/f'continue-{index}.json').write_text('{}')
            receipt=control/f'ready-{index}.json'
            deadline=time.monotonic()+550
            while not receipt.exists():
                if process.poll() is not None:raise RuntimeError('Collector exited before receipt '+str(index))
                if time.monotonic()>deadline:raise TimeoutError(name)
                time.sleep(.2)
            data=json.loads(receipt.read_text());folder=Path(data['output']);previous_folder=folder
            m=json.loads((folder/'metadata.json').read_text())
            candidates=json.loads((folder/'candidate.json').read_text());validate_collection(folder,candidates)
            rendered=render(folder)
            diag=m.get('bodyReuse',{})
            expected=name in ['settings','layout','filter','share','share-access']
            if name!='share-access-closed' and (diag.get('status')=='reused')!=expected:raise RuntimeError(name+': unexpected reuse '+str(diag))
            if name=='share-access' and diag.get('status')=='reused':
                # This child list hides its still-painted parent from AX. An
                # execution receipt alone must not call this visual case a pass.
                previous=json.loads((Path(rows[-1]['folder'])/'metadata.json').read_text())
                def subtract(box, mask):
                    x,y,w,h=box;mx,my,mw,mh=mask
                    l,t,r,b=max(x,mx),max(y,my),min(x+w,mx+mw),min(y+h,my+mh)
                    if r<=l or b<=t:return [box]
                    return [q for q in [(x,y,w,t-y),(x,b,w,y+h-b),(x,t,l-x,b-t),(r,t,x+w-r,b-t)]if q[2]>0 and q[3]>0]
                reg=m['selectionRegion'];scale_x=previous.get('pixelsPerPointX',2);scale_y=previous.get('pixelsPerPointY',2)
                for surface in previous['documentSurfaces']:
                    for box in surface['dialogBoxes']:
                        remaining=[((box['x']-reg['x'])*scale_x,(reg['y']+reg['height']-box['y']-box['height'])*scale_y,box['width']*scale_x,box['height']*scale_y)]
                        for mask in diag['panels']:
                            remaining=[piece for part in remaining for piece in subtract(part,(*mask[0],*mask[1]))]
                        if remaining:raise RuntimeError('Nested popup parent remains painted but is not masked')
            if expected:
                assert all(not s['bodyNodes'] for s in m['documentSurfaces'])
                assert (folder/'retained-body-paragraphs.json').exists()
                assert diag.get('panels')
            row={'scenario':args.baseline+'/'+name,'status':'ok','detail':diag.get('status','missing'),
                 'report':str((folder/'index.html').relative_to(root/'evaluations')),'folder':str(folder),
                 'sourceFrameID':diag.get('sourceFrameID'),'frameID':m['frameID'],'translationFailures':data['failed']}
            rows.append(row)
            print(name+': '+row['detail'],flush=True)
        process.wait(timeout=30)
        code=int((batch/'collector.status').read_text())
        if code not in [0,2]:raise RuntimeError('Collector status '+str(code))
    except Exception as error:
        rows.append({'scenario':args.baseline,'status':'failed','detail':str(error)})
        print(str(error),file=sys.stderr)
    finally:
        if process is not None and process.poll() is None:
            (control/'abort.json').write_text('{}')
            try:
                process.wait(timeout=15)
            except subprocess.TimeoutExpired:
                print('Collector has not acknowledged abort; control folder: '+str(control),file=sys.stderr)
        summary={'selected':len(phases),'collector':'rearview','succeeded':sum(r['status']=='ok'for r in rows),'results':rows}
        (batch/'summary.json').write_text(json.dumps(summary,ensure_ascii=False,indent=2))
        write_batch_index(root,batch,summary)
        print(batch/'index.html',flush=True)
    return 0 if summary['succeeded']==len(phases) else 1

if __name__=='__main__':raise SystemExit(main())
