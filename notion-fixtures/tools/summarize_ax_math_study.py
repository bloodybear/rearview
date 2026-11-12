#!/usr/bin/env python3
"""Issue-only math research evidence and two translation strategies.

Text/math membership comes from measured AXSubrole, never formula characters.
Placeholder requests are experimental inputs to the unchanged production broker,
not a new product translation policy. Preserve failed/missing/reordered tokens.
"""
import argparse
from collections import Counter
import html
import json
from pathlib import Path
import re
import subprocess


def nonrendering(text):
    # Classification for this audit, not an extractor exclusion rule. Keep the
    # exact strings and failed bounds observations in the saved evidence.
    return all(c.isspace() or c in '\u200b\u200c\u200d\u2060\ufeff' for c in text)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('study', type=Path)
    parser.add_argument('--translate', action='store_true')
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[2]
    evaluations = repo / 'notion-fixtures/evaluations'
    study = args.study.resolve()
    manifest = json.loads((study / 'summary.json').read_text())
    output = {'scope': 'research candidates only; standard extraction/translation/paragraph geometry unchanged', 'cases': [], 'controls': []}
    requests = {}
    for row in manifest['results']:
        if row.get('probeExit') != 0:
            raise ValueError('Incomplete live probe: ' + row['scenario'])
        measured = json.loads((evaluations / row['study']).read_text())
        assert not measured['timedOut']
        folder = evaluations / Path(row['report']).parent
        meta = json.loads((folder / 'metadata.json').read_text())
        replay = json.loads((repo / 'notion-fixtures/runs' / meta['runId'] / 'result.json').read_text())
        for unit in measured['paragraphs']:
            assert unit['status'] == 'measured'
            nodes = unit['subtree']
            maths = [n for n in nodes if n['attributes'].get('AXSubrole') == 'AXDocumentMath']
            context = {'scenario': row['scenario'], 'node': unit['node'], 'source': unit['source'],
                       'report': row['report'] + '#paragraph=' + str(unit['node'])}
            if not maths:
                context['report'] = row['report'] + '#node=' + str(unit['node'])
                output['controls'].append({**context, 'subroles': [n['attributes'].get('AXSubrole') for n in nodes],
                    'classes': nodes[0]['attributes'].get('AXDOMClassList', []),
                    'leafValues': [n['attributes'].get('AXValue') for n in nodes if n['attributes'].get('AXRole') == 'AXStaticText']})
                continue
            experiments = [e for e in unit['experiments'] if e['label'].startswith('outside-math-span-')]
            spans = []
            for experiment in experiments:
                text = experiment['text']
                observed = experiment['output']
                lines = observed.get('lineRanges', [])
                for line in lines:
                    data = text.encode('utf-16-le')
                    a, b = 2 * line['rangeStart'], 2 * (line['rangeStart'] + line['rangeLength'])
                    assert data[a:b].decode('utf-16-le') == line['text']
                if not nonrendering(text):
                    assert observed['lineRangeStatus'] == 'complete_unverified', (row['scenario'], unit['node'], experiment)
                    assert ''.join(line['text'] for line in lines) == text
                    requests[text] = {'source': text, 'protectNonSourceText': False}
                spans.append({'text': text, 'nonrendering': nonrendering(text), 'status': observed['lineRangeStatus'],
                              'calls': experiment['calls'], 'seconds': experiment['seconds'], 'lines': lines})
            parents = {n['index']: n['parent'] for n in nodes}
            math_indices = {n['index'] for n in maths}
            def in_math(index):
                while index is not None:
                    if index in math_indices:
                        return True
                    index = parents[index]
                return False
            parts, math_number = [], 0
            for n in nodes:
                if n['index'] in math_indices:
                    parts.append({'kind': 'math', 'token': f'⟦MATH_{math_number}⟧', 'index': n['index'],
                                  'text': n['wholeRange'].get('text'), 'frame': n['frame']})
                    math_number += 1
                elif n['attributes'].get('AXRole') == 'AXStaticText' and not in_math(n['index']):
                    text = n['attributes']['AXValue']
                    if parts and parts[-1]['kind'] == 'text':
                        parts[-1]['text'] += text
                    else:
                        parts.append({'kind': 'text', 'text': text})
            placeholder_source = ''.join(p.get('token', p.get('text', '')) for p in parts)
            assert '⟦MATH_' not in ''.join(p.get('text') or '' for p in parts)
            requests[placeholder_source] = {'source': placeholder_source, 'protectNonSourceText': False}
            current = next(e for e in unit['experiments'] if e['label'] == 'all-leaves-current')
            output['cases'].append({**context, 'mathCount': len(maths), 'spans': spans, 'parts': parts,
                'placeholderSource': placeholder_source, 'current': current['output'], 'currentCalls': current['calls'],
                'image': str((Path(row['report']).parent / 'screen.png').as_posix()), 'frame': replay['screenshot']['frame'],
                'mathFrames': [n['frame'] for n in maths], 'AXStudy': row['study']})
    input_path, translation_path = study / 'translation-input.json', study / 'translation-output.json'
    input_path.write_text(json.dumps(list(requests.values()), ensure_ascii=False, indent=2) + '\n')
    if args.translate:
        binary = repo / '.build/ax-report-translation'
        if not binary.exists():
            raise RuntimeError('Run standard reports first to build the standalone production-broker adapter')
        with (study / 'translation.log').open('w') as log:
            result = subprocess.run([str(binary), '--translate-ax-report', str(input_path), str(translation_path)],
                                    cwd=repo, stdout=log, stderr=subprocess.STDOUT, timeout=600)
        if result.returncode:
            raise RuntimeError('Translation research failed; inspect retained output and translation.log')
    translated = {}
    if translation_path.exists():
        translated = {e['source']: e for e in json.loads(translation_path.read_text())['entries']}
    attributed_path = study / 'attributed-output.json'
    attributed = {e['key']: e for e in json.loads(attributed_path.read_text())['entries']} if attributed_path.exists() else {}
    high_path = study / 'attributed-output-high-fidelity.json'
    high = {e['key']: e for e in json.loads(high_path.read_text())['entries']} if high_path.exists() else {}
    for case in output['cases']:
        for span in case['spans']:
            if not span['nonrendering']:
                span['translationResult'] = translated.get(span['text'], {'status': 'not_requested'})
        response = translated.get(case['placeholderSource'], {'status': 'not_requested'})
        case['placeholderResult'] = response
        expected = [p['token'] for p in case['parts'] if p['kind'] == 'math']
        target = response.get('translation', '')
        actual = re.findall(r'⟦MATH_\d+⟧', target)
        case['placeholderValidation'] = {'expected': expected, 'actual': actual,
            'exactTokensAndOrder': actual == expected and response.get('status') == 'translated',
            'meaningAndPlacementGuaranteed': False}
        case['nativeProtectedResult'] = attributed.get(case['placeholderSource'], {'status': 'not_requested'})
        case['nativeHighFidelityResult'] = high.get(case['placeholderSource'], {'status': 'not_requested'})
    spans = [s for c in output['cases'] for s in c['spans'] if not s['nonrendering']]
    output['counts'] = {'mathParagraphObservations': len(output['cases']),
        'mathObjects': sum(c['mathCount'] for c in output['cases']), 'readableOutsideSpans': len(spans),
        'outsideSpanStatuses': dict(Counter(s['status'] for s in spans)),
        'nonrenderingSpans': sum(s['nonrendering'] for c in output['cases'] for s in c['spans']),
        'uniqueTranslationRequests': len(requests), 'translationStatuses': dict(Counter(e['status'] for e in translated.values())),
        'placeholderAccepted': sum(c['placeholderValidation']['exactTokensAndOrder'] for c in output['cases']),
        'controlsWithoutDocumentMath': len(output['controls'])}
    if attributed:
        output['counts']['uniqueNativeProtectionRequests'] = len(attributed)
        output['counts']['nativeProtectionExactMath'] = sum(e.get('exactMathAndOrder') is True for e in attributed.values())
    if high:
        output['counts']['nativeHighFidelityExactMath'] = sum(e.get('exactMathAndOrder') is True for e in high.values())
    output['translationStrategyEvidence'] = {}
    for key, filename in [('nativeLowLatency', 'attributed-output.json'), ('nativeLowLatencyBatch', 'attributed-output-batch.json'), ('nativeHighFidelity', 'attributed-output-high-fidelity.json')]:
        path = study / filename
        if path.exists():
            entries = json.loads(path.read_text())['entries']
            output['translationStrategyEvidence'][key] = {'requestCount': len(entries),
                'exactMathAndOrder': sum(e.get('exactMathAndOrder') is True for e in entries),
                'requestSecondsTotal': sum(e.get('seconds', 0) for e in entries),
                'scope': 'one sequential pass; excludes setup; not a stable product benchmark', 'file': filename}
    (study / 'findings.json').write_text(json.dumps(output, ensure_ascii=False, indent=2) + '\n')
    esc = html.escape
    cards = []
    def box(rect, cls, title):
        return f'<rect class="{cls}" x="{rect["x"]}" y="{rect["y"]}" width="{rect["width"]}" height="{rect["height"]}"><title>{esc(title)}</title></rect>'
    for case in output['cases']:
        frame = case['frame']
        overlay = ''.join(box(b, 'math', 'AXDocumentMath native frame; 전체 수식 경계 보장 안 됨') for b in case['mathFrames'])
        overlay += ''.join(box(l['box'], 'current', l['text']) for l in case['current'].get('lineRanges', []))
        overlay += ''.join(box(l['box'], 'split', l['text']) for s in case['spans'] for l in s['lines'])
        rows = []
        for span in case['spans']:
            target = span.get('translationResult', {}).get('translation', '')
            rows.append(f'<tr><td>{esc(span["text"])}</td><td>{esc(target)}</td><td>{esc(span["status"])} / {span["calls"]}회</td></tr>')
        pid = f'{case["scenario"]}-{case["node"]}'
        title = f'{case["scenario"]} / P{case["node"]}'
        placeholder = case['placeholderResult'].get('translation', '')
        native = case['nativeProtectedResult']
        high_result = case['nativeHighFidelityResult']
        cards.append(f'''<article id="{pid}"><h2>{esc(title)}</h2>
<p><a href="../{case['report']}">기존 고정 보고서</a> · <a href="../{case['AXStudy']}">AX 실측 JSON</a></p>
<details><summary>화면과 AX 박스 비교</summary><svg viewBox="{frame['x']} {frame['y']} {frame['width']} {frame['height']}">
<image href="../{case['image']}" x="{frame['x']}" y="{frame['y']}" width="{frame['width']}" height="{frame['height']}"/>{overlay}</svg></details>
<table><thead><tr><th>수식 밖 원문</th><th>독립 번역</th><th>라인 상태 / 조회 수</th></tr></thead><tbody>{''.join(rows)}</tbody></table>
<p>문맥 번역 후보 입력: {esc(case['placeholderSource'])}</p><p>실제 번역: {esc(placeholder)}</p>
<p>표식 개수·순서 유지: {case['placeholderValidation']['exactTokensAndOrder']} (의미·배치 보장 아님)</p>
<p>공식 skipsTranslation 후보(별도 API 조사, 제품 broker 경로 아님): {esc(native.get('translation', '미실행'))}<br>수식 원문·범위 유지: {native.get('exactMathAndOrder', False)}</p>
<p>highFidelity + skipsTranslation 후보: {esc(high_result.get('translation', '미실행'))}<br>수식 원문·범위 유지: {high_result.get('exactMathAndOrder', False)} / {high_result.get('seconds', 0):.3f}초 (단발 참고값)</p>
<details><summary>AX 정보와 원시 관측</summary><pre>{esc(json.dumps(case, ensure_ascii=False, indent=2))}</pre></details></article>''')
    content = f'''<!doctype html><html lang="ko"><meta charset="utf-8"><title>수식 경계와 번역 후보 조사</title>
<style>body{{font:15px system-ui;max-width:1100px;margin:24px auto;padding:0 18px;color:#222}}article{{border-top:1px solid #bbb;margin-top:25px;padding-top:12px}}table{{width:100%;border-collapse:collapse;margin:12px 0}}td,th{{border:1px solid #ccc;padding:8px;text-align:left;white-space:pre-wrap}}svg{{width:100%;display:block}}rect{{fill:none;stroke-width:1.5}}.math{{stroke:#ff9900;stroke-dasharray:5 3}}.current{{stroke:#48a4ff}}.split{{stroke:#31d078;fill:#31d07818}}body[data-mode="split"] .current,body[data-mode="current"] .split,body[data-mode="none"] rect{{display:none}}pre{{white-space:pre-wrap;overflow-wrap:anywhere}}nav{{position:sticky;top:0;background:white;padding:12px;border-bottom:1px solid #ddd;z-index:1}}</style>
<body data-mode="split"><h1>수식 경계와 번역 후보 조사</h1><p>실측한 조사 후보다. 기본 추출·번역 규칙과 문단 박스는 변경하지 않았다. 녹색: 수식 밖 텍스트의 AX 라인. 주황 점선: 수식 부모의 원본 AX 프레임(실제 전체 수식 영역과 다를 수 있음). 번역문을 화면에 배치한 검증은 아니다.</p>
<nav><label>박스 보기 <select id="mode"><option value="split">텍스트 분할 후보</option><option value="current">현재 전체 라인</option><option value="none">원본</option></select></label></nav>
<p>{esc(json.dumps(output['counts'], ensure_ascii=False))}</p>{''.join(cards)}
<script>document.querySelector('#mode').onchange=e=>document.body.dataset.mode=e.target.value;</script></body></html>'''
    (study / 'index.html').write_text(content)
    print(json.dumps(output['counts'], ensure_ascii=False))
    print(study / 'index.html')


if __name__ == '__main__':
    main()
