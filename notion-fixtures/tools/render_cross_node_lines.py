#!/usr/bin/env python3
"""Render the issue-specific native AX line investigation; never replace the suite index."""
import argparse
import json
import os
from pathlib import Path


def render(manifest_path):
    manifest = json.loads(manifest_path.read_text())
    output = manifest_path.parent / 'index.html'
    cases = []
    for entry in manifest['cases']:
        probe = manifest_path.parent / entry['probe']
        report = (manifest_path.parent / entry['report']).resolve()
        raw = json.loads((report.parent / 'rawAx.json').read_text())
        window = next(n['frame'] for n in raw if n['role'] == 'AXWindow')
        data = json.loads(probe.read_text())
        paragraphs = json.loads((report.parent / 'paragraphs.json').read_text())['units']
        raw_by_id = {n['id']: n for n in raw}
        selected = []
        for unit in data['results']:
            matches = [p['node'] for p in paragraphs
                       if p['text'] == unit['text'] and
                       raw_by_id.get(p['node'], {}).get('frame') == unit['frame']]
            if matches:
                selected.append(dict(unit, reportParagraphs=matches))
        # The probe deliberately observes offscreen ancestors too. Display only
        # units matched by exact source AND native frame to the standard report.
        data['observedUnitCount'] = len(data['results'])
        data['results'] = selected
        case = dict(entry, data=data, window=window)
        case['image'] = os.path.relpath(report.parent / 'screen.png', output.parent)
        cases.append(case)
    payload = json.dumps(cases, ensure_ascii=False).replace('<', '\\u003c')
    html = '''<!doctype html><html lang="ko"><meta charset="utf-8"><title>AX 줄 범위 조사</title>
<style>body{margin:24px;background:#181818;color:#eee;font:14px system-ui}button,select,a{font:inherit;margin:4px;color:inherit}button,select{background:#333}a{color:#8ccaff}.layout{display:flex;gap:20px;align-items:flex-start}.screen{position:relative;flex-shrink:0}.screen img{display:block;width:100%;height:100%}.box{position:absolute;border:1px solid #ff6d6d;box-sizing:border-box;cursor:pointer}.label{position:absolute;background:#ffffffad;color:#111;font:10px system-ui;top:0;left:0}.list{max-height:720px;overflow:auto;min-width:320px;max-width:480px}pre{white-space:pre-wrap}button.item{display:block;text-align:left;width:95%;padding:8px}#info{white-space:pre-wrap}summary{cursor:pointer}</style>
<h1>AX가 반환한 줄 범위·박스 조사</h1>
<p>좌표 병합 없이 조회한 조사 후보입니다. 기본 추출기의 최종 선택이나 모든 경우의 성공을 뜻하지 않습니다.</p><p>한계: 수식·인라인 위젯은 화면 한 줄이어도 AX가 여러 줄로 취급할 수 있습니다. 박스가 있다는 것과 시각적 줄 전체를 확보했다는 것은 다릅니다.</p>
<select id="case"></select><select id="mode"><option value="rebased">텍스트 노드 marker로 조회한 박스</option><option value="native">문단 marker로 조회한 박스</option><option value="none">원본 화면</option></select>
<a id="standard">고정 양식 보고서</a><p id="status"></p>
<div class="layout"><div id="screen" class="screen"><img id="image"></div><div class="list"><div id="info">박스나 항목을 클릭하면 AX 문자열과 조회 정보를 표시합니다.</div><div id="list"></div></div></div>
<script>const cases=PAYLOAD;
const pick=document.getElementById('case'),mode=document.getElementById('mode'),screen=document.getElementById('screen'),list=document.getElementById('list');
cases.forEach((c,i)=>{let o=document.createElement('option');o.value=i;o.textContent=c.scenario;pick.append(o)});
function draw(){const c=cases[+pick.value];document.getElementById('image').src=c.image;document.getElementById('standard').href=c.report;screen.style.width=c.window.width+'px';screen.style.height=c.window.height+'px';screen.querySelectorAll('.box').forEach(x=>x.remove());list.replaceChildren();let shown=0,missing=0;
for(const p of c.data.results){if(!p.lines)continue;const whole=(p.wholeUnitNativeLineCandidates||[]).filter(x=>x.plausibleWithinParagraph);const useWhole=mode.value!=='native'&&whole.length>0;const lines=useWhole?whole:p.lines;
lines.forEach((l,i)=>{const box=mode.value==='native'?l.nativeBox:l.box;const glyphless=/^[\\s\\u200b]*$/.test(l.text);if(!box||box.width<=0||box.height<=0){if(!glyphless)missing++;return}if(box.y+box.height<c.window.y||box.y>c.window.y+c.window.height)return;
let key='P'+p.reportParagraphs.join(',')+' / '+i;const show=()=>{document.getElementById('info').textContent=key+'\\n원문: '+l.text+'\\n'+(useWhole?'AX 이전 줄 시작 + 다음 줄 끝이 번역 단위 전체를 반환함':'문단 AXNextLineEnd 경계')+'\\n박스: '+JSON.stringify(box)+'\\n';let d=document.createElement('details'),s=document.createElement('summary'),pre=document.createElement('pre');s.textContent='AX 조사 데이터';pre.textContent=JSON.stringify({paragraph:p.text,nativeText:p.nativeText,line:l},null,2);d.append(s,pre);document.getElementById('info').append(d)};
let item=document.createElement('button');item.className='item';item.textContent=key+' '+l.text;item.onclick=show;list.append(item);
if(mode.value!=='none'){let b=document.createElement('div');b.className='box';Object.assign(b.style,{left:(box.x-c.window.x)+'px',top:(box.y-c.window.y)+'px',width:box.width+'px',height:box.height+'px'});let label=document.createElement('span');label.className='label';label.textContent=key;b.append(label);b.onclick=show;screen.append(b)}shown++})}
document.getElementById('status').textContent='표시한 범위 '+shown+'개 · 박스 미확보(공백·줄바꿈 제외) '+missing+'개. 원본 AX 줄 박스는 자르지 않았습니다. P 번호는 고정 양식 보고서의 문단 번호입니다. 해당 보고서에서 선택된 원문·원본 프레임과 정확히 일치한 단위만 표시합니다.'}
pick.onchange=mode.onchange=draw;draw();</script></html>'''.replace('PAYLOAD', payload)
    output.write_text(html)
    return output


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('manifest', type=Path)
    print(render(parser.parse_args().manifest))
