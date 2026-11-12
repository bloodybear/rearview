"""Research hypothesis only: classify timeline labels against the pinned list frame.
Never infer generic paint order from AX child order. No product filter is installed.
"""
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
data = json.loads(path.read_text())
nodes = {n['id']: n for n in data['nodes']}
def value(n, key, default=None):
    return n.get(key, {}).get('value', default)
def classes(n):
    return value(n, 'AXDOMClassList', [])
def ancestors(n):
    while 'parent' in n:
        n = nodes[n['parent']]
        yield n
def frame(n):
    p, s = value(n, 'AXPosition', {}), value(n, 'AXSize', {})
    return [p.get('x', 0), p.get('y', 0), s.get('width', 0), s.get('height', 0)]
def contains(a, b):
    return a[0] <= b[0] and a[1] <= b[1] and a[0]+a[2] >= b[0]+b[2] and a[1]+a[3] >= b[1]+b[3]
def overlaps(a, b):
    return max(a[0], b[0]) < min(a[0]+a[2], b[0]+b[2]) and max(a[1], b[1]) < min(a[1]+a[3], b[1]+b[3])
results=[]
for timeline in nodes.values():
    if 'notion-timeline-view' not in classes(timeline):
        continue
    descendants=[n for n in nodes.values() if any(a['id']==timeline['id'] for a in ancestors(n))]
    # Candidate panel: common collection block wrapping collection-item list rows.
    # This is a Notion-specific structural assumption, not an AX occlusion property.
    panels={}
    for row in descendants:
        if 'notion-collection-item' in classes(row):
            panel=next((a for a in ancestors(row) if 'notion-collection_view-block' in classes(a)), None)
            if panel:
                panels[panel['id']]=panel
    if len(panels)!=1:
        results.append({'timeline':timeline['id'],'status':'ambiguous_panel','panels':list(panels)})
        continue
    panel=next(iter(panels.values())); pf=frame(panel)
    for n in descendants:
        if value(n,'AXRole')!='AXStaticText' or not value(n,'AXValue'):
            continue
        if not any('notion-timeline-item-properties' in classes(a) or 'notion-timeline-item' in classes(a) for a in ancestors(n)):
            continue
        f=frame(n)
        if f[2]<=1 or f[3]<=1:
            continue
        results.append({'timeline':timeline['id'],'panel':panel['id'],'panelFrame':pf,'node':n['id'],'text':value(n,'AXValue'),'frame':f,'hypothesis':'fully_covered' if contains(pf,f) else 'partially_covered' if overlaps(pf,f) else 'outside_panel'})
output=path.with_name(path.stem+'-hypothesis.json')
output.write_text(json.dumps({'source':str(path),'truncated':data['truncated'],'researchOnly':True,'results':results},ensure_ascii=False,indent=2)+'\n')
from collections import Counter
print(output,dict(Counter(r.get('hypothesis',r.get('status')) for r in results)))
