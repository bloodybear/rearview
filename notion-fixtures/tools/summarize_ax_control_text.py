#!/usr/bin/env python3
"""Summarize opt-in AXTitle anchor research and render its recovered text with the fixed report template."""
import argparse
import collections
import copy
import html
import json
import shutil
import statistics
from pathlib import Path

from render_ax_report import render


def box(values):
    return dict(zip(('x', 'y', 'width', 'height'), values)) if len(values) == 4 else {}


def usable(values):
    return len(values) == 4 and values[2] > 1 and values[3] > 1


def anchor_observations(observations):
    for method, value in observations.items():
        if method == 'internalTree' or not isinstance(value, (dict, list)):
            continue
        for anchor in value if isinstance(value, list) else [value]:
            if isinstance(anchor, dict) and anchor.get('role') == 'AXStaticText':
                yield method, anchor


def summarize(batch, additional_batches=()):
    root = Path(__file__).resolve().parents[1]
    sources = [batch, *additional_batches]
    attempts = []
    latest = {}
    for source in sources:
        for result in json.loads((source / 'summary.json').read_text())['results']:
            attempts.append(dict(batch=source.name, scenario=result['scenario'], status=result['status']))
            previous = latest.get(result['scenario'])
            if result['status'] == 'ok' or previous is None or previous['status'] != 'ok':
                latest[result['scenario']] = result
    results = dict(selected=len(latest), results=list(latest.values()))
    records, scenarios, errors = [], [], []
    for result in results['results']:
        if result['status'] != 'ok':
            scenarios.append(dict(scenario=result['scenario'], status='replay_or_collection_failed',
                                  detail=result['detail']))
            continue
        folder = root / 'evaluations' / Path(result['report']).parent
        study_path = folder / 'control-title-study.json'
        if not study_path.exists():
            errors.append(result['scenario'] + ' 조사 파일 누락')
            continue
        study = json.loads(study_path.read_text())
        metadata = json.loads((folder / 'metadata.json').read_text())
        run_result = json.loads((root / 'runs' / metadata['runId'] / 'result.json').read_text())
        unsupported_checks = [step['item'] for step in run_result['steps'] if step['status'] == 'unsupported']
        nodes = json.loads((folder / 'rawAx.json').read_text())
        selected = json.loads((folder / 'candidate.json').read_text())
        expected = {c['node']: c for c in selected if c['textSource'] == 'AXTitle'}
        if study.get('truncated') or not study.get('windowFrameUnchanged'):
            errors.append(result['scenario'] + ' 조사 한도 또는 창 변경')
        if set(expected) != {r['node'] for r in study['rows']}:
            errors.append(result['scenario'] + ' 최종 AXTitle 대상과 조사 대상 불일치')
        scenario_records = []
        for row in study['rows']:
            original = nodes[row['node']]
            if original['title'] != row['title'] or box(row['frame']) != original['frame']:
                errors.append(result['scenario'] + ' 노드 원문·프레임 불일치')
            observed = row['observations']
            reference = {}
            for entry in observed.get('internalTree', []):
                anchor = entry.get('node', {})
                if anchor.get('role') == 'AXStaticText' and anchor.get('fullText'):
                    reference[str(entry['id'])] = anchor
            methods = collections.defaultdict(set)
            for native_id in reference:
                methods[native_id].add('internal-tree')
            for method, anchor in anchor_observations(observed):
                native_id = anchor.get('nativeID', '')
                # Structural membership is checked against independently queried
                # live Chromium child/label IDs, including raw StaticText parents.
                if native_id in reference:
                    methods[native_id].add(method)
            benchmark = row.get('benchmark', {})
            timing = {}
            matched = {}
            recovered_nodes = {}
            for method, samples in benchmark.get('samples', {}).items():
                warm = samples[1:]
                timing[method] = dict(
                    firstUs=samples[0]['us'],
                    medianUs=statistics.median(s['us'] for s in warm),
                    p95Us=sorted(s['us'] for s in warm)[int(len(warm)*.95)],
                    calls=statistics.median(s['calls'] for s in warm),
                )
                outcome = benchmark['results'][method]
                if outcome['status'] == 'matched':
                    native_id = outcome.get('nativeID', '')
                    if native_id not in reference:
                        errors.append(result['scenario'] + ' 소유 관계가 확인되지 않은 일치 ' + str(row['node']))
                    else:
                        matched[method] = native_id
                        if outcome.get('internalTreeComplete') is False:
                            errors.append(result['scenario'] + ' 측정 경로의 내부 글자 탐색 미완료 ' + str(row['node']))
                        recovered = outcome.get('textNodes', [outcome])
                        recovered_nodes[method] = [anchor['nativeID'] for anchor in recovered]
                        for anchor in recovered:
                            expected_anchor = reference.get(anchor.get('nativeID', ''))
                            if expected_anchor is None or anchor.get('text') != expected_anchor['fullText'] or anchor.get('frame') != expected_anchor.get('frame'):
                                errors.append(result['scenario'] + ' 복구 문자열·소유 관계 불일치 ' + str(row['node']))
            measured = {key for key, anchor in reference.items()
                        if usable(anchor.get('frame', []))
                        and len(anchor.get('bounds', [])) == 4
                        and anchor['bounds'][2] > 0 and anchor['bounds'][3] > 0}
            eligible = {key for key in measured if reference[key].get('intersectsControl')}
            opaque = {method: native_id for method, native_id in matched.items()
                      if method not in {'internal-tree', 'internal-owned', 'internal-owned-node', 'hybrid-internal', 'owned-internal'}}
            complete = observed.get('internalTreeComplete', False)
            if not complete:
                status = 'internal_tree_incomplete'
            elif opaque:
                status = 'opaque_marker_recovered'
            elif eligible:
                status = 'internal_diagnostic_only'
            elif measured:
                status = 'static_text_outside_control'
            elif reference:
                status = 'static_text_geometry_unusable'
            else:
                status = 'no_static_text_in_internal_tree'
            record = dict(
                scenario=result['scenario'], node=row['node'], role=row['role'], surface=row['surface'],
                title=row['title'], frame=row['frame'], status=status,
                report=result['report'] + '#node=' + str(row['node']),
                internalTreeComplete=complete, referenceText=reference,
                sourceTitleDiffers=bool(reference) and not any(anchor['fullText'] == row['title'] for anchor in reference.values()),
                recoveryMethods={key: sorted(value) for key, value in methods.items()},
                matchedMethods=matched, recoveredNodes=recovered_nodes, timing=timing,
            )
            records.append(record)
            scenario_records.append(record)

        # Use the existing HTML renderer for the issue-specific snapshot.
        # Original observation files remain linked from the issue index.
        destination = folder.with_name(folder.name + '-control-text-study')
        destination.mkdir(exist_ok=True)
        visual_nodes = copy.deepcopy(nodes)
        visual_selected = [copy.deepcopy(c) for c in selected if c['textSource'] != 'AXTitle']
        for record in scenario_records:
            visible = [(key, anchor) for key, anchor in record['referenceText'].items()
                       if usable(anchor.get('frame', [])) and anchor.get('intersectsControl')]
            if not visible:
                visual_selected.append(copy.deepcopy(expected[record['node']]))
            for native_id, anchor in visible:
                index = len(visual_nodes)
                source = 'AXValue' if anchor.get('value') else 'AXStringForTextMarkerRange'
                text = anchor['fullText']
                visual_nodes.append(dict(
                    id=index, role='AXStaticText', value=anchor.get('value', ''),
                    title=anchor.get('title', ''), frame=box(anchor['frame']),
                    boundsForFullRange=box(anchor.get('bounds', [])),
                    discovery=dict(control=record['node'], nativeID=native_id,
                                   methods=record['recoveryMethods'].get(native_id, []),
                                   status=record['status']),
                    decision='observed', decisionReason='control_title_text_study',
                ))
                visual_selected.append(dict(
                    node=index, text=text, textSource=source, box=box(anchor['frame']),
                    boxKind='node_frame', selectionReason='control_title_text_study',
                    uncertainty='AXTitle 글자 요소 조사. 현재 추출 규칙 채택은 검토 중입니다.',
                    lineRanges=[], lineRangeStatus='not_investigated',
                ))
        for name in ('metadata.json', 'screen.png'):
            shutil.copyfile(folder / name, destination / name)
        (destination / 'rawAx.json').write_text(json.dumps(visual_nodes, ensure_ascii=False, indent=2))
        (destination / 'candidate.json').write_text(json.dumps(visual_selected, ensure_ascii=False, indent=2))
        render(destination)
        page = (destination / 'index.html').read_text()
        banner = ('<p style="background:#fff2ce;color:#332500;padding:12px">'
                  'AXTitle 글자 요소 조사 · 내부 AX에서 확인한 글자 노드를 표시합니다. '
                  '일반 마커 경로와 내부 진단 전용 경로의 구분은 '
                  f'<a href="../{html.escape(folder.name)}/control-title-study.json">조사 원본</a>에서 확인할 수 있습니다. '
                  f'<a href="../{html.escape(folder.name)}/index.html">현재 추출 결과</a></p>')
        page = page.replace('<h1>', banner + '<h1>', 1)
        (destination / 'index.html').write_text(page)
        scenarios.append(dict(
            scenario=result['scenario'], status='ok', targets=len(scenario_records),
            counts=dict(collections.Counter(r['status'] for r in scenario_records)),
            report=str((destination / 'index.html').relative_to(root / 'evaluations')),
            originalReport=result['report'], baselineCollectionMs=metadata['elapsed'] * 1000,
            unsupportedChecks=unsupported_checks, coverageLimitations=metadata.get('coverageLimitations', []),
            studyMs=study['elapsedUs']/1000,
        ))

    summary = dict(
        requestedScenarios=results['selected'], inspectedScenarios=sum(s['status'] == 'ok' for s in scenarios),
        controls=len(records), counts=dict(collections.Counter(r['status'] for r in records)),
        errors=errors, scenarios=scenarios, records=records,
        sourceBatches=[source.name for source in sources], attempts=attempts,
    )
    summary['unsupportedChecks'] = dict(collections.Counter(
        check for scenario in scenarios for check in scenario.get('unsupportedChecks', [])))
    summary['coverageLimitations'] = {scenario['scenario']: scenario['coverageLimitations']
                                      for scenario in scenarios if scenario.get('coverageLimitations')}
    route_stats = {}
    for method in sorted({key for record in records for key in record['timing']}):
        totals = []
        for scenario in scenarios:
            if scenario['status'] != 'ok':
                continue
            same_scenario = [r for r in records if r['scenario'] == scenario['scenario']]
            if not any(method in r['timing'] for r in same_scenario):
                continue
            total = sum(r['timing'].get(method, {}).get('medianUs', 0) for r in same_scenario) / 1000
            totals.append(dict(scenario=scenario['scenario'], sumMedianMs=total,
                               baselineCollectionMs=scenario['baselineCollectionMs']))
        route_stats[method] = dict(
            measuredScenarios=len(totals),
            recoveredControls=sum(method in r['matchedMethods'] for r in records),
            recoveredTextNodes=sum(len(r.get('recoveredNodes', {}).get(method, [])) for r in records),
            medianControlUs=statistics.median(r['timing'][method]['medianUs'] for r in records if method in r['timing']) if records else 0,
            medianScenarioSumMs=statistics.median(r['sumMedianMs'] for r in totals) if totals else 0,
            maxScenarioSumMs=max((r['sumMedianMs'] for r in totals), default=0),
            scenarios=totals,
        )
    summary['routeStats'] = route_stats
    (batch / 'control-title-text.json').write_text(json.dumps(summary, ensure_ascii=False, indent=2))
    labels = {
        'opaque_marker_recovered': '일반 마커 경로에서 글자 요소 확보',
        'internal_diagnostic_only': '내부 진단에서 글자 요소 확보',
        'different_or_fragmented_source': '분리된 원문 또는 제목과 다른 글자 요소',
        'static_text_geometry_unusable': '동일 원문의 글자 요소에 유효한 박스 부족',
        'static_text_outside_control': '글자 요소가 해당 컨트롤 프레임 밖에 있음',
        'no_static_text_in_internal_tree': '내부 트리에 글자 요소 없음',
        'internal_tree_incomplete': '내부 트리 조사 미완료',
    }
    chunks = ['<meta charset="utf-8"><base href="../"><title>AXTitle 글자 요소 조사</title>',
              '<style>body{font:15px system-ui;max-width:1200px;margin:32px auto}td,th{padding:7px;border-bottom:1px solid #ddd;text-align:left}pre{white-space:pre-wrap}summary{cursor:pointer}a{margin-right:10px}</style>',
              '<h1>AXTitle 글자 요소 조사</h1>',
              f'<p>{summary["inspectedScenarios"]}/{summary["requestedScenarios"]}개 시나리오, '
              f'최종 선택 AXTitle {summary["controls"]}건. 각 건은 시나리오별 관측이며 반복되는 UI도 포함합니다.</p>',
              '<ul>']
    for name, count in summary['counts'].items():
        chunks.append(f'<li>{html.escape(labels[name])} {count}건</li>')
    chunks.append('</ul>')
    if summary['unsupportedChecks']:
        chunks.append('<p>재생 검증의 미지원 항목 · ' + html.escape(', '.join(
            f'{check} {count}개' for check, count in summary['unsupportedChecks'].items()))
            + '. 실제 캡처의 대상·창 프레임 일치와 수집 한도를 검증했습니다.</p>')
    if summary['coverageLimitations']:
        chunks.append('<details><summary>기존 수집 한계</summary><pre>'
                      + html.escape(json.dumps(summary['coverageLimitations'], ensure_ascii=False, indent=2)) + '</pre></details>')
    if errors:
        chunks.append('<h2>검증 오류</h2><pre>' + html.escape('\n'.join(errors)) + '</pre>')
    chunks.append('<h2>조회 비용</h2><p>같은 AX 핸들에서 각 경로를 번갈아 7회 측정했습니다. 첫 회를 제외한 노드별 중앙값을 시나리오별로 합산했습니다. '
                  '<code>-node</code> 경로는 원문·노드 프레임·소유 관계 확보를 측정하고, 이후 독립 조사에서 범위 원문·좌표를 검증합니다. '
                  '다른 경로는 범위 검증 비용도 포함합니다. 실제 추출기 전체의 실행 시간은 별도 검증 대상입니다.</p>'
                  '<table><tr><th>경로</th><th>측정 시나리오</th><th>확보한 컨트롤 관측</th><th>글자 노드 관측</th><th>노드 중앙값</th><th>시나리오 합 중앙값</th><th>시나리오 합 최대</th></tr>')
    for method, timing in route_stats.items():
        chunks.append(f'<tr><td>{html.escape(method)}</td><td>{timing["measuredScenarios"]}개</td><td>{timing["recoveredControls"]}건</td>'
                      f'<td>{timing["recoveredTextNodes"]}건</td><td>{timing["medianControlUs"]:.1f} μs</td><td>{timing["medianScenarioSumMs"]:.3f} ms</td>'
                      f'<td>{timing["maxScenarioSumMs"]:.3f} ms</td></tr>')
    chunks.append('</table>')
    chunks.append('<h2>시나리오</h2>')
    for scenario in scenarios:
        name = html.escape(scenario['scenario'])
        if scenario['status'] == 'ok':
            chunks.append(f'<p><b>{name}</b> <a href="{html.escape(scenario["report"])}">글자 요소 보기</a>'
                          f'<a href="{html.escape(scenario["originalReport"])}">현재 추출 결과</a></p>'
                          f'<details><summary>{scenario["targets"]}건의 조사 결과</summary><pre>'
                          + html.escape(json.dumps(scenario['counts'], ensure_ascii=False, indent=2)) + '</pre></details>')
        else:
            chunks.append(f'<details><summary>{name} · 재생·수집 실패</summary><pre>{html.escape(scenario["detail"])}</pre></details>')
    chunks.append('<details><summary>실행 배치와 재실행 기록</summary><p>시나리오별 최신 성공 결과를 합산했습니다. 실패한 실행 시도도 보존합니다.</p><ul>')
    for source in sources:
        attempts_for_batch = [attempt for attempt in attempts if attempt['batch'] == source.name]
        failed = [attempt['scenario'] for attempt in attempts_for_batch if attempt['status'] != 'ok']
        chunks.append('<li><a href="' + html.escape(source.name) + '/summary.json">' + html.escape(source.name) + '</a>'
                      + f' · {len(attempts_for_batch)-len(failed)}/{len(attempts_for_batch)} 성공'
                      + (' · 실패 ' + html.escape(', '.join(failed)) if failed else '') + '</li>')
    chunks.append('</ul></details>')
    chunks.append('<h2>노드별 결과</h2><table><tr><th>시나리오·노드</th><th>원문</th><th>결과</th><th>확인된 경로</th></tr>')
    for record in records:
        methods = ', '.join(m for m in record['matchedMethods'] if m not in {'internal-tree', 'internal-owned', 'internal-owned-node', 'hybrid-internal', 'owned-internal'})
        chunks.append(f'<tr><td><a href="{html.escape(record["report"])}">{html.escape(record["scenario"])} #{record["node"]}</a></td>'
                      f'<td>{html.escape(record["title"])}</td><td>{labels[record["status"]]}</td><td>{html.escape(methods)}</td></tr>')
    chunks.append('</table>')
    (batch / 'control-title-text.html').write_text(''.join(chunks))
    return summary


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('batch', type=Path)
    parser.add_argument('--include-batch', action='append', type=Path, default=[], help='Combine the latest successful evidence for each scenario')
    args = parser.parse_args()
    summary = summarize(args.batch.resolve(), [path.resolve() for path in args.include_batch])
    print(json.dumps({key: summary[key] for key in ('requestedScenarios', 'inspectedScenarios', 'controls', 'counts', 'errors')}, ensure_ascii=False))
    return 1 if summary['errors'] else 0


if __name__ == '__main__':
    raise SystemExit(main())
