#!/usr/bin/env python3
"""Render three independent AX layers from one captured tree; no AX calls or text joining."""
import argparse
import base64
import struct
import html
import hashlib
import json
from pathlib import Path


def translation_sources(root):
    # Compile these production sources read-only into a separate research CLI.
    return [root/'tools/ax_report_translation.swift', root.parent/'Sources/NotionAXCore/MathTranslationPolicy.swift', root.parent/'Sources/NotionAXCore/LogicalLines.swift', root.parent/'Sources/NotionAXCore/CodeTextSegments.swift', root.parent/'Sources/Rearview/AXParagraphTranslator.swift'] + [root.parent/'Sources/Rearview'/name for name in (
        'TranslationBroker.swift', 'LanguageProtector.swift', 'Models.swift',
        'Localization.swift', 'PerformanceProfiler.swift')]


def translation_policy_id(root):
    return 'production-ja-ko-code-only-protected-math-context-hardbreak-code-ranges-v9-' + hashlib.sha256(
        b''.join(p.read_bytes() for p in translation_sources(root))).hexdigest()


def translation_cache_key(source, protect, parts=None):
    # Identical strings in prose and code must not share a policy-dependent result.
    value = [source, bool(protect)]
    if parts is not None:
        value.append(parts)
    return json.dumps(value, ensure_ascii=False, sort_keys=True)


def entry_cache_key(entry):
    return translation_cache_key(entry['source'], entry.get('protectNonSourceText') in (True, 'true'), entry.get('parts'))


def translation_request(unit):
    request = dict(source=unit.get('translationSourceText', unit['text']), protectNonSourceText=unit['protectNonSourceText'])
    if 'codeSegments' in unit:
        request['codeSegments'] = unit['codeSegments']
    if unit.get('inlineContent'):
        # Only typed boundaries and normal text cross the translation boundary.
        # AX IDs/frames are not cache keys. Original paragraph text remains the
        # report/cache identity; the adapter never sends formula text to a model.
        request['parts'] = [dict(kind='math') if part['kind'] == 'math' else dict(kind='text', text=part['text'])
                            for part in unit['inlineContent']]
    return request


def clip_timeline_box(box, panel):
    # Paragraph/node display geometry only; never apply to AX line boxes.
    x, y, w, h = (box[k] for k in ('x', 'y', 'width', 'height'))
    px, py, pw, ph = (panel[k] for k in ('x', 'y', 'width', 'height'))
    if px <= x and py <= y and py + ph >= y + h and x < px + pw:
        return dict(box, x=max(x, px + pw), width=max(0, x + w - max(x, px + pw)))
    return dict(box)

def clip_below_header(box, header):
    x, y, w, h = (box[k] for k in ('x', 'y', 'width', 'height'))
    hx, hy, hw, hh = (header[k] for k in ('x', 'y', 'width', 'height'))
    if hx <= x and hx + hw >= x + w and hy <= y < hy + hh:
        return dict(box, y=hy + hh, height=max(0, y + h - (hy + hh)))
    return dict(box)


def subtract_preview(box, panel):
    x, y, w, h = (box[k] for k in ('x', 'y', 'width', 'height'))
    px, py, pw, ph = (panel[k] for k in ('x', 'y', 'width', 'height'))
    left, top, right, bottom = max(x, px), max(y, py), min(x+w, px+pw), min(y+h, py+ph)
    if left >= right or top >= bottom:
        return [dict(box)]
    pieces = [(x,y,w,top-y), (x,bottom,w,y+h-bottom),
              (x,top,left-x,bottom-top), (right,top,x+w-right,bottom-top)]
    return [dict(x=a,y=b,width=c,height=d) for a,b,c,d in pieces if c > 0 and d > 0]


def build_paragraphs(nodes, selected):
    by_id = {n['id']: n for n in nodes}
    containers = set()
    for node in nodes:
        if node['role'] == 'AXTextArea':
            parent = node.get('parent')
            while parent in by_id:
                if by_id[parent]['role'] == 'AXTextArea':
                    containers.add(parent)
                parent = by_id[parent].get('parent')
    units, unresolved = {}, []
    for candidate in selected:
        chosen = None
        parent = by_id[candidate['node']].get('parent')
        # Every selected translation input needs a unit, including tabs and DB
        # properties. Use existing native text only; never concatenate fragments.
        # Stop at the first native text boundary. A document-wide editor cannot
        # become a unit just because a DB cell has no local AXTextArea.
        if candidate['textSource'] == 'AXValue' and 'controlTextOwner' not in candidate:
            while parent in by_id:
                area = by_id[parent]
                role = area['role']
                frame = area.get('frame', {})
                valid = frame.get('width', 0) > 1 and frame.get('height', 0) > 1
                if role == 'AXTextArea':
                    if parent not in containers and area.get('value') and valid:
                        chosen = (parent, area['value'], frame, 'native_textarea', 'AXTextArea.AXValue')
                    break
                if role in {'AXButton', 'AXPopUpButton', 'AXRadioButton'}:
                    title = area.get('title', '')
                    if title and candidate['text'] in title and valid:
                        chosen = (parent, title, frame, 'native_control', role + '.AXTitle')
                    # Do not climb through a cell/control to a row or card label.
                    break
                parent = area.get('parent')
        if chosen is None:
            # An already selected static text or AXTitle is a complete atomic
            # translation input even when its semantic paragraph is unknown.
            # This is not a fabricated paragraph or an AX range-query fallback.
            chosen = (candidate['node'], candidate['text'], candidate.get('originalBox', candidate['box']),
                      'selected_text', by_id[candidate['node']]['role'] + '.' + candidate['textSource'])
        node, text, box, unit_type, source = chosen
        unit = units.setdefault(node, {'node': node, 'kind': 'paragraph', 'text': text,
            'box': box, 'members': [], 'unitType': unit_type,
            'status': 'translation_unit_candidate_unverified',
            'source': source + ' / native frame',
            'semanticParagraphConfirmed': False})
        unit['members'].append(candidate['node'])
        ancestor = candidate['node']
        is_code = False
        while ancestor in by_id:
            if 'notion-code-block' in by_id[ancestor].get('domClasses', []):
                is_code = True
                break
            ancestor = by_id[ancestor].get('controlTextOwner', by_id[ancestor].get('parent'))
        unit['isCodeBlock'] = unit.get('isCodeBlock', False) or is_code
        unit['protectNonSourceText'] = unit['isCodeBlock']

        if candidate.get('timelineOcclusion'):
            unit.setdefault('originalBox', dict(candidate.get('originalBox', box) if unit_type == 'selected_text' else box))
            unit['timelineOcclusion'] = candidate['timelineOcclusion']
            unit['box'] = clip_timeline_box(unit['originalBox'], candidate['timelineOcclusion']['panelFrame'])
        if candidate.get('timelineHeaderOcclusion'):
            unit.setdefault('originalBox', dict(candidate.get('originalBox', box) if unit_type == 'selected_text' else box))
            unit['timelineHeaderOcclusion'] = candidate['timelineHeaderOcclusion']
            unit['box'] = clip_below_header(unit['box'], candidate['timelineHeaderOcclusion']['headerFrame'])
        if candidate.get('tableHeaderOcclusion'):
            unit.setdefault('originalBox', dict(candidate.get('originalBox', box) if unit_type == 'selected_text' else box))
            unit['tableHeaderOcclusion'] = candidate['tableHeaderOcclusion']
            unit['box'] = clip_below_header(unit['box'], candidate['tableHeaderOcclusion']['headerFrame'])
        if candidate.get('previewOcclusions'):
            unit['previewOcclusions'] = candidate['previewOcclusions']
    for unit in units.values():
        probe = by_id[unit['node']].get('paragraphLineInvestigation')
        if probe is not None:
            unit['lineRanges'] = probe.get('lineRanges', [])
            unit['lineRangeStatus'] = probe.get('lineRangeStatus')
            unit['lineMethod'] = probe.get('lineMethod')
            unit['lineSourceText'] = probe.get('lineSourceText', unit['text'])
            unit['lineSourceNodes'] = probe.get('sourceNodes', [])
            if probe.get('inlineContent'):
                unit['inlineContent'] = probe['inlineContent']
                unit['mathPolicy'] = probe['mathPolicy']
        else:
            # Old artifacts retain their historical node-line display.
            unit['lineRanges'] = []
        if 'codeSegments' in by_id[unit['node']]:
            unit['codeSegments'] = by_id[unit['node']]['codeSegments']
        fragments = [unit['box']]
        for occlusion in unit.get('previewOcclusions', []):
            fragments = [piece for box in fragments for piece in subtract_preview(box, occlusion['panelFrame'])]
        if unit.get('previewOcclusions'):
            unit.setdefault('originalBox', dict(unit['box']))
            unit['visibleBoxes'] = fragments
            unit['box'] = fragments[0] if fragments else dict(x=0,y=0,width=0,height=0)
    return [unit for unit in units.values() if unit['box'].get('width', 0) > 0 and unit['box'].get('height', 0) > 0], unresolved


def table_container_study(nodes, paragraphs):
    by_id = {n['id']: n for n in nodes}

    def chain(node):
        result, seen = [], set()
        while node in by_id and node not in seen:
            seen.add(node)
            item = by_id[node]
            result.append(item)
            node = item.get('controlTextOwner', item.get('parent'))
        return result

    result = []
    for p in paragraphs:
        chains = [chain(n) for n in p.get('members', [])]
        cells = {n['id']: n for c in chains for n in c
                 if n.get('role') == 'AXCell' or 'notion-table-view-cell' in n.get('domClasses', [])}
        if len(cells) > 1:
            continue
        cell = next(iter(cells.values()), None)
        if cell is None and (p.get('unitType') != 'native_textarea' or p['node'] not in by_id):
            continue
        containers = []
        if p.get('unitType') == 'native_textarea' and (cell is None or cell['role'] == 'AXCell'):
            containers = [dict(role='AXTextArea', box=by_id[p['node']].get('frame'),
                               source='AX child tree / AXTextArea frame')]
        else:
            for c in chains:
                if not c:
                    continue
                leaf = c[0]
                if 'ownershipParentFrames' in leaf:
                    # Actual AXParent path was validated against controlTextOwner
                    # by the collector; no geometry/name-based cross-run matching.
                    parent = next((n for n in leaf['ownershipParentFrames'] if n['role'] == 'AXGroup'), None)
                    if parent:
                        containers.append(dict(role=parent['role'], box=parent['frame'],
                                               source='AXParent ownership path / cached AXFrame'))
                else:
                    for n in c[1:]:
                        if n['id'] == cell['id'] or n['role'] in ('AXButton', 'AXPopUpButton', 'AXRadioButton'):
                            break
                        if n['role'] == 'AXGroup':
                            containers.append(dict(role=n['role'], box=n.get('frame'),
                                                   source='AX child tree / group frame'))
                            break
        unique = {}
        for item in containers:
            b = item.get('box')
            if b and b.get('width', 0) > 1 and b.get('height', 0) > 1:
                unique[(item['role'], tuple(b[k] for k in ('x', 'y', 'width', 'height')))] = item
        observed = list(unique.values())
        record = dict(node=p['node'], scope='table' if cell else 'text',
                      cellNode=cell['id'] if cell else None, cellBox=cell.get('frame') if cell else None,
                      containers=observed, status='observed' if len(observed) == 1 else 'ambiguous' if observed else 'unavailable')
        record['reason'] = ('문단 박스로 채택됨' if p.get('resolvedTextArea') else '컨테이너 관측 · 안전성 미판정 또는 채택되지 않음') if len(observed) == 1 else (
            '부모 영역이 여러 개임 · 확장 보류' if observed else '유효한 중간 텍스트 영역 미확인 · 셀 전체를 대신 사용하지 않음')
        result.append(record)
    return result


def rendered_layout_boxes(folder, metadata):
    """Actual product layout, converted from image pixels to screen-top-left pt."""
    path = folder/'render-layout.json'
    image = folder/'render-source.png'
    region = metadata.get('selectionRegion')
    if not path.exists() or not image.exists() or not region or metadata.get('renderFrameID') is None or metadata.get('renderFrameID') != metadata.get('frameID'):
        return []
    width, height = struct.unpack('>II', image.read_bytes()[16:24])
    result = []
    for d in json.loads(path.read_text()):
        if d.get('status') != 'rendered':
            continue
        for index, ((x, y), (w, h)) in enumerate(d.get('lineBoxes', [])):
            result.append(dict(node=d['node'], segment=d.get('segment'), logicalIndex=d.get('logicalIndex'), line=index,
                               box=dict(x=region['x']+x*region['width']/width,
                                        y=region['y']+(height-y-h)*region['height']/height,
                                        width=w*region['width']/width, height=h*region['height']/height)))
    return result


def image_ocr_review(folder, metadata):
    review = ''
    image_path = folder/'image-ocr.json'
    image_ocr = json.loads(image_path.read_text()) if image_path.exists() else []
    if metadata.get('imageRegions'):
        review += '<details open><summary>이미지 영역 · OCR</summary><p>청록색: AX 이미지 박스, 보라색: 실제 캡처 영역, 노란색: OCR 박스. 캡션은 기존 AX 텍스트로 처리합니다.</p>'
        if (folder/'render-source.png').exists():
            iw, ih = struct.unpack('>II', (folder/'render-source.png').read_bytes()[16:24])
            review += '<div style="position:relative"><img src="render-source.png" style="width:100%;display:block">'
            def overlay(x, y, w, h, color, title):
                return f'<span title="{html.escape(title, quote=True)}" style="position:absolute;box-sizing:border-box;border:2px solid {color};left:{x/iw*100}%;top:{(ih-y-h)/ih*100}%;width:{w/iw*100}%;height:{h/ih*100}%"></span>'
            selection = metadata.get('selectionRegion')
            if selection and selection['width'] > 0 and selection['height'] > 0:
                for region in metadata['imageRegions']:
                    b = region.get('box')
                    if region.get('status') == 'selected' and b:
                        x = (b['x']-selection['x'])*iw/selection['width']
                        y = ih-(b['y']+b['height']-selection['y'])*ih/selection['height']
                        review += overlay(x,y,b['width']*iw/selection['width'],b['height']*ih/selection['height'],'#00cccc',f"AX 이미지 {region['node']}")
            for d in image_ocr:
                (x,y),(w,h) = d['pixelBox']
                review += overlay(x,y,w,h,'#d080ff',f"이미지 {d['node']} · {d['status']}")
                for line in d.get('lines',[]):
                    (lx,ly),(lw,lh) = line['box']
                    review += overlay(x+lx*w,y+ly*h,lw*w,lh*h,'#ffe060',line['source'])
            review += '</div>'
        samples = metadata.get('translationSamples', [])
        if samples:
            review += '<details><summary>병렬 처리 · 화면 표시 시점</summary><pre>'+html.escape(json.dumps(samples,ensure_ascii=False,indent=2))+'</pre></details>'
        for d in image_ocr:
            review += '<details><summary>'+html.escape(f"이미지 {d['node']} · {d['status']} · OCR {d['ocrSeconds']:.3f}s · 번역 {d['translationSeconds']:.3f}s · 재사용 {d['cacheHit']}")+'</summary>'
            for line in d.get('lines',[]):
                review += '<p>원문</p><pre>'+html.escape(line['source'])+'</pre><p>번역문</p><pre>'+html.escape(line.get('translation') or '번역 결과 없음 · 원문 유지')+'</pre>'
            review += '<pre>'+html.escape(d.get('error') or '')+'</pre></details>'
        review += '<details><summary>이미지 선택·제외 및 OCR 진단</summary><pre>'+html.escape(json.dumps({'regions':metadata['imageRegions'],'ocr':image_ocr},ensure_ascii=False,indent=2))+'</pre></details></details>'
    return review


def render(folder):
    folder = Path(folder).resolve()
    root = Path(__file__).resolve().parents[1]
    nodes = json.loads((folder/'rawAx.json').read_text())
    selected = json.loads((folder/'candidate.json').read_text())
    metadata = json.loads((folder/'metadata.json').read_text())
    run_id = metadata['runId']
    run = json.loads((root/'runs'/run_id/'result.json').read_text())
    native = folder/'native-paragraphs.json'
    if native.exists():
        built = json.loads(native.read_text())
        paragraphs, unresolved = built['units'], built['unresolved']
    else:
        paragraphs, unresolved = build_paragraphs(nodes, selected)
    cache_path = root/'evaluations/paragraph-translations-ko.json'
    cache = json.loads(cache_path.read_text()) if cache_path.exists() else {}
    translations = {entry_cache_key(e): e for e in cache.get('entries', [])} if cache.get('policyId') == translation_policy_id(root) else {}
    if metadata.get("skipTranslation"):
        translations = {}
    native_translations = folder/'native-translations.json'
    app_results = metadata.get('translationSource') == 'rearview-session'
    native_entries = {}
    if app_results and native_translations.exists() and not metadata.get('skipTranslation'):
        exported = json.loads(native_translations.read_text())
        if exported.get('frameID') != metadata.get('frameID'):
            raise ValueError('AX translation frame mismatch')
        native_entries = {e['node']: e for e in exported['entries']}
    for unit in paragraphs:
        if app_results:
            entry = native_entries.get(unit['node'])
            unit['translationResult'] = entry if entry and (entry['source'] == unit.get('translationSourceText', unit['text']) or entry['status'] == 'source_unavailable') else {'status': 'not_translated'}
        else:
            unit['translationResult'] = translations.get(entry_cache_key(translation_request(unit)), {'status': 'not_translated', 'targetLanguage': 'ko'})
    data = {'run': run_id, 'evaluation': folder.name, 'scenario': run['scenarioId'],
            'fixture': run['fixtureId'], 'nodes': nodes, 'selected': selected,
            'paragraphs': paragraphs, 'unresolved': unresolved, 'frame': metadata.get('windowFrame', run['screenshot']['frame']),
            'coverageLimitations': metadata.get('coverageLimitations', []), 'collection': metadata}
    data['selectionRegion'] = next((c['selectionRegion'] for c in selected if c.get('selectionRegion')), None)
    data['tableContainerStudy'] = table_container_study(nodes, paragraphs)
    data['layoutBoxes'] = rendered_layout_boxes(folder, metadata)
    if (folder/'render-source.png').exists() and metadata.get('renderFrameID') is not None and metadata.get('renderFrameID') == metadata.get('frameID') and metadata.get('selectionRegion'):
        data['containerStudyCapture'] = dict(image='render-source.png', frame=metadata['selectionRegion'], frameID=metadata['frameID'])
    encoded = base64.b64encode(json.dumps(data, ensure_ascii=False).encode()).decode()
    template = Path(__file__).with_name('ax_report.html').read_text()
    page = template.replace('__PAYLOAD__', encoded).replace('__SCENARIO__', html.escape(data['scenario']))
    if (folder/'render-translated.png').exists():
        if metadata.get('renderFrameID') != metadata.get('frameID'):
            raise ValueError('AX rendering frame mismatch')
        review = '<details open style="background:#20252d;color:white;padding:12px"><summary>Rearview 실제 렌더링 · 같은 캡처 프레임</summary><p>아래 기존 AX 관측 화면은 별도 시점입니다.</p>'
        for label, name in [('원본','render-source.png'),('번역','render-translated.png')]:
            review += f"<button onclick=\"document.getElementById('axRenderImage').src='{name}'\">{label}</button> "
        review += "<button onclick=\"document.getElementById('axRenderDebug').hidden=!document.getElementById('axRenderDebug').hidden\">진단 경계</button>"
        review += '<p>진단 경계: 분홍색은 원본 라인, 청록색은 번역 배치 영역, 주황색은 표시 clip입니다.</p>'
        review += '<div style="position:relative"><img id="axRenderImage" style="display:block;width:100%" src="render-translated.png"><img id="axRenderDebug" hidden style="position:absolute;inset:0;width:100%;pointer-events:none" src="render-debug.png"></div>'
        diagnostics = json.loads((folder/'render-layout.json').read_text())
        review += '<details><summary>문단별 배치·압축·clip 상세</summary><table><tr><th>문단/구간</th><th>상태</th><th>폰트</th><th>공통 압축</th><th>라인 추가 압축</th><th>clip</th><th>배경 RGB</th><th>전경 RGB</th><th>전경 선택</th><th>명암비</th></tr>'
        for d in diagnostics:
            review += '<tr>'+''.join('<td>'+html.escape(str(v))+'</td>' for v in [str(d['node'])+'/'+str(d.get('segment','')),d['status'],round(d['fontSize'],2),round(d['commonScale'],3),[round(x,3) for x in d['lineScales']],d['clipped'],d.get('backgroundColor'),d.get('foregroundColor'),d.get('foregroundSource'),round(d['foregroundContrast'],2) if d.get('foregroundContrast') is not None else None])+'</tr>'
        review += '</table><a href="render-layout.json">배치 데이터</a></details>'
        source_png = folder/'render-source.png'
        if source_png.exists():
            image_width, image_height = struct.unpack('>II', source_png.read_bytes()[16:24])
            review += '<details><summary>문단별 실제 렌더링 확대 (2배)</summary>'
            for d in diagnostics:
                (x, y), (width, height) = d['box']
                left, top = max(0, x), max(0, image_height-y-height)
                right, bottom = min(image_width, x+width), min(image_height, image_height-y)
                if right <= left or bottom <= top:
                    continue
                review += f'<details><summary>{d["node"]}/{d.get("segment", "")} · {html.escape(d["status"])}</summary><div style="max-width:100%;overflow:auto"><div style="position:relative;overflow:hidden;width:{(right-left)*2}px;height:{(bottom-top)*2}px"><img loading="lazy" src="render-translated.png" style="position:absolute;max-width:none;width:{image_width*2}px;height:{image_height*2}px;left:{-left*2}px;top:{-top*2}px"></div></div></details>'
            review += '</details>'
        review += image_ocr_review(folder, metadata)
        review += '</details>'
        page = page.replace('</style>', '</style>'+review, 1)
    (folder/'index.html').write_text(page)
    (folder/'paragraphs.json').write_text(json.dumps({'policy':'all selected inputs covered by native text areas, control labels or atomic selected text; no source concatenation', 'units':paragraphs,'unresolved':unresolved},ensure_ascii=False,indent=2))
    return {'report':str(folder/'index.html'),'paragraphs':len(paragraphs),'unresolved':len(unresolved)}


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('folder',type=Path)
    args=parser.parse_args()
    print(json.dumps(render(args.folder)))

if __name__=='__main__':main()
