#!/usr/bin/env python3
"""Audit markers-local batch artifacts and create a review entry point."""
import argparse
from collections import Counter
from datetime import datetime, timezone
import html
import json
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).parent))
from run_ax_prototype import validate_collection


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('batches', nargs='+', type=Path)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    evaluations = root / 'evaluations'
    output = evaluations / ('markers-local-' + datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ'))
    output.mkdir()
    results = []
    for batch in args.batches:
        batch = batch.resolve()
        for row in json.loads((batch / 'summary.json').read_text())['results']:
            row = dict(row)
            row['batch'] = str(batch.relative_to(evaluations))
            results.append(row)
    latest = {row['scenario']: row for row in results}
    expected = {path.stem for path in (root / 'scenarios').glob('*/*.json')}
    missing = sorted(expected - latest.keys())
    statuses = Counter()
    incomplete = []
    explicit = []
    total_lines = 0
    total_nodes = 0
    for row in latest.values():
        if row['status'] != 'ok':
            continue
        folder = (evaluations / row['report']).parent
        metadata = json.loads((folder / 'metadata.json').read_text())
        assert metadata['lineMethod'] == 'markers-local'
        assert metadata['activation'] == 'manual'
        assert metadata['targetAndFrameMatch'] and not metadata['truncated']
        candidates = json.loads((folder / 'candidate.json').read_text())
        raw = json.loads((folder / 'rawAx.json').read_text())
        validate_collection(folder, candidates)
        total_nodes += len(candidates)
        for node in raw:
            for probe in node.get('rangeInvestigations', []):
                assert probe['lineMethod'] == 'markers-local'
                assert all(event['attribute'] in {'AXTextMarkerRangeForUIElement', 'AXNextLineEndTextMarkerForTextMarker', 'AXStringForTextMarkerRange', 'AXBoundsForTextMarkerRange'} for event in probe['trace'])
        for candidate in candidates:
            status = candidate.get('lineRangeStatus', 'control_frame_only')
            statuses[status] += 1
            lines = candidate.get('lineRanges', [])
            total_lines += len(lines)
            record = {'scenario': row['scenario'], 'node': candidate['node'], 'text': candidate['text'], 'status': status, 'lines': len(lines), 'report': row['report'] + '#node=' + str(candidate['node'])}
            if status not in ('complete_unverified', 'control_frame_only'):
                incomplete.append(record)
            if '\n' in candidate['text']:
                explicit.append(record)
        # Make the selected line method visible in each newly generated report too.
        page = folder / 'index.html'
        page.write_text(page.read_text().replace('범위 API 기반 라인(픽셀 가시성 미검증)', 'markers-local 라인(픽셀 가시성 미검증)'))
    summary = {'lineMethod': 'markers-local', 'activation': 'manual', 'characterFallback': False,
               'scenarios': len(latest), 'definedScenarios': len(expected), 'unattemptedScenarios': missing, 'succeeded': sum(row['status'] == 'ok' for row in latest.values()),
               'emptySelectionScenarios': [row['scenario'] for row in latest.values() if row['status'] == 'ok' and row.get('candidateCount') == 0], 'selectedNodes': total_nodes, 'lineBoxes': total_lines, 'rangeStatuses': dict(statuses),
               'incompleteNodes': incomplete, 'explicitNewlineNodes': explicit,
               'results': list(latest.values()), 'attempts': results, 'artifactAudit': 'passed'}
    (output / 'summary.json').write_text(json.dumps(summary, ensure_ascii=False, indent=2))
    def link(ref, label):
        return '<a href="../' + html.escape(ref, quote=True) + '">' + html.escape(label) + '</a>'
    rows = ''.join('<tr><td>' + link(row.get('report', row['batch'] + '/' + row['scenario'] + '-replay.log'), row['scenario']) + '</td><td>' + html.escape(row['status']) + '</td><td>' + html.escape(row['detail']) + '</td></tr>' for row in latest.values())
    def entries(items):
        return ''.join('<li>' + link(item['report'], item['scenario'] + ' / node=' + str(item['node'])) + ' — ' + html.escape(item['status']) + ' / ' + str(item['lines']) + '줄 <pre>' + html.escape(item['text']) + '</pre></li>' for item in items)
    page = f'''<!doctype html><meta charset="utf-8"><title>markers-local 전체 시나리오 검증</title>
<style>body{{font:15px system-ui;margin:32px;line-height:1.6}}table{{border-collapse:collapse;width:100%}}td,th{{border:1px solid #ccc;padding:8px;text-align:left}}pre{{white-space:pre-wrap}}a{{color:#1259ae}}</style>
<h1>markers-local 전체 시나리오 검증</h1>
<p>정의 {len(expected)}개 · 실행한 시나리오 {len(latest)}개 · 재시도 포함 총 {len(results)}회 · 미실행 {len(missing)}개. 재시도 항목은 마지막 결과를 표시합니다.</p>
<p>재생·수집 성공 {summary['succeeded']}/{summary['scenarios']}개 · 선택 노드 {total_nodes}개 · 라인 박스 {total_lines}개.</p>
<p>AXManualAccessibility 활성화 후 AXStaticText의 marker 경계로 라인을 조회합니다. 범위 구성은 로컬 AXTextMarkerRangeCreate를 사용합니다. 문자별 조회·부모 TextArea fallback은 없습니다.</p>
<p>성공은 시나리오 재생과 파일·좌표·UTF-16 대응 검사를 통과했다는 뜻입니다. complete_unverified는 전체 원문 범위 대응을 뜻하며 픽셀 가시성이나 모든 줄 경계의 정확성을 보증하지 않습니다. 잘린 노드의 전체 원문은 유지하며 화면 밖 라인 박스는 표시에서 제외합니다. 라인 불완전 시 기존 노드 박스를 유지합니다.</p>
<p>개별 보고서에서 ‘노드 / 라인 박스 전환’을 누르면 파란 라인 박스를 확인할 수 있습니다.</p>
<p>선택 노드가 0개인 실행(별도 검토 필요): {html.escape(", ".join(summary["emptySelectionScenarios"]) or "없음")}.</p>
<h2>관측된 한계</h2><p>서식·이모지로 나뉜 짧은 노드에서는 다음 줄 끝 marker가 이웃 노드까지 넘어가 원문 검증에서 거부된 사례가 있습니다. 일부 DB 말줄임 셀은 범위 문자열 조회 오류를 반환합니다. 이는 일반 문단 검증만으로 전체 노드 형태를 보장할 수 없음을 보여줍니다. 이번 실행에서는 문자별 fallback을 추가하지 않고 원본 trace와 미확정 상태를 보존했습니다.</p>
<h2>조회 상태</h2><pre>{html.escape(json.dumps(dict(statuses), ensure_ascii=False, indent=2))}</pre>
<details><summary>라인 미완성·조회 불가 ({len(incomplete)}개) — 펼쳐서 노드 확인</summary><ul>{entries(incomplete)}</ul></details>
<details><summary>명시적 줄바꿈 검토 대상 ({len(explicit)}개) — 펼쳐서 노드 확인</summary><ul>{entries(explicit)}</ul></details>
<h2>전체 실행 결과</h2><table><tr><th>시나리오</th><th>실행</th><th>결과</th></tr>{rows}</table>
<p>{link(output.name + '/summary.json', '원본 요약 JSON')}</p>'''
    (output / 'index.html').write_text(page)
    (evaluations / 'index.html').write_text('<meta charset="utf-8"><a href="' + output.name + '/index.html">markers-local 전체 시나리오 검증 보고서</a>')
    print(output)


if __name__ == '__main__':
    main()
