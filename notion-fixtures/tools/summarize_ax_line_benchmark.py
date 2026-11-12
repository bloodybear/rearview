#!/usr/bin/env python3
"""Audit and summarize live shared-handle AX line benchmarks; keep standard report links."""
import argparse
import html
import json
import statistics
from collections import Counter
from pathlib import Path

METHODS = ['old', 'native', 'native-single-fastpath']
LABELS = {'old': '기존 markers-local', 'native': '새 경로 일괄', 'native-single-fastpath': '새 경로 + 단일 노드 기존 경로'}


def percentile(values, fraction):
    values = sorted(values)
    index = (len(values) - 1) * fraction
    lower = int(index)
    return values[lower] + (values[min(lower + 1, len(values) - 1)] - values[lower]) * (index - lower)


def summarize(folder):
    manifest = json.loads((folder / 'manifest.json').read_text())
    assert manifest['cases'] and not manifest['failures'], 'Incomplete scenario execution'
    all_samples, all_outcomes, scenarios = [], [], []
    for case in manifest['cases']:
        data = json.loads((folder / case['benchmark']).read_text())
        assert data['validLiveState'] and all(s['stable'] for s in data['samples']), 'Changed live state/output'
        assert data['rounds'] == 18
        report = (folder / case['report']).resolve()
        raw = {n['id']: n for n in json.loads((report.parent / 'rawAx.json').read_text())}
        children = {}
        for n in raw.values():
            children.setdefault(n.get('parent'), []).append(n['id'])

        def leaf_text(node):
            if raw[node]['role'] == 'AXStaticText':
                return raw[node].get('value', '')
            return ''.join(leaf_text(c) for c in children.get(node, []))

        by_unit = {}
        for outcome in data['outcomes']:
            canonical = leaf_text(outcome['paragraph'])
            encoded = canonical.encode('utf-16-le')
            previous_end = 0
            for line in outcome['result']['lines']:
                start, length = line['start'], line['length']
                assert start >= previous_end and length > 0
                assert encoded[start * 2:(start + length) * 2].decode('utf-16-le') == line['text']
                previous_end = start + length
            if outcome['result']['status'] == 'complete':
                assert ''.join(l['text'] for l in outcome['result']['lines']) == canonical
            outcome['scenario'] = case['scenario']
            by_unit.setdefault(outcome['paragraph'], {})[outcome['method']] = outcome
        assert len(data['samples']) == len(by_unit) * len(METHODS) * data['rounds']
        assert all(sum(s['paragraph'] == unit and s['method'] == method and s['round'] == r for s in data['samples']) == 1
                   for unit in by_unit for method in METHODS for r in range(data['rounds']))
        for methods in by_unit.values():
            assert set(methods) == set(METHODS)
            if methods['old']['leafCount'] == 1:
                assert methods['old']['result'] == methods['native-single-fastpath']['result']
        for sample in data['samples']:
            sample['scenario'] = case['scenario']
        all_samples.extend(data['samples'])
        all_outcomes.extend(data['outcomes'])
        scenarios.append({'scenario': case['scenario'], 'report': case['report'], 'skipped': data['skipped']})

    def group_stats(samples, outcomes):
        results = {}
        for method in METHODS:
            selected = [s for s in samples if s['method'] == method]
            totals = [sum(s['ns'] for s in selected if s['round'] == r) / 1e6 for r in range(18)]
            calls = [sum(s['calls'] for s in selected if s['round'] == r) for r in range(18)]
            quality = [o for o in outcomes if o['method'] == method]
            assert len(set(calls)) == 1
            results[method] = {'medianMs': statistics.median(totals), 'p10Ms': percentile(totals, .1),
                               'p90Ms': percentile(totals, .9), 'calls': calls[0], 'units': len(quality),
                               'complete': sum(o['result']['status'] == 'complete' for o in quality),
                               'statuses': dict(Counter(o['result']['status'] for o in quality)), 'roundMs': totals}
        return results

    overall = {}
    for group in ['all', 'single', 'multi']:
        def keep(x):
            return group == 'all' or (x['leafCount'] == 1) == (group == 'single')
        overall[group] = group_stats([s for s in all_samples if keep(s)], [o for o in all_outcomes if keep(o)])
    for case in scenarios:
        case['stats'] = group_stats([s for s in all_samples if s['scenario'] == case['scenario']],
                                    [o for o in all_outcomes if o['scenario'] == case['scenario']])
    summary = {'rounds': 18, 'warmups': 3, 'scenarios': scenarios, 'groups': overall,
               'scope': 'warm live AX line extraction only; shared traversal/activation, replay, screenshot, translation, report I/O excluded; fresh invocation-local marker cache; old trace formatting disabled',
               'audit': 'all scenario execution successful, output stable in every timed sample, exact native source offsets checked, complete status covers full source, single fastpath equals legacy output',
               'outcomes': all_outcomes}
    (folder / 'summary.json').write_text(json.dumps(summary, ensure_ascii=False, indent=2))
    rows = ''.join('<tr><td>' + html.escape(c['scenario']) + '</td>' + ''.join(
        f'<td>{c["stats"][m]["medianMs"]:.3f} ms / {c["stats"][m]["calls"]}회</td>' for m in METHODS) +
        f'<td><a href="{html.escape(c["report"], quote=True)}">고정 보고서</a></td></tr>' for c in scenarios)
    groups = ''
    for group, label in [('all', '전체 측정 대상'), ('single', '단일 텍스트 노드'), ('multi', '여러 텍스트 노드')]:
        groups += f'<h2>{label}</h2><table><tr><th>방식</th><th>중앙값 (p10~p90)</th><th>AX 호출</th><th>원문 범위 수집 완료</th></tr>'
        for method in METHODS:
            s = overall[group][method]
            groups += f'<tr><td>{LABELS[method]}</td><td>{s["medianMs"]:.3f} ms ({s["p10Ms"]:.3f}~{s["p90Ms"]:.3f})</td><td>{s["calls"]}</td><td>{s["complete"]}/{s["units"]}</td></tr>'
        groups += '</table>'
    detail = ''
    for case in scenarios:
        detail += '<details><summary>' + html.escape(case['scenario']) + ' 문단별 원문·상태·박스</summary>'
        units = sorted({o['paragraph'] for o in all_outcomes if o['scenario'] == case['scenario']})
        for unit in units:
            outcomes = [o for o in all_outcomes if o['scenario'] == case['scenario'] and o['paragraph'] == unit]
            detail += f'<details><summary>P{unit} · 텍스트 노드 {outcomes[0]["leafCount"]}개 · ' + html.escape(outcomes[0]['text'][:100]) + '</summary>'
            detail += '<pre>' + html.escape(json.dumps(outcomes, ensure_ascii=False, indent=2)) + '</pre></details>'
        detail += '</details>'
    document = '''<!doctype html><html lang="ko"><meta charset="utf-8"><title>AX 라인 경로 성능 비교</title>
<style>body{font:15px system-ui;max-width:1250px;margin:30px auto;line-height:1.6}table{border-collapse:collapse;width:100%;margin:15px 0}td,th{border:1px solid #aaa;padding:8px;text-align:left}pre{white-space:pre-wrap}summary{cursor:pointer}details{margin:8px}</style>
<h1>AX 라인 경로 성능 비교</h1>
<p><b>결론: 모든 문단에 새 경로를 적용하면 느리다. 단일 텍스트 노드는 기존 경로를 재사용하고, 여러 텍스트 노드는 새 경로를 사용하는 공통 진입점이 적합하다.</b></p>
<p>SCENARIO_COUNT개 대상 화면의 동일 AX 핸들에서 방식 순서를 번갈아 18회 측정했다. 준비 3회 제외, Swift -O, 모든 방식 상세 로그 생성 제외, 호출 간 marker 캐시 재사용 없음. 표의 ms는 줄 추출만 측정한다. 앱 전체 응답 시간이나 최초 활성화 속도가 아니다.</p>
<p>범위 수집 완료는 원문 전체 문자열을 얻었다는 뜻이다. 기존 방식의 여러 조각이 한 줄 전체 박스인 것은 아니며, 수식의 시각적 줄 문제도 해결됐다는 뜻이 아니다. 실패가 빠르게 종료되면 시간도 짧아지므로 완료 수를 함께 봐야 한다.</p>
<h2>시나리오별 (중앙값 / AX 호출 수)</h2><table><tr><th>시나리오</th><th>기존</th><th>새 경로 일괄</th><th>새 경로 + 단일 노드 기존 경로</th><th>보고서</th></tr>ROWS</table>
GROUPS
<p>집계 ms는 각 반복 번호에서 SCENARIO_COUNT개 화면의 줄 추출 시간을 합친 고정 작업량의 중앙값이다. 단일 노드 재사용 경로는 기존 코드와 동일하며, 그 구간의 작은 시간 차이는 측정 편차다. p10~p90은 관측 분포로 신뢰구간이 아니다. 단일 노드의 실패도 그대로 유지하며, 이번 측정으로 개선하지 않았다.</p>
<h2>검증과 남은 한계</h2><p>모든 측정 반복에서 결과가 동일했고 원문 UTF-16 범위를 검증했다. 고정 보고서에서 원문·원본 프레임이 일치하는 native 문단/컨트롤과 그 자식 StaticText를 비교했다. 자식 StaticText 없는 컨트롤과 독립 텍스트는 이 비교에서 제외됐다. 가시성 필터·폰트 크기·번역문 배치는 비교 대상이 아니다. 새 경로의 실험 구현이며 기본 추출기를 교체하지 않았다.</p><p><b>알려진 실패:</b> 코드 개행의 너비 0 범위에서 새 경로는 첫 줄 이후 중단되어 기존보다 부분 수집량이 적은 사례가 있었다. 수식도 시각적 한 줄로 통합되지 않았다. 기본 교체 전 별도 처리가 필요하다.</p>
DETAIL</html>'''.replace('ROWS', rows).replace('GROUPS', groups).replace('DETAIL', detail).replace('SCENARIO_COUNT', str(len(scenarios)))
    (folder / 'index.html').write_text(document)
    return summary


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('folder', type=Path)
    args = parser.parse_args()
    result = summarize(args.folder)
    print(args.folder / 'index.html')
    for group in ['all', 'single', 'multi']:
        print(group, {m: {k: v for k, v in s.items() if k not in ['roundMs', 'statuses']} for m, s in result['groups'][group].items()})
