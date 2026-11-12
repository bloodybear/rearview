#!/usr/bin/env python3
"""Evidence-based summaries; complete strings alone do not prove visual-line geometry."""
import argparse,collections,difflib,html,json,pathlib,re,statistics
parser=argparse.ArgumentParser();parser.add_argument('activation',type=pathlib.Path);parser.add_argument('review',type=pathlib.Path);args=parser.parse_args()
def load(p):return json.loads(p.read_text())
def exact_lines(actual,reference):
 if len(actual)!=len(reference):return False
 for a,b in zip(actual,reference):
  if any(a.get(k)!=b.get(k) for k in ['start','length','text']):return False
  if any(abs(a['box'][k]-b['box'][k])>1 for k in ['x','y','width','height']):return False
 return bool(actual)
def summarize_methods(data):
 measurements=data['measurements'];ref=next(x['lines'] for x in measurements if x['method']=='characters' and x['role']=='AXStaticText')
 groups=collections.defaultdict(list)
 for m in measurements:groups[(m['role'],m['method'])].append(m)
 return [dict(role=role,method=method,samples=len(ms),complete=sum(m['complete'] for m in ms),geometryMatches=sum(exact_lines(m['lines'],ref) for m in ms),callsMedian=statistics.median(m['calls'] for m in ms),millisecondsMedian=1000*statistics.median(m['seconds'] for m in ms),millisecondsMax=1000*max(m['seconds'] for m in ms),lines=ms[0]['lines']) for (role,method),ms in groups.items()]
def signatures(rows):
 indexed={r['id']:r for r in rows};groups=collections.defaultdict(list)
 for r in rows:
  path=[];p=r.get('parent')
  while p is not None:
   parent=indexed[p];path.append((parent['role'],parent.get('title','')));p=parent.get('parent')
  key=(r['role'],r.get('value',''),r.get('title',''),tuple(path))
  groups[key].append(r)
 return groups
def compare(before,after):
 a,b=signatures(before),signatures(after);matched=[];ambiguous=0
 for key in a.keys() & b.keys():
  if len(a[key])==len(b[key])==1:matched.append((a[key][0],b[key][0]))
  else:ambiguous+=len(a[key])+len(b[key])
 fields=['frame','boundsForFullRange','attributes','parameterizedAttributes','decision','decisionReason']
 result = dict(beforeNodes=len(before),afterNodes=len(after),uniquePairs=len(matched),ambiguousNodes=ambiguous,beforeOnlyNodes=sum(len(a[k]) for k in a.keys()-b.keys()),afterOnlyNodes=sum(len(b[k]) for k in b.keys()-a.keys()),changes={f:[{'beforeNode':x['id'],'afterNode':y['id'],'role':x['role'],'text':x.get('value') or x.get('title'),'before':x.get(f),'after':y.get(f)} for x,y in matched if (sorted(x.get(f,[]))!=sorted(y.get(f,[])) if f in ['attributes','parameterizedAttributes'] else x.get(f)!=y.get(f))] for f in fields})
 # A changed aggregate value cannot match the text-key above. Report separately
 # only when role+ancestry is unique in BOTH complete trees; never guess siblings.
 sa,sb=collections.defaultdict(list),collections.defaultdict(list)
 for groups,target in [(a,sa),(b,sb)]:
  for key,nodes in groups.items():target[(key[0],key[3])].extend(nodes)
 result['structurallyUniqueTextChanges']=[]
 for key in sa.keys() & sb.keys():
  if len(sa[key])!=1 or len(sb[key])!=1:continue
  x,y=sa[key][0],sb[key][0]
  for field in ['value','title']:
   left,right=x.get(field,''),y.get(field,'')
   if left==right:continue
   edits=[dict(operation=op,before=left[max(0,i-20):min(len(left),j+20)],after=right[max(0,k-20):min(len(right),l+20)]) for op,i,j,k,l in difflib.SequenceMatcher(None,left,right,autojunk=False).get_opcodes() if op!='equal']
   result['structurallyUniqueTextChanges'].append(dict(role=x['role'],beforeNode=x['id'],afterNode=y['id'],field=field,beforeLength=len(left),afterLength=len(right),edits=edits))
 return result
def generate():
 activation=load(args.activation/'summary.json');review=load(args.review/'summary.json');output={'activation':[],'methods':[],'pairs':[]}
 for mode in ['none','manual','enhanced','both']:
  rs=[r for r in activation if r['mode']==mode];times=[r['readyAfterSeconds'] for r in rs if 'readyAfterSeconds'in r]
  output['activation'].append(dict(mode=mode,trials=len(rs),collected=sum(r['status']=='collected' for r in rs),readySeconds=times,settingErrors=[r['settingErrors'] for r in rs]))
 for r in review:
  if r['tag'].startswith('methods-'):
   output['methods'].append(dict(scenario=r['scenario'],runId=r['runId'],summary=summarize_methods(load(args.review/r['evidence']))))
  else:
   base=args.review.parent;folders={m:base/p for m,p in r['reports'].items()};mode=next(m for m in folders if m!='none')
   diff=compare(load(folders['none']/'rawAx.json'),load(folders[mode]/'rawAx.json'))
   output['pairs'].append(dict(scenario=r['scenario'],runId=r['runId'],reports=r['reports'],diff=diff,metadata={m:load(p/'metadata.json') for m,p in folders.items()},candidates={m:len(load(p/'candidate.json')) for m,p in folders.items()},lineBoxes={m:sum(len(c.get('lineRanges',[])) for c in load(p/'candidate.json')) for m,p in folders.items()}))
 if (args.review/'lifetime.json').exists():output['lifetime']=load(args.review/'lifetime.json')
 (args.review/'analysis.json').write_text(json.dumps(output,ensure_ascii=False,indent=2))
 def display(value):
  if isinstance(value,float):return f'{value:.3f}'
  if isinstance(value,list) and value and all(isinstance(v,float) for v in value):return ', '.join(f'{v:.3f}' for v in value)
  return str(value)
 def table(rows,columns):
  labels={'mode':'설정','trials':'반복','collected':'확보','readySeconds':'준비 시간(s)','settingErrors':'설정 반환 코드','role':'대상','method':'경로','samples':'측정 횟수','complete':'원문 완전 일치','geometryMatches':'줄 좌표 일치','callsMedian':'IPC 중앙값','millisecondsMedian':'중앙값(ms)','millisecondsMax':'최댓값(ms)'}
  return '<table><tr>'+''.join('<th>'+html.escape(labels.get(c,c))+'</th>' for c in columns)+'</tr>'+''.join('<tr>'+''.join('<td>'+html.escape(display(r.get(c,'')))+'</td>' for c in columns)+'</tr>' for r in rows)+'</table>'
 content='''<!doctype html><meta charset="utf-8"><title>AX 상세 모드 재검토</title><style>body{font:14px sans-serif;max-width:1300px;margin:30px}td,th{border:1px solid #ccc;padding:6px}table{border-collapse:collapse}code{white-space:pre-wrap}img{max-width:640px}.pair{display:flex;gap:12px}a{color:#1457a0}</style><h1>AX 활성화·라인 조회·기존 규칙 재검토</h1><p>연구용 결과입니다. 상세 모드가 실제로 보이는 문자열을 보장하지는 않습니다. 기본 수집 규칙과 앱의 제품 동작은 변경하지 않았습니다.</p>'''
 content+='<p><strong>SDK 확인 정정:</strong> marker 함수와 범위 속성은 현재 Apple SDK AXUIElement.h 및 AXWebConstants.h에 선언돼 있습니다. AXEnhancedUserInterface와 AXManualAccessibility는 별도의 앱 구현 신호이며, 후자는 Electron 공식 문서에 안내돼 있습니다.</p>'
 content+='<h2>독립 프로세스 활성화 조건</h2>'+table(output['activation'],['mode','trials','collected','readySeconds','settingErrors'])
 content+='<p>Notion 정상 종료·재실행 후 각 조건을 3회 수행했습니다. 부트스트랩은 모드 setter 없이 AX 트리를 읽습니다. 기본 AX 조회 자체의 접근성 활성화 효과까지 배제한 실험은 아닙니다.</p>'
 if output['methods'] and all(any(r['role']=='AXStaticText' and r['method']=='markers-local' and r['geometryMatches']==10 for r in g['summary']) for g in output['methods']):
  content+='<p><strong>일반 문단 권고:</strong> AXManualAccessibility로 준비 후 AXStaticText의 marker 줄 경계를 이동하고 로컬 AXTextMarkerRangeCreate로 범위를 구성해 문자열·좌표를 조회합니다. 두 너비에서 각 10회 기준 좌표와 일치했습니다. 실제 실패가 발견되기 전에는 문자별 fallback을 구현하지 않습니다. 불완전 결과는 기존 노드 박스와 미확정 상태로 남깁니다. 다른 노드 형태로의 일반화와 앱 통합은 수행하지 않았습니다.</p>'
 for group in output['methods']:
  content+='<h2>'+html.escape(group['scenario'])+' 조회 방식</h2>'+table(group['summary'],['role','method','samples','complete','geometryMatches','callsMedian','millisecondsMedian','millisecondsMax'])
  content+='<p>geometryMatches는 같은 화면에서 문자별 좌표로 구성한 기준과 1pt 이내 일치한 횟수입니다. 기준 자체도 아래 화면으로 검토해야 하며, 부모의 문단 전체 박스는 문자열이 완전해도 라인 성공으로 계산하지 않습니다.</p>'
  root=args.review.parents[1]
  replay=load(root/'runs'/group['runId']/'result.json');frame=replay['screenshot']['frame']
  best=next((r for r in group['summary'] if r['role']=='AXStaticText' and r['method']=='markers-local'),next(r for r in group['summary'] if r['role']=='AXStaticText' and r['method']=='characters'))
  image='../../runs/'+group['runId']+'/screen.png'
  content+=f'<div style="position:relative;width:{frame["width"]}px;height:{frame["height"]}px"><img style="max-width:none;width:100%;height:100%" src="{image}">'
  for number,line in enumerate(best['lines'],1):
   b=line['box'];content+=f'<div style="position:absolute;pointer-events:none;border:1px solid blue;box-sizing:border-box;left:{b["x"]-frame["x"]}px;top:{b["y"]-frame["y"]}px;width:{b["width"]}px;height:{b["height"]}px"><b style="position:absolute;right:100%;font-size:10px;color:blue">{number}</b></div>'
  content+='</div><p>방법 비교 실행의 재생 화면에 줄 박스를 표시했습니다. 캡처와 조회는 비원자적입니다. 호출 수는 AX IPC 횟수이며 로컬 marker 범위 생성은 포함하지 않습니다. 진단 추적은 측정 밖에서 수행합니다.</p>'

 for pair in output['pairs']:
  content+='<h2>'+html.escape(pair['scenario'])+'</h2><div class="pair">'
  for mode,p in pair['reports'].items():
   rel='../'+p
   meta=pair['metadata'][mode]
   content+=f'<div><a href="{rel}/index.html">{mode} 상세 보고서</a><p>선택 {pair["candidates"][mode]}개 / 라인 {pair["lineBoxes"][mode]}개 / truncated={meta["truncated"]}</p><p>AX 수집 {meta["elapsed"]:.3f}s · 캡처/저장 {meta.get("screenshotElapsed",0):.3f}s · 범위 {meta["rangeCalls"]}회/{meta["rangeElapsed"]:.4f}s · 활성화 관측 대기 {meta.get("activationObservationDelaySeconds",0)}s</p><img src="{rel}/screen.png"></div>'
  content+='</div><details><summary>노드 대응·변경 상세</summary><pre>'+html.escape(json.dumps(pair['diff'],ensure_ascii=False,indent=2))+'</pre></details>'
 lifetime=[]
 for row in output.get('lifetime',[]):
  size=re.search(r'w:([-\d.]+) h:([-\d.]+)',row.get('firstBounds',''))
  status='대상 없음' if not size else '유효 좌표' if float(size[1])>0 and float(size[2])>0 else '빈 좌표'
  lifetime.append({'단계':row['tag'],'PID':row['pid'],'창 ID':row.get('windowIDs',[]),'첫 문자':status,'Manual getter':row.get('AXManualAccessibility','')})
 content+='<h2>모드 유지 관측</h2>'+table(lifetime,['단계','PID','창 ID','첫 문자','Manual getter'])+'<p>Manual getter는 유효 좌표가 있어도 false였습니다. 같은 프로세스의 반복·문서 복귀·새 창 상태와 복원·재실행 상태를 비교하세요. 속성 getter만으로 내부 모드·캐시의 복원을 보장하지 않습니다. 서로 다른 프로세스의 노드 번호는 대응 키로 사용하지 않았으며 반복 문구의 모호한 대응은 별도 집계합니다.</p><details><summary>원본 모드 관측</summary><pre>'+html.escape(json.dumps(output.get('lifetime',[]),ensure_ascii=False,indent=2))+'</pre></details><p><a href="../../AX_MODE_REVIEW.md">결론·SDK 근거·한계 문서</a> · <a href="analysis.json">전체 분석 JSON</a></p>'
 (args.review/'index.html').write_text(content)
 (args.review.parent/'index.html').write_text('<!doctype html><meta charset="utf-8"><h1>AX 조사 보고서</h1><p><a href="'+args.review.name+'/index.html">최신 활성화·라인 조회·기존 규칙 비교 ('+str(len(output['pairs']))+'/11 시나리오)</a></p><p><a href="review.html">이전 2단계 조사 보고서</a></p>')
 print(args.review/'index.html')
if __name__=='__main__':generate()
