#!/usr/bin/env python3
"""Review native paragraph candidates in archived AX snapshots; never join source strings."""
import argparse
from collections import Counter
import html
import json
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--baseline', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    evaluations = root / 'evaluations'
    active = json.loads((root / 'ax-active-scenarios.json').read_text())['scenarios']
    previous = {row['scenario']: row for row in json.loads(args.baseline.read_text())['results']}
    totals = Counter()
    sections = []
    results = []
    for name in active:
        row = previous[name]
        assert row['status'] == 'ok', name
        folder = (evaluations / row['report']).parent
        raw = {node['id']: node for node in json.loads((folder / 'rawAx.json').read_text())}
        candidates = json.loads((folder / 'candidate.json').read_text())
        container_areas = set()
        for node in raw.values():
            if node['role'] != 'AXTextArea':
                continue
            parent = node.get('parent')
            while parent in raw:
                if raw[parent]['role'] == 'AXTextArea':
                    container_areas.add(parent)
                parent = raw[parent].get('parent')
        units = {}
        unresolved = []
        counts = Counter()
        for candidate in candidates:
            if candidate['textSource'] != 'AXValue':
                counts['control_title'] += 1
                continue
            node = raw[candidate['node']]
            parent = node.get('parent')
            path = []
            nearest = None
            while parent in raw:
                path.append({'id': parent, 'role': raw[parent]['role']})
                if raw[parent]['role'] == 'AXTextArea':
                    nearest = raw[parent]
                    break
                parent = raw[parent].get('parent')
            if nearest and nearest['id'] not in container_areas:
                counts['leaf_textarea_fragments'] += 1
                unit = units.setdefault(nearest['id'], {
                    'nativeNode': nearest['id'], 'role': nearest['role'], 'text': nearest['value'],
                    'frame': nearest.get('frame'), 'selectedFragments': [],
                })
                unit['selectedFragments'].append({'node': candidate['node'], 'text': candidate['text']})
            else:
                kind = 'container_textarea_only' if nearest else 'no_textarea'
                counts[kind] += 1
                unresolved.append({'node': candidate['node'], 'text': candidate['text'], 'kind': kind, 'path': path})
        counts['native_leaf_units'] = len(units)
        totals.update(counts)
        item = {'scenario': name, 'sourceReport': row['report'], 'counts': dict(counts), 'nativeLeafUnits': list(units.values()), 'unresolved': unresolved}
        results.append(item)
        link = '../' + row['report']
        unit_rows = ''.join('<tr><td>' + str(unit['nativeNode']) + '</td><td><pre>' + html.escape(unit['text']) + '</pre></td><td>' + ', '.join(str(fragment['node']) for fragment in unit['selectedFragments']) + '</td></tr>' for unit in units.values())
        other_rows = ''.join('<tr><td><a href="' + html.escape(link + '#node=' + str(node['node']), quote=True) + '">' + str(node['node']) + '</a></td><td>' + html.escape(node['text']) + '</td><td>' + html.escape(node['kind']) + '</td><td>' + html.escape(' → '.join(str(parent['id']) + ':' + parent['role'] for parent in node['path'][:5])) + '</td></tr>' for node in unresolved)
        sections.append('<p><a href="' + html.escape(link, quote=True) + '">' + html.escape(name) + ' 화면·노드 보고서</a></p><details><summary>' + html.escape(name) + ' — native 문단 후보 ' + str(len(units)) + '개 / 미분류 조각 ' + str(len(unresolved)) + '개</summary><h3>작은 AXTextArea가 직접 제공한 원문</h3><table><tr><th>원본 AX 부모 번호</th><th>AXValue 그대로</th><th>선택된 하위 노드</th></tr>' + unit_rows + '</table><h3>문단 단위 미분류</h3><table><tr><th>노드</th><th>원문</th><th>분류</th><th>상위 구조</th></tr>' + other_rows + '</table></details>')
    summary = {'source': 'archived successful AX captures from the active 43 scenarios', 'freshReplaySucceeded': False,
               'nativeParagraphAPIsMeasured': False, 'noSourceConcatenation': True, 'scenarios': len(results),
               'counts': dict(totals), 'results': results,
               'blockers': ['No valid Rearview Development signing identity', 'ntn has no auth token for current workspace', 'Direct native replay rich-r04: target_window_missing'],
               'candidatePolicy': 'Small leaf AXTextArea is a body-text candidate, not an adopted universal extraction rule'}
    args.output.mkdir(parents=True, exist_ok=True)
    (args.output / 'paragraph-analysis.json').write_text(json.dumps(summary, ensure_ascii=False, indent=2))
    page = '''<!doctype html><meta charset="utf-8"><title>Notion AX 문단 단위 조사</title>
<style>body{font:15px system-ui;line-height:1.65;margin:28px;max-width:1400px}details{border:1px solid #ccc;padding:12px;margin:12px 0}summary{cursor:pointer;font-weight:bold}table{border-collapse:collapse;width:100%}th,td{border:1px solid #ccc;padding:8px;text-align:left;vertical-align:top}pre{white-space:pre-wrap;margin:0}</style>
<h1>Notion AX 문단 단위 조사</h1>
<p><strong>기존 43개 시나리오의 성공한 AX 캡처를 분석한 결과다. 이번 새 재생은 환경 문제로 실패했으며 문단 marker API는 새로 실측하지 못했다.</strong></p>
<p>기본 테스트 범위는 ax-active-scenarios.json의 사용자 지정 43개다. 원문 문자열 결합이나 좌표 기반 문단 추정은 사용하지 않았다. 아래 원문은 기존 native AXTextArea의 AXValue 그대로다.</p>
<h2>현재 결론</h2><p>일반 본문·서식·목록은 가장 가까운 작은 AXTextArea가 이미 번역 문단 후보를 제공한다. 이모지와 서식 조각도 같은 native 부모를 참조할 수 있다. 그러나 AXTextArea라는 역할은 문서 전체 편집 영역에도 쓰인다. 자식 AXTextArea를 포함한 상위 편집 영역을 문단으로 채택하지 않았다. 자식 편집 영역이 없다는 조건도 보편적인 충분조건으로 검증된 것은 아니다.</p>
<p>DB 셀·카드·타임라인에서는 가까운 AXTextArea가 문서 전체이거나 아예 없는 경우가 있어 별도 native 범위 조사가 필요하다. 이 영역은 문서 전체로 확장하지 않고 미분류로 남겼다. 버튼 라벨 등 AXTitle 컨트롤은 문단 후보에서 구분했다.</p>
<h2>실측할 후보 API</h2><ul><li>AXTextMarkerRangeForUIElement(작은 AXTextArea): 기존 블록 전체 범위를 직접 제공하는지 확인.</li><li>AXParagraphTextMarkerRangeForTextMarker: 특정 위치의 문단 전체 범위를 반환하는지, 서식·이모지 경계를 넘어 하나로 잡히는지 확인.</li><li>AXNextParagraphEndTextMarkerForTextMarker: 현재 위치부터 문단 끝. 시작이 문단 중간이면 전체 문단 API와 다르므로 원문 단위로 바로 대체하지 않음.</li></ul>
<p>세 속성은 현재 SDK의 AXWebConstants.h에 선언돼 있다. 선언 존재는 Notion의 지원·경계 의미를 보증하지 않는다. 명시적 줄바꿈이 문단 API를 나누는지, DB 셀 밖으로 넘어가는지, 표·다단·토글·미리보기 경계를 보존하는지 실측해야 한다.</p>
<h2>실행 차단</h2><p>현재 서명 인증서가 없고 ntn 인증 토큰도 없다. 재패키징 시도, 기존 서명 앱 검증 후 43개 실행 시도 모두 로그를 남겼다. 기존 앱을 사용한 rich-r04 직접 재생도 target_window_missing으로 실패했다. 문서 무결성을 확인한 새 재생·수집 성공으로 집계하지 않는다. 기존 앱 UUID가 현재 빌드와 다르다는 한계도 남겼다.</p>
<h2>구조 관측 집계</h2><pre>''' + html.escape(json.dumps(dict(totals), ensure_ascii=False, indent=2)) + '''</pre><p>조각 수와 native 부모 후보 수는 서로 다른 집계다. 화면 간 중복 문단도 합산했다.</p>
<h2>시나리오별 원문 확인</h2>''' + ''.join(sections) + '<p><a href="paragraph-analysis.json">원본 분석 JSON</a> · <a href="rich-r04/result.json">직접 재생 실패 기록</a> · <a href="../batch-20261109T043808.336342Z/index.html">43개 새 실행 차단 기록</a></p>'
    (args.output / 'index.html').write_text(page)
    print(json.dumps({'scenarios': len(results), 'counts': dict(totals), 'report': str(args.output / 'index.html')}, ensure_ascii=False))


if __name__ == '__main__':
    main()
