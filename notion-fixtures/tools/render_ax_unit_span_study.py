"""Issue-only previews using measured native text spans, with the fixed report template."""
import json,shutil,math
from pathlib import Path
from render_ax_report import render
root=Path(__file__).resolve().parents[1];out=root/'evaluations/unit-span-study-20261112';rows=json.loads((out/'summary.json').read_text());findings=[]
for row in rows:
 folder=Path(row['probe']).parent;study=json.loads(Path(row['probe']).read_text());raw=json.loads((folder/'rawAx.json').read_text());changed=[]
 for unit in study['units']:
  if 'probes' not in unit:continue
  probes={p['label']:p for p in unit['probes']};whole=probes.get('unit-whole',{});span=probes.get('leaf-span',{});reverse=probes.get('reverse-from-last-leaf',{})
  source=unit['text'];line=reverse.get('text');b=span.get('box');valid=span.get('text')==source and b and all(math.isfinite(b[k]) for k in ('x','y','width','height')) and b['width']>0 and b['height']>0 and isinstance(line,str) and line.endswith(source)
  if whole.get('matchesLeaves') or not valid:continue
  # Both markers are real leaf anchors. The native reverse line covers the
  # source suffix, so restricting to the first leaf retains one native line.
  probe=dict(lineMethod='research-native-leaf-span-reverse',lineSourceText=source,lineRangeStatus='complete_unverified',sourceNodes=unit['sourceNodes'],coveredUTF16Length=len(source.encode('utf-16-le'))//2,totalUTF16Length=len(source.encode('utf-16-le'))//2,lineRanges=[dict(rangeStart=0,rangeLength=len(source.encode('utf-16-le'))//2,text=source,box=span['box'],boxKind='native_leaf_span_research',line=0)])
  raw[unit['node']]['paragraphLineInvestigation']=probe;changed.append(unit['node']);findings.append(dict(scenario=row['scenario'],node=unit['node'],source=source,whole=whole.get('text'),box=span['box']))
 dest=folder.parent/('research-leaf-span-'+row['scenario']);dest.mkdir(parents=True,exist_ok=True)
 for name in ['candidate.json','metadata.json','screen.png']:
  if (folder/name).exists():shutil.copy2(folder/name,dest/name)
 (dest/'rawAx.json').write_text(json.dumps(raw,ensure_ascii=False,indent=2));m=json.loads((dest/'metadata.json').read_text());m['researchOnly']='native-leaf-span';(dest/'metadata.json').write_text(json.dumps(m,ensure_ascii=False,indent=2));render(dest)
 row['researchPreview']='../'+str(dest.relative_to(root/'evaluations')/'index.html');row['changedUnits']=changed
(out/'findings.json').write_text(json.dumps(findings,ensure_ascii=False,indent=2));(out/'preview-summary.json').write_text(json.dumps(rows,ensure_ascii=False,indent=2));print(json.dumps(findings,ensure_ascii=False))
