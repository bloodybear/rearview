"""Verify persisted reverse-line artifacts, without live AX or screenshot inference."""
import argparse,json,collections,math
from pathlib import Path
from run_ax_prototype import validate_collection

def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('batch',type=Path);args=parser.parse_args()
    root=Path(__file__).resolve().parents[1];batch=args.batch.resolve();summary=json.loads((batch/'summary.json').read_text())
    counts=collections.Counter();statuses=collections.Counter();methods=collections.Counter();partial=[];checked=[]
    for row in summary['results']:
        if row['status']!='ok':continue
        folder=root/'evaluations'/Path(row['report']).parent
        raw=json.loads((folder/'rawAx.json').read_text());selected=json.loads((folder/'candidate.json').read_text());units=json.loads((folder/'paragraphs.json').read_text())['units'];meta=json.loads((folder/'metadata.json').read_text())
        assert meta['lineMethod']=='native-paragraph-reverse-with-markers-local-reverse-single-node'
        assert meta['targetAndFrameMatch'] and not meta['truncated']
        validate_collection(folder,selected)
        for unit in units:
            node=raw[unit['node']];probe=node['paragraphLineInvestigation'];method=probe['lineMethod'];status=probe['lineRangeStatus'];methods[method]+=1;statuses[status]+=1
            assert method in {'markers-local-reverse-single-node','native-paragraph-markers-reverse','sidebar-title-full-range','unavailable','math-segmented-native'}
            source=probe.get('lineSourceText','').encode('utf-16-le');observation=node['rangeInvestigations'][0];lines=observation.get('lineRanges',[]);end=0;covered=0;keys={}
            for line in lines:
                start,length=line['rangeStart'],line['rangeLength'];assert length>0 and start>=end
                assert source[2*start:2*(start+length)].decode('utf-16-le')==line['text'];end=start+length;covered+=length
                box=line['box'];assert all(math.isfinite(box[k]) for k in ('x','y','width','height')) and box['width']>0 and box['height']>0
                keys[(start,length,line['text'])]=box
            if status=='complete_unverified':
                assert covered==len(source)//2==probe['coveredUTF16Length']
                assert ''.join(l['text'] for l in lines).encode('utf-16-le')==source
            for line in unit.get('lineRanges',[]):
                assert keys[(line['rangeStart'],line['rangeLength'],line['text'])]==line['box'],'line geometry changed during clipping/rendering'
            counts['units']+=1;counts['complete']+=status=='complete_unverified';counts['visibleLineBoxes']+=len(unit.get('lineRanges',[]));counts['rawLineBoxes']+=len(lines)
            if status!='complete_unverified':partial.append(dict(scenario=row['scenario'],node=unit['node'],text=unit['text'],status=status,report=row['report']+'#paragraph='+str(unit['node'])))
        checked.append(row['scenario']);assert (folder/'index.html').is_file()
    result=dict(checkedScenarios=checked,counts=dict(counts),statuses=dict(statuses),methods=dict(methods),partial=partial,failedScenarios=[r['scenario'] for r in summary['results'] if r['status']!='ok'],scope='Integrity, source coverage, direction metadata and unchanged line geometry; not pixel visibility ground truth')
    (batch/'reverse-line-audit.json').write_text(json.dumps(result,ensure_ascii=False,indent=2));print(json.dumps({k:v for k,v in result.items() if k not in ('partial','checkedScenarios')},ensure_ascii=False));print('checked scenarios:',len(checked))
if __name__=='__main__':main()
