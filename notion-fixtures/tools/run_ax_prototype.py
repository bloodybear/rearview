#!/usr/bin/env python3
"""Prepare fixtures, build, replay selected screens and collect local AX reports."""
import argparse
from datetime import datetime, timezone
import html
import json
import math
from pathlib import Path
import subprocess
import tempfile
import sys



def run_rearview_app(app, arguments, run, name, log_folder):
    """Launch the signed .app through LaunchServices and preserve its real status."""
    with tempfile.TemporaryDirectory(prefix='rearview-ax-') as temporary:
        temporary = Path(temporary)
        stdout, stderr, status = (temporary / n for n in ('stdout', 'stderr', 'status'))
        command = ['/usr/bin/open', '-n', '-g', '-W', '-a', str(app),
                   '--stdout', str(stdout), '--stderr', str(stderr), '--args',
                   '--collect-ax-report'] + arguments + ['--command-status-file', str(status)]
        launched = run(command, name + '-launch')
        output = stdout.read_text() if stdout.exists() else ''
        error = stderr.read_text() if stderr.exists() else ''
        if launched.returncode:
            code, error = launched.returncode, error + launched.stderr
        else:
            try:
                code = int(status.read_text().strip())
            except (OSError, ValueError):
                code, error = 1, error + '\nRearview app command status receipt missing or invalid'
        (log_folder / (name + '.log')).write_text(output + '\n' + error)
        return subprocess.CompletedProcess(command, code, output, error)


def validate_collection(folder, candidates):
    """Check artifact integrity, not screenshot accuracy or a derived AX ground truth."""
    raw = {node['id']: node for node in json.loads((folder / 'rawAx.json').read_text())}
    seen = set()
    for candidate in candidates:
        node = candidate['node']
        if raw.get(node, {}).get('mathOwner') is not None:
            raise ValueError(f'수식이 최종 텍스트 대상으로 선택됨: {node}')
        if node not in raw or node in seen:
            raise ValueError(f'후보 노드 참조 오류/중복: {node}')
        seen.add(node)
        text = candidate['text']
        if not text:
            raise ValueError(f'빈 후보 문자열: {node}')
        def valid_box(box):
            return all(isinstance(box.get(key), (int, float)) and math.isfinite(box[key]) for key in ['x', 'y', 'width', 'height']) and box['width'] > 0 and box['height'] > 0
        if not valid_box(candidate['box']):
            raise ValueError(f'후보 박스 오류: {node}')
        previous_end = 0
        for line in candidate.get('lineRanges', []):
            start, length = line['rangeStart'], line['rangeLength']
            if start < previous_end or length <= 0 or not valid_box(line['box']):
                raise ValueError(f'라인 범위/박스 오류: {node}')
            units = text.encode('utf-16-le')
            if (start + length) * 2 > len(units) or units[start*2:(start+length)*2].decode('utf-16-le') != line['text']:
                raise ValueError(f'라인 원문 대응 오류: {node}')
            previous_end = start + length
        if candidate.get('lineRangeStatus') == 'complete_unverified':
            investigations = raw[node].get('rangeInvestigations', [])
            if not investigations or investigations[0].get('coveredUTF16Length') != len(text.encode('utf-16-le')) // 2:
                raise ValueError(f'완료 상태와 원문 커버리지 불일치: {node}')


    # Paragraph-owned lines can span nodes and therefore use their own exact
    # native source string (control AXTitle may include additional spaces).
    for node, observation in raw.items():
        probe = observation.get('paragraphLineInvestigation')
        if probe is None:
            continue
        if probe.get('inlineContent'):
            for part in probe['inlineContent']:
                if part['kind'] == 'math':
                    assert raw[part['node']]['mathOwner'] == part['node']
                    continue
                assert all(raw[i].get('mathOwner') is None for i in part['sourceNodes'])
                for line in part['lineRanges']:
                    data = part['text'].encode('utf-16-le')
                    assert data[2*line['rangeStart']:2*(line['rangeStart']+line['rangeLength'])].decode('utf-16-le') == line['text']
            for line in probe.get('lineRanges', []):
                part = next(p for p in probe['inlineContent'] if p['id'] == line['segment'])
                original = next(l for l in part['lineRanges'] if l['rangeStart'] == line['segmentRangeStart'] and l['rangeLength'] == line['rangeLength'])
                assert original['box'] == line['box'], '수식 분할 중 라인 좌표 변경'
        if observation.get('mathOwner') is not None:
            raise ValueError(f'수식에 문단 라인 조회가 수행됨: {node}')
        source = probe.get('lineSourceText', '').encode('utf-16-le')
        previous_end = 0
        for line in probe.get('lineRanges', []):
            start, length = line['rangeStart'], line['rangeLength']
            box = line['box']
            if start < previous_end or length <= 0 or not all(math.isfinite(box[k]) for k in ['x', 'y', 'width', 'height']) or box['width'] <= 0 or box['height'] <= 0:
                raise ValueError(f'문단 라인 범위/박스 오류: {node}')
            if source[start*2:(start+length)*2].decode('utf-16-le') != line['text']:
                raise ValueError(f'문단 라인 원문 대응 오류: {node}')
            previous_end = start + length
        if probe.get('lineRangeStatus') == 'complete_unverified' and probe.get('coveredUTF16Length') != len(source)//2:
            raise ValueError(f'문단 라인 완료 커버리지 오류: {node}')


def replay_with_repair(root, scenario, participating_fixtures, run, row):
    """Repair detected fixture drift once; never collect from the rejected replay.

    The user explicitly requested immediate ensure on change detection. Keep the
    rejected run and repair logs so restoration cannot hide an integrity failure.
    A second drift is reported rather than retried indefinitely.
    """
    command = [str(root / 'fixture'), 'scenario', 'apply', scenario, '--json']
    replay = run(command, f'{scenario}-replay')
    try:
        result = json.loads(replay.stdout)
    except ValueError:
        return replay
    changed = any(step.get('code') in {'fixture_changed', 'document_changed'}
                  for step in result.get('steps', []))
    if not changed:
        return replay
    repair = {'rejectedRunId': result.get('runId'), 'fixtures': participating_fixtures}
    row['fixtureRepair'] = repair
    print(f'{scenario}: 픽스처 변경 감지 → ensure 후 재생 재시도', flush=True)
    for fixture in participating_fixtures:
        ensured = run([str(root / 'fixture'), 'ensure', fixture], f'{scenario}-repair-{fixture}')
        if ensured.returncode:
            raise ValueError('변경 감지 후 픽스처 복구 실패: ' + fixture + ' / ' + ensured.stderr)
    replay = run(command, f'{scenario}-replay-after-repair')
    try:
        repair['retryRunId'] = json.loads(replay.stdout).get('runId')
    except ValueError:
        pass
    return replay


def write_batch_index(root, batch, summary):
    """Use the fixed batch template for ordinary runs and combined retry results."""
    rows = summary["results"]
    items = []
    for row in rows:
        label = html.escape(row['scenario'])
        if 'report' in row:
            label = f'<a href="{html.escape(row["report"])}">{label}</a>'
        if 'failureScreenshot' in row:
            label += f' <a href="{html.escape(row["failureScreenshot"])}">실패 시 화면</a>'
        items.append(f'<li>{label} — {html.escape(row["detail"])}</li>')
    statuses = {}
    for row in rows:
        for name, count in row.get('rangeStatuses', {}).items():
            statuses[name] = statuses.get(name, 0) + count
    findings = '<h2>문단 라인 범위 관측 요약</h2><p>문자별 fallback 없음. 라인 박스 ' + str(sum(row.get('lineBoxCount', 0) for row in rows)) + '개. 박스 존재가 실제 가시 문자열의 확정을 뜻하지 않습니다.</p><pre>' + html.escape(json.dumps(statuses, ensure_ascii=False, indent=2)) + '</pre>'
    content = '<meta charset="utf-8"><h1>AX prototype reports</h1><p>현재 규칙의 출력이며 정확성은 미검증입니다. 이번 실행 대상만 표시합니다.</p><ul>' + ''.join(items) + '</ul>' + findings
    if summary.get('controlTitleStudyReport'):
        content += '<p><a href="' + html.escape(summary['controlTitleStudyReport']) + '">AXTitle 글자 요소 조사</a></p>'
    # Relative report paths below are rooted in evaluations, including the archived index.
    (batch / 'index.html').write_text(content.replace('<meta charset="utf-8">', '<meta charset="utf-8"><base href="../">'))
    (root / 'evaluations/index.html').write_text(content)


def main():
    repo = Path(__file__).resolve().parents[2]
    root = repo / 'notion-fixtures'
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('scenarios', nargs='*', help='Scenario IDs; omitted means the active user-selected suite')
    parser.add_argument('--collector', choices=['evaluation', 'rearview'], default='evaluation')
    parser.add_argument('--skip-translation', action='store_true')
    parser.add_argument('--export-diagnostics', action='store_true', help='Export a local diagnostic ZIP from the Rearview collector')
    parser.add_argument('--ax-newline-context', action='store_true')
    parser.add_argument('--ax-newline-independent', action='store_true')
    parser.add_argument('--ax-collect-parent-values', action='store_true')
    parser.add_argument('--ax-repeat', type=int, choices=range(1, 6), default=2)
    parser.add_argument('--ax-translation-direction', choices=['ja-ko', 'ko-ja'], default='ja-ko')
    parser.add_argument('--reuse-replay-app', action='store_true', help='Use the signed installed replay app when all replay sources predate it')
    parser.add_argument('--control-title-study', action='store_true', help='Research only: inspect text anchors of final selected AXTitle controls without changing selection')
    parser.add_argument('--paragraph-probe', action='store_true', help='Collect native paragraph boundaries for research')
    parser.add_argument('--all-defined', action='store_true', help='Include every scenario JSON, beyond prototype cases')
    parser.add_argument('--list', action='store_true', help='List available prototype cases without running')
    parser.add_argument('--skip-ensure', action='store_true', help='Use existing fixtures without checking/restoring their contents')
    parser.add_argument('--group', action='append', choices=['lines', 'clipping', 'database', 'regression', 'all'], help='Repeatable scenario groups; no selection defaults to ax-active-scenarios.json')
    parser.add_argument('--activation', choices=['none', 'manual', 'enhanced', 'both'], default='manual', help='Research-only mode; restored after collection')
    parser.add_argument('--offscreen-study', action='store_true', help='Research only: compare AXVisibleOnly membership and discovery timing; keep production selection unchanged')
    parser.add_argument('--disable-1pt-filter', action='store_true', help='Research only: retain <=1pt text frames; other visibility filters remain enabled')
    args = parser.parse_args()
    if args.collector == 'rearview' and (args.offscreen_study or args.control_title_study or args.disable_1pt_filter or args.activation != 'manual'):
        parser.error('Rearview collector supports production extraction only')
    if args.collector != 'rearview' and args.ax_translation_direction != 'ja-ko':
        parser.error('Translation direction override requires --collector rearview')
    cases = json.loads((root / 'ax-prototype-cases.json').read_text())
    active = json.loads((root / "ax-active-scenarios.json").read_text())["scenarios"]
    if args.all_defined or not args.group:
        catalog = json.loads((root / 'scenario-catalog.json').read_text()).get('cases', {})
        existing = {case['id'] for case in cases}
        for path in sorted((root / 'scenarios').glob('*/*.json')):
            if path.stem not in existing:
                cases.append({'id': path.stem, 'purpose': catalog.get(path.stem, {}).get('purpose', path.stem), 'groups': []})
    known = {case['id']: case for case in cases}
    unknown = set(args.scenarios) - known.keys()
    if unknown:
        parser.error('Unknown scenarios: ' + ', '.join(sorted(unknown)))
    selected_ids = set(args.scenarios or (active if not args.group and not args.all_defined else []))
    groups = set(args.group or (['all'] if args.all_defined else []))
    selected = [case for case in cases if case['id'] in selected_ids or 'all' in groups or groups.intersection(case.get('groups', []))]
    if args.scenarios:
        selected = [known[scenario] for scenario in dict.fromkeys(args.scenarios)]
    if not args.scenarios and not args.group and not args.all_defined:
        by_id = {case['id']: case for case in selected}
        selected = [by_id[scenario] for scenario in active]
    if args.list:
        for case in selected:
            print(f"{case['id']}\t{','.join(case.get('groups', []))}\t{case['purpose']}")
        return 0

    # Resolve everything before mutating fixtures. Each selected fixture is ensured once.
    fixtures = {}
    participants = {}
    for case in selected:
        matches = list((root / 'scenarios').glob(f"*/{case['id']}.json"))
        if len(matches) != 1:
            parser.error(f"Expected exactly one scenario definition: {case['id']}")
        definition = json.loads(matches[0].read_text())
        fixtures[case['id']] = definition['fixtureId']
        preview = definition.get('state', {}).get('presentation', {}).get('fixtureId')
        participants[case['id']] = list(dict.fromkeys([definition['fixtureId']] + ([preview] if preview else [])))
    batch = root / 'evaluations' / ('batch-' + datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S.%fZ'))
    batch.mkdir(parents=True)
    rows = []

    def run(command, name):
        result = subprocess.run(command, cwd=repo, text=True, capture_output=True)
        (batch / f'{name}.log').write_text(result.stdout + '\n' + result.stderr)
        return result

    def finish():
        summary = {'selected': len(selected), 'lineMethod': 'native-paragraph-reverse-with-markers-local-reverse-single-node', 'collector': args.collector, 'skipTranslation': args.skip_translation, 'activation': args.activation, 'tinyTextFilterEnabled': not args.disable_1pt_filter, 'succeeded': sum(row['status'] == 'ok' for row in rows), 'results': rows}
        (batch / 'summary.json').write_text(json.dumps(summary, ensure_ascii=False, indent=2))
        if args.control_title_study:
            study = run([sys.executable, str(root / 'tools/summarize_ax_control_text.py'), str(batch)], 'summarize-control-title-text')
            if study.returncode:
                summary['controlTitleStudyError'] = (study.stdout + study.stderr)[-4000:]
            else:
                summary['controlTitleStudyReport'] = str((batch / 'control-title-text.html').relative_to(root / 'evaluations'))
            (batch / 'summary.json').write_text(json.dumps(summary, ensure_ascii=False, indent=2))
        write_batch_index(root, batch, summary)
        print(f"완료: {summary['succeeded']}/{len(selected)} 성공 | 로그·요약: {batch.relative_to(repo)}", flush=True)
        print(root / 'evaluations/index.html', flush=True)
        return 0 if summary['succeeded'] == len(selected) and not summary.get('controlTitleStudyError') else 1

    print(f'대상 {len(selected)}개 | 빌드', flush=True)
    build = run(['swift', 'build', '--product', 'NotionAXEvaluation'], 'build')
    if build.returncode:
        rows.extend({'scenario': case['id'], 'status': 'failed', 'detail': '빌드 실패: ' + build.stderr[-2000:]} for case in selected)
        return finish()
    if args.collector == 'rearview':
        packaged = run([str(repo / 'scripts/package_app.sh'), 'dev'], 'package-rearview')
        if packaged.returncode:
            rows.extend({'scenario': case['id'], 'status': 'failed', 'detail': 'Rearview 개발 앱 빌드·서명 실패: ' + packaged.stderr[-2000:]} for case in selected)
            return finish()
    if args.offscreen_study:
        probe_build = run(['swiftc', str(root / 'tools/probe_ax_offscreen.swift'), '-o', '/tmp/probe-ax-offscreen'], 'build-offscreen-probe')
        if probe_build.returncode:
            rows.extend({'scenario': case['id'], 'status': 'failed', 'detail': 'offscreen 조사 도구 빌드 실패: ' + probe_build.stderr[-2000:]} for case in selected)
            return finish()
    if args.paragraph_probe:
        probe_build = run(['swiftc', str(root / 'tools/probe_ax_paragraphs.swift'), '-o', '/tmp/probe-ax-paragraphs'], 'build-paragraph-probe')
        if probe_build.returncode:
            rows.extend({'scenario': case['id'], 'status': 'failed', 'detail': '문단 조사 도구 빌드 실패: ' + probe_build.stderr[-2000:]} for case in selected)
            return finish()
    if args.reuse_replay_app:
        executable = repo / 'dist/NotionScenarios.app/Contents/MacOS/NotionScenarios'
        replay_sources = list((repo / 'Sources/NotionScenarioCore').glob('*.swift')) + list((repo / 'Sources/NotionScenarios').glob('*.swift'))
        verified = run(['codesign', '--verify', '--strict', str(repo / 'dist/NotionScenarios.app')], 'verify-existing-replay')
        if not executable.exists() or verified.returncode or any(path.stat().st_mtime > executable.stat().st_mtime for path in replay_sources):
            rows.extend({'scenario': case['id'], 'status': 'failed', 'detail': '기존 재생 앱 검증 실패 또는 재생 소스가 더 최신임'} for case in selected)
            return finish()
        run(['dwarfdump', '--uuid', str(repo / '.build/debug/NotionScenarios'), str(executable)], 'existing-replay-build-ids')
        print('기존 서명 재생 앱 사용: 재생 소스 변경 없음, 서명 검증 통과. 동일 빌드 UUID 보증 아님.', flush=True)
    else:
        packaged = run([str(repo / 'scripts/package_notion_scenarios.sh')], 'package-replay')
        if packaged.returncode:
            rows.extend({'scenario': case['id'], 'status': 'failed', 'detail': '재생 앱 패키징 실패: ' + packaged.stderr[-2000:]} for case in selected)
            return finish()
    preparation = {}
    if not args.skip_ensure:
        for fixture in dict.fromkeys(f for ids in participants.values() for f in ids):
            print(f'픽스처 준비: {fixture}', flush=True)
            preparation[fixture] = run([str(root / 'fixture'), 'ensure', fixture], f'ensure-{fixture}')
    for case in selected:
        scenario = case['id']
        row = {'scenario': scenario, 'status': 'failed'}
        rows.append(row)
        prepared = preparation.get(fixtures[scenario])
        if prepared and prepared.returncode:
            row['detail'] = '픽스처 준비 실패; 재생·수집 생략: ' + (prepared.stderr + prepared.stdout)[-2000:]
            print(f'{scenario}: 실패 (ensure)', flush=True)
            continue
        try:
            # Replay also needs the complete AX tree on ordinary runs.
            activation = run([str(repo / '.build/debug/NotionAXEvaluation'), 'prepare-ax', '--activation', args.activation], f'{scenario}-prepare-ax')
            if activation.returncode:
                raise ValueError('재생 전 접근성 활성화 실패: ' + activation.stderr)
            replay = replay_with_repair(root, scenario, participants[scenario], run, row)
            if replay.returncode not in (0, 2):
                raise ValueError('재생 오류: ' + replay.stderr + replay.stdout)
            result = json.loads(replay.stdout)
            row['runId'] = result['runId']
            unexpected = [step for step in result['steps'] if step['status'] != 'verified' and not (step['item'] == 'zoom' and step['status'] == 'unsupported')]
            if unexpected:
                raise ValueError('재생 검증 실패: ' + json.dumps(unexpected, ensure_ascii=False))
            collector_arguments = (['--export-diagnostics'] if args.export_diagnostics and args.collector == 'rearview' else []) + (['--ax-newline-context'] if args.ax_newline_context else []) + (['--ax-newline-independent'] if args.ax_newline_independent else []) + (['--ax-repeat', str(args.ax_repeat)] if args.collector == 'rearview' else []) + (['--ax-collect-parent-values'] if args.ax_collect_parent_values else []) + [ '--root', str(root), '--run-id', result['runId'], '--activation', args.activation] + (['--ax-translation-direction', args.ax_translation_direction] + (['--skip-translation'] if args.skip_translation else []) if args.collector == 'rearview' else []) + (['--offscreen-study'] if args.offscreen_study else []) + (['--disable-1pt-filter'] if args.disable_1pt_filter else []) + (['--control-title-study'] if args.control_title_study else [])
            if args.collector == 'rearview':
                collected = run_rearview_app(repo / 'dist/Rearview-dev.app', collector_arguments, run, f'{scenario}-collect', batch)
            else:
                collected = run([str(repo / '.build/debug/NotionAXEvaluation'), 'collect'] + collector_arguments, f'{scenario}-collect')
            if collected.returncode not in ((0, 2) if args.collector == 'rearview' else (0,)):
                raise ValueError('AX 수집 실패: ' + collected.stderr)
            folder = Path(collected.stdout.strip())
            if args.offscreen_study:
                probe = run(['/tmp/probe-ax-offscreen', str(folder / 'offscreen.json')], f'{scenario}-offscreen')
                if probe.returncode:
                    raise ValueError('offscreen 조사 실패: ' + probe.stderr)
                row['offscreenProbe'] = str((folder / 'offscreen.json').relative_to(root / 'evaluations'))
            candidates = json.loads((folder / 'candidate.json').read_text())
            metadata = json.loads((folder / 'metadata.json').read_text())
            if args.skip_translation:
                metadata['skipTranslation'] = True
                (folder / 'metadata.json').write_text(json.dumps(metadata, ensure_ascii=False, indent=2))
            validate_collection(folder, candidates)
            rendered = run([sys.executable, str(root / 'tools/render_ax_report.py'), str(folder)], f'{scenario}-render')
            if rendered.returncode:
                raise ValueError('문단·노드·라인 보고서 생성 실패: ' + rendered.stderr)
            if not args.skip_translation and args.collector != 'rearview':
                translated = run([sys.executable, str(root / 'tools/translate_ax_reports.py'), str(folder)], f'{scenario}-translate')
                if translated.returncode:
                    raise ValueError('문단 실제 번역·보고서 생성 실패: ' + translated.stderr)
            row['report'] = str((folder / 'index.html').relative_to(root / 'evaluations'))
            row['candidateCount'] = len(candidates)
            row['collectionStatus'] = metadata.get('status', 'comparison_unverified')
            row['rangeCalls'] = metadata.get('rangeCalls', 0)
            row['totalAXCalls'] = metadata.get('totalAXCalls')
            row['rangeElapsed'] = metadata.get('rangeElapsed', 0)
            row['initializationSeconds'] = sum(sample.get('initializationSeconds', 0) for sample in metadata.get('sessionCollections', [])) or metadata.get('initializationSeconds', 0)
            row['sessionCollections'] = metadata.get('sessionCollections', [])
            row['collectionSeconds'] = metadata.get('elapsed', 0)
            line_units = json.loads((folder / 'paragraphs.json').read_text())['units']
            row['lineBoxCount'] = sum(len(c.get('lineRanges', [])) for c in line_units)
            row['rangeStatuses'] = {status: sum(c.get('lineRangeStatus') == status for c in line_units) for status in {c['lineRangeStatus'] for c in line_units if 'lineRangeStatus' in c}}

            row['detail'] = f"{case['purpose']} / 선택 {len(candidates)}개 / 수집 {metadata['elapsed']:.3f}s / 한도초과 {metadata['truncated']} / 대상·프레임 일치 {metadata['targetAndFrameMatch']}"
            row['detail'] += f" / 수집 상태 {row['collectionStatus']} / 라인 박스 {row['lineBoxCount']}개 / 범위 호출 {row['rangeCalls']}회 ({row['rangeElapsed']:.3f}s)"
            row['coverageLimitations'] = metadata.get('coverageLimitations', [])
            if 'menu_background_not_exposed_by_ax' in row['coverageLimitations']:
                row['detail'] += ' / 수집 한계: 메뉴 상태에서 배경 본문 AX 미노출'
            if metadata['truncated'] or not metadata['targetAndFrameMatch']:
                raise ValueError('수집 검증 실패: ' + row['detail'])
            if args.paragraph_probe:
                probe = run(['/tmp/probe-ax-paragraphs', str(folder)], f'{scenario}-paragraph-probe')
                if probe.returncode:
                    raise ValueError('문단 조사 실패: ' + probe.stderr)
                paragraph = json.loads((folder / 'paragraph-probe.json').read_text())
                if paragraph['truncated'] or not paragraph['windowFrameUnchanged']:
                    raise ValueError('문단 조사 한도/창 상태 검증 실패')
                row['paragraphProbe'] = str((folder / 'paragraph-probe.json').relative_to(root / 'evaluations'))
            row['translationSamples'] = metadata.get('translationSamples', [])
            row['translationPreparationSeconds'] = metadata.get('translationPreparationSeconds')
            if collected.returncode == 2:
                raise ValueError('실제 앱 번역 실패: 결과와 오류는 보고서에 보존됨')
            row['status'] = 'ok'
            print(f'{scenario}: 성공 / 선택 {len(candidates)}개', flush=True)
        except (ValueError, KeyError, OSError) as error:
            row['detail'] = str(error)[-2000:]
            if row.get('runId') and (root / 'runs' / row['runId'] / 'screen.png').exists():
                row['failureScreenshot'] = f"../runs/{row['runId']}/screen.png"
            print(f'{scenario}: 실패 / {row["detail"]}', flush=True)
    return finish()


if __name__ == '__main__':
    sys.exit(main())
