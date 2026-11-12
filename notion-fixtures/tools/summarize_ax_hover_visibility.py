#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Evaluate AX-only hit-test convergence against recorded study states."""
import argparse
import html
import json
from pathlib import Path


def classify_point(attempts):
    # Chromium may answer the first call from stale cache/geometric approximation.
    # Unstable, missing or failed responses never count as an exclusion signal.
    usable = attempts[1:]
    if len(usable) < 3 or any(a['error'] != 0 for a in usable[-3:]):
        return 'unknown'
    tail = {a['targetInPath'] for a in usable[-3:]}
    if len(tail) != 1:
        return 'unknown'
    return 'hit_available' if tail.pop() else 'hit_unavailable'


def classify_control(control):
    points = [classify_point(p['attempts']) for p in control.get('hitGrid', [])]
    if 'hit_available' in points:
        return 'hit_available'
    if points and all(p == 'hit_unavailable' for p in points):
        return 'hit_unavailable'
    return 'unknown'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('folder', type=Path)
    args = parser.parse_args()
    # Labels identify the requested study subjects only; classification above
    # never inspects names, roles, DOM classes, screenshots or pixel colors.
    targets = ['1 backlink', 'Add icon', 'Add cover', 'Add comment']
    phases = ['hidden-grid', 'visible-grid', 'hidden2-grid', 'visible2-grid',
              'hidden3-grid', 'db-hidden', 'db-visible']
    rows, raw_count, initial_mismatches, point_count = [], 0, 0, 0
    for phase in phases:
        snapshot = json.loads((args.folder/(phase+'.json')).read_text())
        assert not snapshot['truncated'] and snapshot['windowFrameUnchanged']
        expected = 'hit_available' if 'visible' in phase else 'hit_unavailable'
        for title in targets:
            control = next(c for c in snapshot['controls'] if c['title'] == title)
            decision = classify_control(control)
            assert decision == expected, (phase, title, decision)
            for point in control['hitGrid']:
                assert classify_point(point['attempts']) == expected
                point_count += 1
                raw_count += len(point['attempts'])
                initial_mismatches += sum(a['targetInPath'] != (expected == 'hit_available')
                                          for a in point['attempts'])
            rows.append({'phase': phase, 'title': title, 'decision': decision,
                         'points': len(control['hitGrid'])})
    normal_rows = []
    for phase in ['db-hidden', 'db-visible']:
        snapshot = json.loads((args.folder/(phase+'.json')).read_text())
        for control in snapshot['controls']:
            if control['title'] in {'Not started', 'In progress', 'Done', '高', '中', '低'} and control.get('hitGrid'):
                decision = classify_control(control)
                assert decision == 'hit_available', (phase, control['title'], control['frame'])
                normal_rows.append({'phase': phase, 'text': control['title'],
                                    'frame': control['frame'], 'decision': decision})
    result = {'targetStates': len(rows), 'coordinateStates': point_count,
              'rawReplies': raw_count, 'rawStaleReplies': initial_mismatches,
              'allSettledTargetStatesCorrect': True, 'normalDBLabelChecks': len(normal_rows),
              'method': 'AX hit-test, ignore first reply, require final 3 replies to agree',
              'pixelInputUsed': False, 'rows': rows, 'normalDBLabels': normal_rows}
    (args.folder/'settled-summary.json').write_text(json.dumps(result, ensure_ascii=False, indent=2))
    table = ''.join('<tr><td>'+html.escape(r['phase'])+'</td><td>'+html.escape(r['title'])+
                    '</td><td>'+r['decision']+'</td><td>'+str(r['points'])+'</td><td><a href="'+
                    r['phase']+'.json">AX 원본</a></td></tr>' for r in rows)
    page = '''<!doctype html><html lang="ko"><meta charset="utf-8"><title>AX 반복 hit-test 조사</title>
<style>body{font:16px system-ui;margin:28px;line-height:1.65;max-width:1250px}table{border-collapse:collapse}td,th{border:1px solid #ccc;padding:7px;text-align:left}img{max-width:48%;margin:5px}pre{white-space:pre-wrap}</style>
<h1>AX만으로 네 호버 버튼을 구분하는 방법</h1>
<p><strong>첫 응답을 버리고, 동일 좌표의 AX hit-test를 재조회하여 연속 응답이 일치하는지 확인합니다.</strong> 반환된 요소 또는 그 상위 경로가 대상 컨트롤을 포함하는지 AX 객체 동일성으로 비교합니다. 이름별 제외·픽셀·OCR·DOM 접근은 판정에 사용하지 않습니다.</p>
<p>Chromium은 동기 AX 요청에 먼저 캐시 또는 좌표 추정값을 돌려주고 렌더러 hit-test를 비동기로 갱신합니다. 따라서 최초 응답을 가시성 판정으로 사용하면 안 됩니다. 이번 연구는 40ms 간격·지점당 6회로 수집하고 최초 1회를 버린 뒤 마지막 3회 일치를 검사했습니다. 여러 지점 중 한 곳이라도 안정적으로 대상에 도달하면 hit_available, 모든 지점이 안정적으로 다른 대상으로 귀결되면 hit_unavailable, 나머지는 unknown입니다.</p>
<p>시각적 표시 여부의 모든 일반 사례를 보증하는 API는 아닙니다. hit_unavailable은 접근성 hit-test에서 도달하지 못했다는 뜻이며, 다른 UI의 가림·hit-test 미지원·응답 지연 등과 구분해야 합니다. 첫 응답만으로 제외하지 않고 오류·불안정은 unknown으로 남깁니다. 제품 제외 규칙에는 아직 적용하지 않았습니다.</p>
<p>이미지는 실험 상태 확인용입니다. 판정 함수는 AX JSON의 응답만 읽습니다. 캡처와 AX는 동시 원자적 실행이 아니므로 조회 전후 상태 확인과 반복 전환을 함께 기록했습니다. 실제 하드웨어 포인터 좌표는 CUA가 합성한 포인터 상태와 같다고 가정하지 않습니다.</p>
<h2>실측 집계</h2><pre>__COUNTS__</pre>
<h2>방법의 비용과 적용 범위</h2><p>연구 설정은 지점당 최대 200ms의 관찰 구간이며 코드의 마지막 대기까지 포함하면 240ms입니다. 5지점 검사는 정확성 연구용입니다. 매 프레임 모든 노드에 그대로 적용하면 성능 목표에 부합하지 않습니다. 제품 적용 전 비동기 실행·판정 보류·캐시 갱신 조건과 대기 최소화를 검증해야 합니다. 비슷한 숨김 구현의 모든 컨트롤로 일반화하거나 추출기 전체 완료로 취급하지 않습니다.</p>
<h2>원본 자료</h2><table><tr><th>상태</th><th>대상</th><th>AX 판정</th><th>검사 지점</th><th>자료</th></tr>__ROWS__</table>
<h2>호버 상태 관찰</h2><p>rich-document: 숨김 → 표시 → 재숨김 → 표시 → 재숨김. project-database: 숨김 → 표시. 클릭/메뉴의 키보드 포커스 유지와 실제 포인터 호버를 구분했습니다. 첫 세 속성 비교 표본은 클릭·포커스 영향도 있었고, grid 표본은 미세 포인터 이동으로 실제 표시 상태를 만들었습니다.</p>
<details><summary>rich-document 표시·재숨김 화면</summary><img src="visible-grid-before.png"><img src="hidden2-grid-before.png"></details>
<details><summary>원래 DB 표시·숨김 화면</summary><img src="db-visible-before.png"><img src="db-hidden-before.png"></details>
<p><a href="settled-summary.json">집계 JSON</a> · <a href="../../AX_HOVER_VISIBILITY_FINDING.md">근거·한계·이전 결론 정정</a></p>
<p>소스 근거: <a href="https://chromium.googlesource.com/chromium/src/+/HEAD/ui/accessibility/platform/browser_accessibility_manager.cc">CachingAsyncHitTest</a>, <a href="https://chromium.googlesource.com/chromium/src/+/HEAD/ui/accessibility/platform/browser_accessibility_cocoa.mm">macOS AX 브리지</a>.</p></html>'''
    counts = {k:v for k,v in result.items() if k not in {'rows', 'normalDBLabels'}}
    page = page.replace('__COUNTS__', html.escape(json.dumps(counts, ensure_ascii=False, indent=2))).replace('__ROWS__', table)
    (args.folder/'index.html').write_text(page)
    print(json.dumps(counts, ensure_ascii=False))


if __name__ == '__main__':
    main()
