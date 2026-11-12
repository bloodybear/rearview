"""Render direction comparisons with the existing fixed node/paragraph/line template."""
import json, html, shutil, statistics
from pathlib import Path
from render_ax_report import render
root=Path(__file__).resolve().parents[1]
out=root/'evaluations/direction-study-20261112'
summary=json.loads((out/'summary.json').read_text())
all_counts={k:dict(complete=0,lines=0,calls=0,medianSumMs=0) for k in ('forward','reverse','hybrid')}
issues=[];scenarios=[];rows_html=[];currentComplete=0;actualRecovered=0;actualRegressed=0;shortcuts=0
def signature(lines):
    return [(l['start'],l['length'],l['text'],l['box']) for l in lines]
def baseline_signature(lines):
    return [(l['rangeStart'],l['rangeLength'],l['text'],l['box']) for l in lines]
for case in summary:
    if case.get('probeStatus')!='ok':
        issues.append(dict(scenario=case['scenario'],error='probe not successful'));continue
    folder=Path(case['probe']).parent
    study=json.loads(Path(case['probe']).read_text())
    assert not study['timedOut']
    raw=json.loads((folder/'rawAx.json').read_text())
    counts={k:dict(complete=0,lines=0,calls=0,medianSumMs=0) for k in all_counts}
    units=[u for u in study['units'] if 'methods' in u]
    unmatched=[u for u in study['units'] if 'methods' not in u]
    diffs=[];regress=[];recovered=[];equalCoverage=[]
    for u in units:
        f,r,h=(u['methods'][k] for k in all_counts)
        prior=raw[u['node']]['paragraphLineInvestigation'];wasComplete=prior.get('lineRangeStatus')=='complete_unverified'
        currentComplete+=wasComplete;actualRecovered+=not wasComplete and r['status']=='complete';actualRegressed+=wasComplete and r['status']!='complete';shortcuts+=prior.get('lineMethod')=='sidebar-title-full-range'
        baselineMode='reverse' if 'reverse' in u['baseline'].get('lineMethod','') else 'forward'
        assert baseline_signature(u['baseline'].get('lineRanges',[]))==signature(u['methods'][baselineMode]['lines']),('baseline differs',case['scenario'],u['node'],baselineMode)
        for mode in all_counts:
            v=u['methods'][mode]
            encoded=u['text'].encode('utf-16-le');last=0
            for l in v['lines']:
                a,b=l['start'],l['start']+l['length'];assert a>=last and b>a and encoded[a*2:b*2].decode('utf-16-le')==l['text'];last=b
                assert l['box']['width']>0 and l['box']['height']>0
            if v['status']=='complete':assert v['covered']==len(encoded)//2
            counts[mode]['complete']+=v['status']=='complete'
            counts[mode]['lines']+=len(v['lines']);counts[mode]['calls']+=v['calls'];counts[mode]['medianSumMs']+=v['medianMs']
        if f['status']=='complete' and r['status']!='complete':regress.append(u['node'])
        if f['status']!='complete' and r['status']=='complete':recovered.append(u['node'])
        if f['status']==r['status']=='complete':
            equalCoverage.append(u)
            if signature(f['lines'])!=signature(r['lines']):
                # Preserve raw strings/ranges. Only classify the comparison.
                geomEqual=[l['box'] for l in f['lines']]==[l['box'] for l in r['lines']]
                textEqual=[l['text'].strip('\r\n') for l in f['lines']]==[l['text'].strip('\r\n') for l in r['lines']]
                diffs.append(dict(node=u['node'],sameGeometry=geomEqual,newlineOwnershipOnly=geomEqual and textEqual))
        if f['status']!='complete' and r['status']!='complete':issues.append(dict(scenario=case['scenario'],node=u['node'],text=u['text'],forward=f['status'],reverse=r['status']))
    for mode in all_counts:
        for key in all_counts[mode]:all_counts[mode][key]+=counts[mode][key]
    links=[]
    for mode in all_counts:
        dest=out/case['scenario']/mode;dest.mkdir(parents=True,exist_ok=True)
        for name in ('candidate.json','metadata.json','screen.png'):
            if (folder/name).exists():shutil.copy2(folder/name,dest/name)
        source=json.loads(json.dumps(raw))
        for u in units:
            v=u['methods'][mode]
            p=dict(lineMethod='research-'+mode,lineSourceText=u['text'],sourceNodes=u['sourceNodes'],lineRangeStatus='complete_unverified' if v['status']=='complete' else v['status'],coveredUTF16Length=v['covered'],totalUTF16Length=len(u['text'].encode('utf-16-le'))//2,
                lineRanges=[dict(rangeStart=l['start'],rangeLength=l['length'],text=l['text'],box=l['box'],boxKind='native_direction_research',line=i) for i,l in enumerate(v['lines'])])
            source[u['node']]['paragraphLineInvestigation']=p
        (dest/'rawAx.json').write_text(json.dumps(source,ensure_ascii=False,indent=2))
        meta=json.loads((dest/'metadata.json').read_text());meta['researchOnlyDirection']=mode;meta['sourceEvaluation']=str(folder.relative_to(root));(dest/'metadata.json').write_text(json.dumps(meta,ensure_ascii=False,indent=2))
        render(dest)
        links.append('<a href="'+str(dest.relative_to(out))+'/index.html">'+mode+'</a>')
    entry=dict(scenario=case['scenario'],units=len(units),unmatched=unmatched,counts=counts,reverseRegressions=regress,reverseRecoveries=recovered,differencesWhenBothComplete=diffs,equalCoverageUnits=len(equalCoverage),equalCoverageTimingMs={m:sum(u['methods'][m]['medianMs'] for u in equalCoverage) for m in all_counts},equalCoverageCalls={m:sum(u['methods'][m]['calls'] for u in equalCoverage) for m in all_counts})
    scenarios.append(entry)
    rows_html.append('<tr><td>'+html.escape(case['scenario'])+'</td><td>'+str(len(units))+'</td>'+''.join('<td>'+str(counts[m]['complete'])+' / '+str(counts[m]['lines'])+' / '+str(counts[m]['calls'])+' / '+format(counts[m]['medianSumMs'],'.3f')+'</td>' for m in all_counts)+'<td>'+' · '.join(links)+'</td></tr>')
audit=dict(scenarios=scenarios,totals=all_counts,currentExtractorComplete=currentComplete,actualRecovered=actualRecovered,actualRegressed=actualRegressed,existingSidebarShortcutUnits=shortcuts,remainingIssues=issues,notes=['Timings sum warm per-unit medians, not pipeline elapsed.','Whole marker cached within each strategy, including hybrid retries.','Fixed standard report template; research outputs only, default extractor unchanged.'])
(out/'audit.json').write_text(json.dumps(audit,ensure_ascii=False,indent=2))
page='<meta charset="utf-8"><title>AX line direction comparison</title><style>body{font:15px system-ui;margin:28px}td,th{border:1px solid #aaa;padding:8px}table{border-collapse:collapse}</style><h1>라인 수집 방향 비교 · 연구용</h1><p>각 열: 완주 단위 / 라인 수 / AX 호출 수 / 노드별 중앙값 합(ms). 결과량이 다르므로 총시간만으로 속도 우위를 판정하지 않습니다. 보고서는 기존 고정 양식을 사용합니다.</p><table><tr><th>시나리오</th><th>단위</th><th>정방향</th><th>역방향</th><th>실패 시 역방향</th><th>보고서</th></tr>'+''.join(rows_html)+'</table><h2>세부 비교</h2><details><summary>호출·동일 완주 집합·남은 실패</summary><pre>'+html.escape(json.dumps(audit,ensure_ascii=False,indent=2))+'</pre></details>'
(out/'index.html').write_text(page)
print(json.dumps(audit,ensure_ascii=False)[:1500]);print(out/'index.html')
