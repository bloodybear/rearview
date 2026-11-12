#!/usr/bin/env python3
"""Summarize native paragraph probes without assembling source fragments."""
import argparse, collections, html, json
from pathlib import Path

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('batch', type=Path)
    parser.add_argument('--retry', type=Path, action='append', default=[])
    parser.add_argument('--output', type=Path)
    args=parser.parse_args()
    base=args.batch.parent
    batch=json.loads((args.batch/'summary.json').read_text())
    for retry in args.retry:
        retried={r['scenario']:r for r in json.loads((retry/'summary.json').read_text())['results']}
        batch['results']=[retried.get(r['scenario'],r) if r['status']!='ok' else r for r in batch['results']]
    output=args.output or args.batch
    output.mkdir(parents=True,exist_ok=True)
    counts=collections.Counter(); rows=[]; sections=[]
    for row in batch['results']:
        item={'scenario':row['scenario'],'status':row['status'],'detail':row.get('detail','')}
        records=[]
        if row.get('paragraphProbe'):
            probe=json.loads((base/row['paragraphProbe']).read_text())
            item['probe']=row['paragraphProbe']
            item['truncated']=probe['truncated']
            for node in probe['results']:
                counts['probedFragments']+=1
                ancestor=probe['ancestors'].get(str(node.get('nearestTextArea')),{})
                paragraph=node.get('paragraphAPI',{})
                end=node.get('nextParagraphEndAPI',{})
                text=paragraph.get('text')
                if text is not None:
                    counts['paragraphStringSuccess']+=1
                    relation='same_as_fragment' if text==node['text'] else ('contains_fragment' if node['text'] in text else 'different')
                    counts[relation]+=1
                else:
                    relation='unavailable'; counts['paragraphUnavailable']+=1
                if ancestor and not ancestor.get('containsNestedTextAreas'):
                    counts['leafTextAreaFragments']+=1
                    if text==ancestor.get('text'): counts['paragraphEqualsLeafTextArea']+=1
                record={'fragment':node['text'],'paragraph':text,'relation':relation,'paragraphError':paragraph.get('rangeError'),'stringError':paragraph.get('stringError'),'nearestTextArea':ancestor,'nextParagraphEnd':end,'probeNode':node['probeNode'],'nearbyStructure':node.get('nearbyStructure',[])}
                records.append(record)
            item['records']=records
            item['observedNativeLeafUnits']=len({r['nearestTextArea'].get('probeNode') for r in records if r['nearestTextArea'] and not r['nearestTextArea'].get('containsNestedTextAreas')})
            counts['nativeLeafUnits']+=item['observedNativeLeafUnits']
            units={r['nearestTextArea']['probeNode']:r['nearestTextArea'] for r in records if r['nearestTextArea'] and not r['nearestTextArea'].get('containsNestedTextAreas')}
            counts['leafElementRangeEqualsValue']+=sum(a.get('elementMarkerRange',{}).get('text')==a['text'] for a in units.values())
            counts['leafUnitsWithNewlines']+=sum('\n' in a['text'] for a in units.values())
            counts['nearestContainerFragments']+=sum(bool(r['nearestTextArea'].get('containsNestedTextAreas')) for r in records)
            counts['noTextAreaFragments']+=sum(not r['nearestTextArea'] for r in records)
        rows.append(item)
        table=''.join('<tr><td><pre>'+html.escape(r['fragment'])+'</pre></td><td><pre>'+html.escape(r['paragraph'] if r['paragraph'] is not None else str(r['paragraphError']))+'</pre></td><td>'+html.escape(r['relation'])+'</td><td><pre>'+html.escape(r['nearestTextArea'].get('text',''))+'</pre></td></tr>' for r in records)
        link='../'+row['report'] if row.get('report') else ''
        report_link=('<p><a href="'+html.escape(link,quote=True)+'">'+html.escape(row['scenario'])+' 화면·선택 박스 보고서</a></p>') if link else ''
        sections.append(report_link+'<details><summary>'+html.escape(row['scenario'])+' / '+row['status']+' / '+str(len(records))+'</summary><p>'+html.escape(item['detail'])+'</p><table><tr><th>하위 조각 AXValue</th><th>문단 API 반환 원문</th><th>문자열 관계</th><th>가장 가까운 AXTextArea 원문</th></tr>'+table+'</table></details>')
    result={'batch':str(args.batch),'retries':[str(p) for p in args.retry],'succeeded':sum(r['status']=='ok' for r in rows),'selected':len(rows),'counts':dict(counts),'results':rows,'warning':'Native observations only; substring membership is diagnostic, not paragraph correctness or extraction policy.'}
    (output/'paragraph-summary.json').write_text(json.dumps(result,ensure_ascii=False,indent=2))
    (output/'paragraphs.html').write_text('<!doctype html><meta charset="utf-8"><title>AX 문단 단위 실측</title><style>body{font:15px system-ui;margin:24px;line-height:1.6}details{border:1px solid #ccc;padding:12px;margin:10px 0}table{border-collapse:collapse;width:100%}td,th{border:1px solid #ccc;padding:8px;vertical-align:top}pre{white-space:pre-wrap;overflow-wrap:anywhere}</style><h1>AX 문단 단위 실측</h1><p>성공 '+str(result['succeeded'])+' / 대상 '+str(len(rows))+'</p><p>Notion이 직접 제공한 범위를 비교했습니다. 원문을 조합하지 않았습니다. 문자열 포함 여부만으로 문단 경계의 정확성을 판정하지 않습니다. 조사용 노드 번호와 화면 보고서 번호는 별도입니다. 조사는 선택 원문과 같은 문자열을 가진 화면 내 노드를 대상으로 하므로 동일 문자열의 다른 노드가 포함될 수 있습니다. 컨트롤 AXTitle은 이 문단 조사 대상에서 제외했습니다.</p><pre>'+html.escape(json.dumps(dict(counts),indent=2))+'</pre>'+''.join(sections))
    report=output/'paragraphs.html'
    note='<h2>실측 해석</h2><p>본문·서식·일반 표 셀은 작은 AXTextArea의 AXValue가 번역 단위 후보입니다. 서식과 이모지 조각을 연결하지 않아도 부모가 원문 전체를 제공했습니다. 아직 최종 수집 규칙으로 채택하지 않았습니다.</p><p>문단 API는 서식 조각만 반환하거나 명시적 줄바꿈에서 끊겼습니다. 문단 끝 API는 문단 중간부터 시작하면 앞 원문이 빠지고, bounds가 문서 전체 크기로 반환되기도 했습니다. DB의 큰 편집 영역을 문단으로 채택하지 않습니다. 작은 AXTextArea라도 페이지 링크의 객체 문자가 섞인 경우는 따로 검토해야 합니다.</p><p>타임라인 오른쪽은 두 차례 스크롤 재생 실패로 미수집입니다. 성공 수는 절차 완료 수이며 문단 정확도가 아닙니다. 수집·캡처·probe는 동시 원자적 실행이 아닙니다. 성능 향상은 아직 측정하지 않았습니다.</p><p><a href="../../AX_PARAGRAPH_UNITS_FINDING.md">조사 결정·한계 기록</a> · <a href="paragraph-summary.json">전체 분석 JSON</a></p>'
    report.write_text(report.read_text().replace('<h1>AX 문단 단위 실측</h1>','<h1>AX 문단 단위 실측</h1>'+note))
    print(json.dumps(dict(counts)))
if __name__=='__main__':main()
