"""Offline native-frame comparison; no AX calls, no default selection changes."""
import json,base64,re,html,shutil,collections,math,time
from pathlib import Path
from render_ax_report import clip_timeline_box,clip_below_header,subtract_preview
ROOT=Path(__file__).resolve().parents[1];OUT=ROOT/'evaluations/paragraph-clip-study-20261112';OUT.mkdir(exist_ok=True)
paths={}
for batch in ['batch-20261111T232325.326327Z','batch-20261112T045813.642696Z']:
 for r in json.loads((ROOT/'evaluations'/batch/'summary.json').read_text())['results']:
  if r['status']=='ok':paths[r['scenario']]=ROOT/'evaluations'/Path(r['report']).parent

def valid(b):return isinstance(b,dict) and all(isinstance(b.get(k),(int,float)) and math.isfinite(b[k]) for k in ('x','y','width','height')) and b['width']>1 and b['height']>1

def contains(a,b):return a['x']<=b['x'] and a['y']<=b['y'] and a['x']+a['width']>=b['x']+b['width'] and a['y']+a['height']>=b['y']+b['height']
def intersect(a,b):
 x,y=max(a['x'],b['x']),max(a['y'],b['y']);return dict(x=x,y=y,width=max(0,min(a['x']+a['width'],b['x']+b['width'])-x),height=max(0,min(a['y']+a['height'],b['y']+b['height'])-y))
def ancestors(n,raw):
 chain=[];p=raw[n].get('parent')
 while p is not None:
  chain.append(p);p=raw[p].get('parent')
 return chain

def wrapper(unit,raw):
 members=unit['members'];chains=[ancestors(n,raw) for n in members];boundaries={'AXButton','AXPopUpButton','AXRadioButton','AXTextArea','AXWindow','AXWebArea'}
 common=set(chains[0]);
 for c in chains[1:]:common.intersection_update(c)
 for n in chains[0]:
  if raw[n]['role'] in boundaries:break
  if n not in common or raw[n]['role'] not in {'AXGroup','AXLink'}:continue
  frame=raw[n].get('frame')
  if not valid(frame) or not all(valid(raw[m].get('frame')) and contains(frame,raw[m]['frame']) for m in members):continue
  descendants=[r for r in raw if n in ancestors(r['id'],raw)]
  if any(r['role'] in {'AXButton','AXPopUpButton','AXRadioButton','AXImage','AXTextArea'} for r in descendants):continue
  visibleText={r['id'] for r in descendants if r['role']=='AXStaticText' and (r.get('value') or r.get('recoveredText')) and valid(r.get('frame'))}
  if not visibleText.issubset(set(unit.get('lineSourceNodes',members))):continue
  return dict(node=n,role=raw[n]['role'],frame=frame)
 return None

def clipped(frame,unit,selected):
 b=dict(frame)
 for member in unit['members']:
  c=selected[member];v=c.get('effectiveClipRegion')
  if valid(v):b=intersect(b,v)
 for key in ['timelineOcclusion']:
  if unit.get(key):b=clip_timeline_box(b,unit[key]['panelFrame'])
 for key in ['timelineHeaderOcclusion','tableHeaderOcclusion']:
  if unit.get(key):b=clip_below_header(b,unit[key]['headerFrame'])
 pieces=[b]
 for oc in unit.get('previewOcclusions',[]):pieces=[p for a in pieces for p in subtract_preview(a,oc['panelFrame'])]
 return [p for p in pieces if valid(p)]

cases=[('share','database-nowrap-left',lambda p:p['text']=='Share'),('db-note','database-nowrap-left',lambda p:p['text'].startswith('短い漢字だけ')),
 ('db-emoji','database-nowrap-left',lambda p:p['text'].startswith('👩')),('db-short-title','database-nowrap-left',lambda p:p['text']=='未承認'),
 ('page-link','navigation-background-middle',lambda p:p['text'].startswith('\n日本語を中心')),
 ('body','rich-r04',lambda p:p['text'].startswith('この機能は管理者だけ')),
 ('svg-label','media-i04-diagram',lambda p:p['text']=='申請を受け付ける'),
 ('timeline','database-timeline-right',lambda p:'代理の担当者' in p['text'] and not p['text'].startswith('👩'))]
results=[];inventory=[];started=time.perf_counter()
for scenario in dict.fromkeys(c[1] for c in cases):
 folder=paths[scenario];raw=json.loads((folder/'rawAx.json').read_text());units=json.loads((folder/'paragraphs.json').read_text())['units']
 for u in units:
  w=wrapper(u,raw);inventory.append(dict(scenario=scenario,node=u['node'],wrapper=w,unitType=u['unitType']))
for key,scenario,predicate in cases:
 folder=paths[scenario];raw=json.loads((folder/'rawAx.json').read_text());units=json.loads((folder/'paragraphs.json').read_text())['units'];unit=next(u for u in units if predicate(u));selected={c['node']:c for c in json.loads((folder/'candidate.json').read_text())}
 w=wrapper(unit,raw);owner=next((raw[m].get('controlTextOwner') for m in unit['members'] if raw[m].get('controlTextOwner') is not None),unit['node']);ownerFrame=raw[owner].get('frame');variants={'current':None}
 if valid(ownerFrame):variants['owner']=ownerFrame
 if w:
  variants['wrapper']=w['frame']
  x=max(unit['box']['x'],w['frame']['x']);right=min(unit['box']['x']+unit['box']['width'],w['frame']['x']+w['frame']['width'])
  variants['wrapper-x']=dict(unit['box'],x=x,width=max(0,right-x))
 result=dict(key=key,scenario=scenario,node=unit['node'],text=unit['text'],current=unit['box'],owner=dict(node=owner,frame=ownerFrame),wrapper=w,lineBoxes=[l['box'] for l in unit.get('lineRanges',[])],reports={})
 originalPayload=json.loads(base64.b64decode(re.search(r"atob\('([^']+)'",(folder/'index.html').read_text())[1]));originalLines=[p.get('lineRanges',[]) for p in originalPayload['paragraphs']]
 for mode,frame in variants.items():
  dest=folder.parent/('research-clip-'+key+'-'+mode);dest.mkdir(exist_ok=True);shutil.copy2(folder/'screen.png',dest/'screen.png');data=json.loads(json.dumps(originalPayload));data['evaluation']=dest.name
  target=next(p for p in data['paragraphs'] if p['node']==unit['node']);pieces=(unit.get('visibleBoxes') or [unit['box']]) if frame is None else clipped(frame,unit,selected)
  if not pieces:continue
  target['box']=pieces[0];target['visibleBoxes']=pieces;target['clipStudy']=dict(researchOnly=True,mode=mode,rawCandidate=frame,originalParagraphBox=unit['box'],provenCSSClip=False)
  assert originalLines==[p.get('lineRanges',[]) for p in data['paragraphs']]
  data['clipStudyOverlay']=dict(node=unit['node'],pieces=pieces,lines=result['lineBoxes']);template=(ROOT/'tools/ax_report.html').read_text();payload=base64.b64encode(json.dumps(data,ensure_ascii=False).encode()).decode();page=template.replace('__PAYLOAD__',payload).replace('__SCENARIO__',html.escape(scenario+' · clip 연구 '+key+' / '+mode))
  legend='<p style="background:#fff0cc;padding:10px"><b>연구 전용 '+mode+'</b> · 초록: 잘림 영역 후보, 파랑: AX 원본 라인, 채움: 두 영역의 교차. 번역문 렌더링 시뮬레이션이 아닙니다. 기본 규칙은 변경하지 않았습니다.</p>'
  overlay='''<script>
const study=data.clipStudyOverlay,svgNS='http://www.w3.org/2000/svg',layer=document.createElementNS(svgNS,'svg');layer.id='clipStudyLayer';layer.setAttribute('viewBox','0 0 '+data.frame.width+' '+data.frame.height);Object.assign(layer.style,{position:'absolute',inset:'0',width:'100%',height:'100%',pointerEvents:'none',zIndex:'30'});
function studyRect(b,color,fill){const r=document.createElementNS(svgNS,'rect');for(const [k,v]of Object.entries({x:b.x-data.frame.x,y:b.y-data.frame.y,width:b.width,height:b.height,stroke:color,fill:fill||'none','stroke-width':2}))r.setAttribute(k,v);layer.append(r);}
for(const b of study.lines){studyRect(b,'#245bd4');for(const c of study.pieces){const x=Math.max(b.x,c.x),y=Math.max(b.y,c.y),w=Math.min(b.x+b.width,c.x+c.width)-x,h=Math.min(b.y+b.height,c.y+c.height)-y;if(w>0&&h>0)studyRect({x,y,width:w,height:h},'none','#16a34a44');}}
for(const b of study.pieces)studyRect(b,'#16803c');screen.append(layer);document.querySelectorAll('[data-mode]').forEach(b=>b.addEventListener('click',()=>layer.style.display=b.dataset.mode==='none'?'none':''));
</script>'''
  page=page.replace('<nav aria-label="박스 보기">',legend+'<nav aria-label="박스 보기">').replace('</body>','')+overlay
  (dest/'index.html').write_text(page);(dest/'clip-study.json').write_text(json.dumps(target['clipStudy'],ensure_ascii=False,indent=2));result['reports'][mode]=str((dest/'index.html').relative_to(ROOT/'evaluations'));result.setdefault('effectiveCandidates',{})[mode]=pieces
  result.setdefault('lineExposure',{})[mode]=[[intersect(line,p) for p in pieces if valid(intersect(line,p))] for line in result['lineBoxes']]
 results.append(result)
audit=dict(cases=results,inventory=inventory,counts=dict(collections.Counter('wrapper_candidate' if i['wrapper'] else 'no_wrapper_candidate' for i in inventory)),extraAXCalls=0,offlineAnalysisSeconds=time.perf_counter()-started,scope='Observed native frame candidates, not proof of CSS clipping. Original source/translation/AX observations/line rectangles unchanged.')
(OUT/'audit.json').write_text(json.dumps(audit,ensure_ascii=False,indent=2))
items=[]
for r in results:
 links=' · '.join('<a href="../'+v+'#paragraph='+str(r['node'])+'">'+k+'</a>' for k,v in r['reports'].items())
 items.append('<tr><td>'+html.escape(r['key']+' / '+r['text'][:45])+'</td><td>'+html.escape(str(r['current']))+'</td><td>'+html.escape(str(r['owner']))+'</td><td>'+html.escape(str(r['wrapper']))+'</td><td>'+links+'</td></tr>')
(OUT/'index.html').write_text('<meta charset="utf-8"><title>문단 clip 후보 비교</title><style>body{font:14px system-ui;margin:24px}table{border-collapse:collapse}td,th{border:1px solid #aaa;padding:8px;max-width:300px}</style><h1>문단 잘림 영역 후보 비교 · 연구용</h1><p>동일 캡처·동일 원문·동일 번역·동일 native 라인에서 잘림 영역 후보만 비교합니다. 개별 보고서는 기존 고정 양식에 조사 경계 오버레이를 추가했습니다. 초록은 후보, 파랑은 원본 라인, 채움은 교차 영역입니다. 실제 번역 배치나 CSS clip 증명이 아닙니다.</p><table><tr><th>사례</th><th>현재</th><th>컨트롤/소유자</th><th>텍스트 부모 후보</th><th>비교 보고서</th></tr>'+''.join(items)+'</table>')
print(json.dumps(dict(counts=audit['counts'],cases=len(results),reports=sum(len(r['reports']) for r in results),extraAXCalls=0),ensure_ascii=False));print(OUT/'index.html')
