#!/usr/bin/env python3
"""Compare observed AXVisibleOnly membership without changing production rules."""
import argparse
import html
import json
from pathlib import Path
from statistics import median


def intersects(a, b):
    return a['width'] > 0 and a['height'] > 0 and b['width'] > 0 and b['height'] > 0 and a['x'] < b['x']+b['width'] and b['x'] < a['x']+a['width'] and a['y'] < b['y']+b['height'] and b['y'] < a['y']+a['height']


def summarize(folder, root):
    read = lambda name: json.loads((folder/name).read_text())
    raw, baseline, probe, metadata = [read(n) for n in ['rawAx.json','candidate.json','offscreen.json','metadata.json']]
    by_id={n['id']:n for n in raw}
    sidecar=read('offscreen-membership.json') if (folder/'offscreen-membership.json').exists() else None
    observed=probe['nodes']
    membership_source='separate traversal, verified stable node identities and geometry'
    if sidecar:
        if [n['node'] for n in sidecar['nodes']] != [n['id'] for n in raw]:
            raise ValueError('Same-handle membership node IDs do not match rawAx')
        membership_source='same AXUIElement handles as rawAx, before activation restoration'
        observed=[]
        for n,measurement in zip(raw,sidecar['nodes']):
            f=measurement.get('frame',n.get('frame'))
            q={} if not f else {'AXPosition':{'value':{k:f[k] for k in ['x','y']}},'AXSize':{'value':{k:f[k] for k in ['width','height']}}}
            observed.append({'id':n['id'],'parent':n.get('parent'),'role':n['role'],'text':n.get('value',''),
                'title':n.get('title',''),'queries':q,'searchMembership':measurement['searchMembership']})
    # Never guess node identity by source string: repeated DB labels matter.
    def identity(n, probe=False):
        return (n['id'], n.get('parent'), n['role'], n.get('text' if probe else 'value','') if n['role'] != 'AXTextArea' else '', n.get('title',''))
    identity_match=len(raw)==len(observed) and all(identity(a)==identity(b,True) for a,b in zip(raw,observed))
    def probe_frame(n):
        q=n.get('queries',{});p=q.get('AXPosition',{}).get('value');s=q.get('AXSize',{}).get('value')
        return {**p,**s} if isinstance(p,dict) and isinstance(s,dict) else None
    geometry_changes=[n['id'] for n,p in zip(raw,observed) if n.get('frame') and probe_frame(p) and n['frame']!=probe_frame(p)] if identity_match else []
    parents_with_children={n.get('parent') for n in raw}
    ignored_geometry_changes=[i for i in geometry_changes if by_id[i].get('frame',{}).get('width',0)<=0 or by_id[i].get('frame',{}).get('height',0)<=0 or (i not in parents_with_children and not by_id[i].get('value') and not by_id[i].get('title'))]
    material_geometry_changes=[i for i in geometry_changes if i not in ignored_geometry_changes]
    aggregate_value_changes=[n['id'] for n,p in zip(raw,observed) if n['role']=='AXTextArea' and n.get('value','')!=p.get('text','')]
    searches=sidecar['searches'] if sidecar else probe['searches']
    root_ids={n['id'] for n in raw if n['role']=='AXWebArea'}
    invalid_searches=[s for s in searches if s['error'] or s['count']>=10000]
    valid=identity_match and not material_geometry_changes and not probe['truncated'] and not metadata['truncated'] and metadata['targetAndFrameMatch'] and not invalid_searches and root_ids=={s['root'] for s in searches}
    # Limit decisions to actual WebArea descendants; window chrome is not the
    # search's scope. Do not interpret absence from an unrelated root as hidden.
    def web_root(n):
        parent=n['id']
        while parent is not None:
            if by_id[parent]['role']=='AXWebArea': return parent
            parent=by_id[parent].get('parent')
    memberships={n['id']:{m['root']:m for m in n['searchMembership']} for n in observed}
    def visible(n):
        r=web_root(n)
        return None if r is None else memberships[n['id']][r]['visibleOnly']
    run=json.loads((root/'runs'/metadata['runId']/'result.json').read_text())
    viewport=run['screenshot']['frame']
    # Actual viewport may exclude titlebar. Source metadata candidates carry it.
    # Use observed AXWebArea bounds to restrict new tiny nodes to document area;
    # baseline already enforces its existing exact clip/selection regions.
    regions={n['id']:n.get('frame',viewport) for n in raw if n['role']=='AXWebArea'}
    region=next((c.get('selectionRegion') for c in baseline if c.get('selectionRegion')),None)
    static_ancestors=set()
    for n in raw:
        if n['role']=='AXStaticText' and n.get('value'):
            parent=n.get('parent')
            while parent is not None:
                static_ancestors.add(parent);parent=by_id[parent].get('parent')
    base_ids={c['node'] for c in baseline}
    removed=[];added=[];tiny=[]
    def info(n):
        f=n.get('frame');anc=[];parent=n.get('parent')
        while parent is not None:
            a=by_id[parent];anc.append({k:a.get(k) for k in ['id','role','title','frame']});parent=a.get('parent')
        return {'node':n['id'],'role':n['role'],'text':n.get('value') or n.get('title'), 'box':f,
                'offscreenSearchVisible':visible(n),'searchAllIncluded':memberships[n['id']].get(web_root(n),{}).get('all'),'oldReason':n.get('decisionReason'),
                'fullTextBounds':n.get('boundsForFullRange'),'rangeInvestigations':n.get('rangeInvestigations',[]),
                'ancestors':anc}
    if valid:
        for n in raw:
            if n['id'] in base_ids and visible(n) is False:removed.append(info(n))
            if n.get('decisionReason')=='text_extent_at_most_1pt':
                tiny.append({'node':n['id'],'visible':visible(n),'box':n.get('frame'),'text':n.get('value') or n.get('title')})
                f=n.get('frame');r=web_root(n)
                if visible(n) is not True or not f or not intersects(f,regions.get(r,viewport)) or (region and not intersects(f,region)):continue
                eligible=n['role']=='AXStaticText' and bool(n.get('value')) or n['role'] in {'AXButton','AXPopUpButton','AXRadioButton'} and bool(n.get('title')) and n['id'] not in static_ancestors
                if eligible:added.append(info(n))
    timings=[]
    for r in sorted(root_ids):
        samples=[b for b in probe.get('benchmarks',[]) if b['root']==r and not b['warmup']]
        old=[b['elapsedMs'] for b in samples if b['mode']=='tree' and b['finished'] and not b['error']]
        new=[b['elapsedMs'] for b in samples if b['mode']=='visible-search' and b['finished'] and not b['error']]
        if len(old)==6 and len(new)==6:
            timings.append({'root':r,'treeMs':median(old),'visibleSearchMs':median(new),'ratio':median(new)/median(old),'samplesPerMode':6})
    result={'scenario':run['scenarioId'],'folder':str(folder),'membershipSource':membership_source,'identityMatch':identity_match,'geometryChanges':geometry_changes,
            'ignoredNonDecisionGeometryChanges':ignored_geometry_changes,'aggregateValueChanges':aggregate_value_changes,'validComparison':valid,'searches':searches,'timings':timings,'removed':removed,'added':added,'tiny':tiny,
            'baselineCount':len(baseline),'hypothesisCount':len(baseline)-len(removed)+len(added) if valid else None,
            'baselineCollectionMs':metadata['elapsed']*1000,'baselineRangeMs':metadata.get('rangeElapsed',0)*1000,
            'replayStatus':run['status'],'limitations':['Selection comparison uses the full observed parent tree to preserve existing control-title deduplication.','Benchmark measures discovery plus five basic attributes, not complete product extraction.','No screenshot/AX atomicity guarantee; decision-relevant structural or geometry drift invalidates comparison. AXTextArea aggregate value, zero-area frames and textless childless decoration frame drift are recorded separately; they do not change node selection.']}
    (folder/'offscreen-comparison.json').write_text(json.dumps(result,ensure_ascii=False,indent=2))
    payload={'frame':viewport,'removed':removed,'added':added,'baseline':baseline}
    encoded=json.dumps(payload,ensure_ascii=False).replace('</','<\\/')
    table=''.join('<tr><td>'+('추가' if x['offscreenSearchVisible'] else '제외')+'</td><td>'+str(x['node'])+'</td><td>'+html.escape(x['text'])+'</td><td>'+html.escape(json.dumps(x['box']))+'</td><td><details><summary>AX 정보</summary><pre>'+html.escape(json.dumps(x,ensure_ascii=False,indent=2))+'</pre></details></td></tr>' for x in removed+added)
    page='''<!doctype html><html lang="ko"><meta charset="utf-8"><title>AXVisibleOnly 비교</title><style>body{font:14px system-ui;margin:24px}td,th{border:1px solid #aaa;padding:6px;max-width:600px;overflow-wrap:anywhere}table{border-collapse:collapse}.screen{position:relative;overflow:hidden}.screen img{width:100%;height:100%}.box{position:absolute;border:2px solid;box-sizing:border-box;background:transparent;cursor:pointer}.box span{background:#fffd;font:10px monospace}.removed{color:#c22}.added{color:#139334}.baseline{color:#2368b8}pre{white-space:pre-wrap}dialog{max-width:80vw;max-height:80vh;overflow:auto}button{margin:5px}</style><h1>SCENARIO</h1><p>연구용 비교. 빨강=기존 선택에서 제외될 노드 / 초록=1pt 조건 제거로 추가될 노드 / 파랑=기존 선택. 픽셀 판정 없이 AX 선택만 비교했습니다. 화면을 보고 실제 표시 여부를 검토해야 합니다.</p><p><a href="index.html">기존 문단·노드·라인 보고서</a> · <a href="offscreen.json">측정 원본</a> · <a href="offscreen-comparison.json">비교 JSON</a></p><pre>SUMMARY</pre><button onclick="draw('removed')">제외 차이</button><button onclick="draw('added')">추가 차이</button><button onclick="draw('baseline')">기존 선택</button><div class="screen" id="screen"><img src="screen.png"></div><dialog id="detail"><button onclick="this.parentElement.close()">닫기</button><pre></pre></dialog><h2>선택 차이</h2><table><tr><th>변경</th><th>노드</th><th>원문</th><th>박스</th><th>근거</th></tr>TABLE</table><script>const d=PAYLOAD,s=document.getElementById('screen');s.style.width=d.frame.width+'px';s.style.height=d.frame.height+'px';function draw(k){s.querySelectorAll('button').forEach(x=>x.remove());for(const n of d[k]){const f=n.box;if(!f)continue;const b=document.createElement('button');b.className='box '+k;b.style.cssText=`margin:0;left:${f.x-d.frame.x}px;top:${f.y-d.frame.y}px;width:${f.width}px;height:${f.height}px`;const t=document.createElement('span');t.textContent=n.node;b.append(t);b.onclick=()=>{const q=document.getElementById('detail');q.querySelector('pre').textContent=JSON.stringify(n,null,2);q.showModal()};s.append(b)}}draw('removed');</script></html>'''
    summary={k:result[k] for k in ['validComparison','identityMatch','geometryChanges','baselineCount','hypothesisCount','timings']}
    page=page.replace('SCENARIO',html.escape(run['scenarioId'])).replace('SUMMARY',html.escape(json.dumps(summary,ensure_ascii=False,indent=2))).replace('TABLE',table).replace('PAYLOAD',encoded)
    (folder/'offscreen.html').write_text(page)
    return result


def main():
    parser=argparse.ArgumentParser();parser.add_argument('batch',type=Path);parser.add_argument('--supplement',action='append',type=Path,default=[]);args=parser.parse_args()
    root=Path(__file__).resolve().parents[1];results=[]
    logs=[log for batch in [args.batch,*args.supplement] for log in sorted(batch.glob('*-collect.log'))]
    for log in logs:
        lines=log.read_text().strip().splitlines()
        if not lines:continue
        folder=Path(lines[0])
        if not (folder/'offscreen.json').exists():continue
        results.append(summarize(folder,root))
    results=list({r['scenario']:r for r in results}.values())
    attempts=[{'batch':str(batch),**r} for batch in [args.batch,*args.supplement] if (batch/'summary.json').exists() for r in json.loads((batch/'summary.json').read_text())['results']]
    requested=list(dict.fromkeys(r['scenario'] for r in attempts))
    output={'requestedScenarios':requested,'attempts':attempts,'unverifiedScenarios':[s for s in requested if not any(r['scenario']==s and r['validComparison'] for r in results)],'batches':[str(p) for p in [args.batch,*args.supplement]],'scenarios':len(results),'valid':sum(r['validComparison'] for r in results),'results':results}
    valid_results=[r for r in results if r['validComparison']]
    sums=[(sum(t['treeMs'] for t in r['timings']),sum(t['visibleSearchMs'] for t in r['timings'])) for r in valid_results if r['timings']]
    output['performance']={
        'scope':'WebArea discovery plus AXRole/AXValue/AXTitle/AXPosition/AXSize; warmup excluded, six alternating samples per mode. Not full product extraction.',
        'scenarios':len(sums),
        'medianTreeMs':median([a for a,b in sums]) if sums else None,
        'medianVisibleSearchMs':median([b for a,b in sums]) if sums else None,
        'medianRatio':median([b/a for a,b in sums]) if sums else None,
        'fasterScenarios':sum(b<a for a,b in sums),
        'slowerScenarios':sum(b>=a for a,b in sums),
        'queryOnlyTotalMedianMs':median([sum(q['elapsedMs'] for q in r['searches'] if q['visibleOnly']) for r in valid_results]) if valid_results else None,
        'queryOnlyTotalMaxMs':max([sum(q['elapsedMs'] for q in r['searches'] if q['visibleOnly']) for r in valid_results],default=None),
        'queryOnlyMs':[q['elapsedMs'] for r in valid_results for q in r['searches'] if q['visibleOnly']],
    }
    output['tinyComparison']={
        'total':sum(len(r['tiny']) for r in valid_results),
        'visibleSearchTrue':sum(n['visible'] is True for r in valid_results for n in r['tiny']),
        'visibleSearchFalse':sum(n['visible'] is False for r in valid_results for n in r['tiny']),
        'outsideWebArea':sum(n['visible'] is None for r in valid_results for n in r['tiny']),
        'eligibleAdditions':sum(len(r['added']) for r in valid_results),
    }
    (args.batch/'offscreen-summary.json').write_text(json.dumps(output,ensure_ascii=False,indent=2))
    links=[]
    metrics='<pre>'+html.escape(json.dumps({'requested':len(requested),'measured':len(results),'valid':output['valid'],'unverified':output['unverifiedScenarios'],'performance':{k:v for k,v in output['performance'].items() if k!='queryOnlyMs'},'tinyComparison':output['tinyComparison']},ensure_ascii=False,indent=2))+'</pre>'
    for r in results:
        href=Path(r['folder']).relative_to(root/'evaluations').as_posix()+'/offscreen.html'
        text=f"{r['scenario']} — 비교 {'유효' if r['validComparison'] else '불일치/보류'} / 제외 {len(r['removed'])} / 추가 {len(r['added'])}"
        links.append(f'<li><a href="../{html.escape(href)}">{html.escape(text)}</a></li>')
    missing=[s for s in requested if s not in {r['scenario'] for r in results}]
    for scenario in missing:
        last=next(r for r in reversed(attempts) if r['scenario']==scenario)
        links.append('<li>'+html.escape(scenario)+' — 미수집 / '+html.escape(last['detail'])+'</li>')
    findings='<p><a href="../../AX_VISIBLE_ONLY_REVIEW.md">검토 기록</a></p>'
    review_path=args.batch/'offscreen-review.html'
    if review_path.exists():findings+=review_path.read_text()
    (args.batch/'offscreen.html').write_text('<!doctype html><meta charset="utf-8"><h1>AXVisibleOnly 시나리오 비교</h1><p>탐색+기본 속성 5개 성능을 기존 트리 순회와 교대로 6회 측정(준비1회 별도). 제품 전체 성능·가시성 정답을 보증하지 않습니다. 개별 보고서에서 선택 차이와 캡처를 확인할 수 있습니다.</p>'+findings+'<ul>'+''.join(links)+'</ul>'+metrics)
    print(json.dumps({'scenarios':output['scenarios'],'valid':output['valid'],'removed':sum(len(r['removed']) for r in results),'added':sum(len(r['added']) for r in results)},ensure_ascii=False))

if __name__=='__main__':main()
