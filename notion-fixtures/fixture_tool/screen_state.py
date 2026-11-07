"""Version two screen state validation; no Notion or native UI access."""
import math
import re
from .definitions import FixtureError

FIELDS = {'presentation', 'sidebar', 'scrolls', 'tabs', 'databaseView', 'blockDisplays', 'captureRegion', 'overlay'}
SCOPES = {'main', 'preview', 'database', 'code', 'table', 'sidebar'}


def capture_candidates(definition, scope='main'):
    """Source-authored controls only; candidates are not observations."""
    content = getattr(definition, 'content', '')
    tabs, displays = [], []
    for group in re.finditer(r'<tabs>\s*(.*?)</tabs>', content, re.S):
        headings = re.findall(r'^#{1,6} (.+)$', content[:group.start()], re.M)
        if not headings:
            continue
        for tab in re.finditer(r'<tab(?: [^>]*)?>\s*(.*?)</tab>', group.group(1), re.S):
            paragraphs = [p.strip() for p in tab.group(1).split('\n\n') if p.strip()]
            if len(paragraphs) >= 2:
                tabs.append(dict(scope=scope, anchor={'text': headings[-1]},
                                 selectedText=paragraphs[0], contentAnchor={'text': paragraphs[1]}))
    for code in re.finditer(r'```mermaid\n.*?\n```', content, re.S):
        headings = re.findall(r'^#{1,6} (.+)$', content[:code.start()], re.M)
        if headings:
            displays.append(dict(scope=scope,anchor={'text':headings[-1]},mode='source'))
    return tabs, displays


def need(condition, message):
    if not condition:
        raise FixtureError(message)


def number(value, low, high):
    return type(value) in (int, float) and math.isfinite(value) and low <= value <= high


def anchor(value):
    need(isinstance(value, dict) and not set(value) - {'text', 'blockClass', 'ancestorText'}
         and isinstance(value.get('text'), str) and bool(value['text'].strip())
         and all(isinstance(v, str) and v for v in value.values()), 'Invalid screen anchor')


def required_items(state):
    items = set()
    for field in ('presentation', 'sidebar', 'databaseView', 'captureRegion', 'overlay'):
        if field in state:
            items.add(field)
    if state.get('overlay',{}).get('kind') == 'menu':
        items.add('backgroundState')
    if state.get('presentation',{}).get('mode') == 'center':
        items.add('backgroundState')
    for field, prefix in [('scrolls', 'scroll'), ('tabs', 'tab'), ('blockDisplays', 'blockDisplay')]:
        items.update(f'{prefix}.{i}' for i in range(len(state.get(field, []))))
    return items


def validate(value):
    state = value['state']
    versions = value.get('fixtureVersions')
    need(isinstance(versions, dict) and versions.get(value['fixtureId']) == value['fixtureVersion'],
         'v2 fixtureVersions must pin the host Fixture')
    need(all(isinstance(k, str) and re.fullmatch(r'[a-z0-9][a-z0-9-]{0,79}', k)
             and isinstance(v, str) and re.fullmatch(r'[0-9a-f]{64}', v) for k, v in versions.items()),
         'Invalid participating Fixture versions')
    if 'presentation' in state:
        p = state['presentation']
        need(isinstance(p, dict) and not set(p) - {'mode', 'fixtureId', 'rowIndex', 'widthFraction'}
             and p.get('mode') in ('none', 'side', 'center', 'full'), 'Invalid presentation')
        if p['mode'] != 'none':
            need(isinstance(p.get('fixtureId'), str) and p['fixtureId'] in versions, 'Preview Fixture must be pinned')
        else:
            need(set(p) == {'mode'}, 'Closed preview accepts no target')
        if 'rowIndex' in p:
            need(type(p['rowIndex']) is int and p['rowIndex'] >= 0 and p.get('fixtureId') == value['fixtureId'],
                 'rowIndex is a zero-based host database record reference')
        if 'widthFraction' in p:
            need(p['mode'] == 'side' and number(p['widthFraction'], .2, .8), 'Invalid side peek width')
    if 'sidebar' in state:
        p = state['sidebar']
        need('sidebarOpen' not in state and isinstance(p, dict) and not set(p) - {'mode', 'width'}
             and p.get('mode') in ('closed', 'pinned', 'floating'), 'Invalid sidebar state')
        if 'width' in p:
            need(p['mode'] != 'closed' and number(p['width'], 160, 600), 'Invalid sidebar width')
    for field in ('scrolls', 'tabs', 'blockDisplays'):
        need(isinstance(state.get(field, []), list), field + ' must be an array')
    seen = set()
    for p in state.get('scrolls', []):
        need(isinstance(p, dict) and not set(p) - {'scope', 'container', 'axis', 'mode', 'anchor', 'offset', 'rangeLocation', 'rangeLength', 'advancePixels'}
             and p.get('scope') in SCOPES and p.get('axis') in ('x', 'y')
             and p.get('mode') in ('start', 'end', 'anchor'), 'Invalid scoped scroll')
        key = (p['scope'], p['axis'], str(p.get('container')))
        need(key not in seen, 'Duplicate scroll request for one container and axis')
        seen.add(key)
        if 'container' in p:
            anchor(p['container'])
        if p['mode'] == 'anchor':
            anchor(p.get('anchor'))
            need(number(p.get('offset'), -10000, 10000), 'Anchor scroll needs a finite offset')
        else:
            need(not set(p) & {'anchor', 'offset', 'rangeLocation', 'rangeLength'}, 'Boundary scroll accepts no text range')
        if set(p) & {'rangeLocation', 'rangeLength'}:
            need(type(p.get('rangeLocation')) is int and type(p.get('rangeLength')) is int
                 and p['rangeLocation'] >= 0 and p['rangeLength'] > 0
                 and p['rangeLocation'] + p['rangeLength'] <= len(p['anchor']['text'].encode('utf-16-le')) // 2,
                 'Scroll range must fit anchor UTF-16 text')
        if 'advancePixels' in p:
            need(type(p['advancePixels']) is int and 0 < p['advancePixels'] <= 10000
                 and 'window' in state and not set(p) & {'rangeLocation','rangeLength'}
                 and (p['mode']=='anchor' or (p['scope']=='code' and p['mode']=='start')),
                 'Pixel advance needs a fixed window and a verified anchor or code start boundary')
    for p in state.get('tabs', []):
        need(isinstance(p, dict) and set(p) == {'scope', 'anchor', 'selectedText', 'contentAnchor'}
             and p['scope'] in ('main', 'preview') and isinstance(p['selectedText'], str) and bool(p['selectedText']), 'Invalid tab')
        anchor(p['anchor']); anchor(p['contentAnchor'])
    for p in state.get('blockDisplays', []):
        need(isinstance(p, dict) and set(p) == {'scope', 'anchor', 'mode'}
             and p['scope'] in ('main', 'preview') and p['mode'] in ('source', 'diagram'), 'Invalid block display')
        anchor(p['anchor'])
    if 'databaseView' in state:
        need(isinstance(state['databaseView'], str) and bool(state['databaseView']), 'databaseView needs a name')
    if 'captureRegion' in state:
        p = state['captureRegion']
        need(isinstance(p, dict) and not set(p) - {'rect', 'scope', 'anchor', 'cutEdge', 'fraction', 'target'}, 'Invalid capture region')
        need('target' not in p or (p['target'] == 'followingImage' and 'anchor' in p), 'Image region needs an anchor')
        if 'rect' in p:
            r = p['rect']
            need(set(p) == {'rect'} and isinstance(r, dict) and set(r) == {'x', 'y', 'width', 'height'}
                 and all(number(v, 0, 100000) for v in r.values()) and r['width'] > 0 and r['height'] > 0,
                 'Region rect must be window-relative positive points')
            w = state.get('window')
            if w:
                need(r['x'] + r['width'] <= w['width'] and r['y'] + r['height'] <= w['height'], 'Region exceeds window')
        else:
            need(p.get('scope') in SCOPES, 'Region needs a scope or rect')
            if 'anchor' in p:
                anchor(p['anchor'])
                need(p.get('cutEdge') in ('left', 'right', 'top', 'bottom')
                     and number(p.get('fraction', .5), .01, .99), 'Anchor region needs a cut edge and fraction')
            else:
                need(set(p) == {'scope'}, 'Viewport region accepts only scope')
    if 'overlay' in state:
        p = state['overlay']
        need(isinstance(p, dict) and {'kind','text'} <= set(p) <= {'kind','text','expectedText'} and p['kind'] in ('menu', 'tooltip')
             and isinstance(p['text'], str) and bool(p['text']), 'Invalid overlay')
        need('expectedText' not in p or (isinstance(p['expectedText'],str) and bool(p['expectedText'].strip())), 'Invalid overlay expected text')
    need(required_items(state) <= set(state['required']), 'Every v2 screen condition must be required')
