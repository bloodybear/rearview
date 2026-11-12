#!/usr/bin/env python3
"""Translate native report units locally and persist exact-source Korean results."""
import argparse
from collections import Counter
import json
from pathlib import Path
import subprocess
import tempfile
from render_ax_report import render, translation_policy_id, translation_sources, entry_cache_key, translation_request


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('folders',nargs='*',type=Path)
    parser.add_argument('--all-rendered',action='store_true')
    args=parser.parse_args()
    root=Path(__file__).resolve().parents[1]
    folders=args.folders
    if args.all_rendered:
        folders+=sorted(p.parent for p in (root/'evaluations').glob('*/*/paragraphs.json'))
    folders=list(dict.fromkeys(p.resolve() for p in folders))
    if not folders:parser.error('No report folders selected')
    cache_path=root/'evaluations/paragraph-translations-ko.json'
    cache=json.loads(cache_path.read_text()) if cache_path.exists() else {'targetLanguage':'ko','entries':[]}
    shared_sources=translation_sources(root)
    policy_id=translation_policy_id(root)
    # Old report-only auto-detection/ASCII results are not product evidence.
    cached={entry_cache_key(e):e for e in cache['entries']} if cache.get('policyId')==policy_id else {}
    # Refresh context for older reports before preparing per-paragraph requests.
    for folder in folders:
        render(folder)
    sources={}
    for folder in folders:
        for unit in json.loads((folder/'paragraphs.json').read_text())['units']:
            request = translation_request(unit)
            sources[entry_cache_key(request)] = request
    pending=[request for key, request in sources.items() if cached.get(key,{}).get('status') not in {'translated','preserved_by_policy','skipped_non_source_language'}]
    if pending:
        binary=root.parent/'.build/ax-report-translation'
        if not binary.exists() or any(binary.stat().st_mtime<p.stat().st_mtime for p in shared_sources):
            # Reuse the existing debug module/objects read-only; exclude the app's
            # main entry point. This builds a separate report CLI without editing
            # or launching Rearview or duplicating its translation implementation.
            subprocess.run(['swift', 'build', '--product', 'Rearview'], cwd=root.parent, check=True)
            debug = root.parent/'.build/debug'
            objects = sorted(p for p in (debug/'Rearview.build').glob('*.o') if p.name != 'main.swift.o')
            if not objects:
                raise RuntimeError('Production translation objects unavailable')
            subprocess.run(['swiftc', '-parse-as-library', '-swift-version', '6',
                '-module-name', 'AXReportTranslationCLI', '-I', str(debug/'Modules'),
                '-F', str(debug), '-framework', 'Sparkle', '-Xlinker', '-rpath',
                '-Xlinker', str(debug.resolve()), '-o', str(binary),
                str(root/'tools/ax_report_translation.swift'), str(root.parent/'Sources/NotionAXEvaluation/MathTranslationPolicy.swift')] + [str(p) for p in objects],
                cwd=root.parent, check=True)
        with tempfile.TemporaryDirectory(prefix='ax-report-translation-') as tmp:
            input_path=Path(tmp)/'input.json';output_path=Path(tmp)/'output.json'
            input_path.write_text(json.dumps(pending,ensure_ascii=False))
            # Preserve completed work even if a later engine request fails.
            try:
                subprocess.run([str(binary),'--translate-ax-report',str(input_path),str(output_path)],check=True,timeout=600)
            finally:
                if output_path.exists():
                    cached.update({entry_cache_key(e):e for e in json.loads(output_path.read_text())['entries']})
                    cache_path.write_text(json.dumps({'targetLanguage':'ko','sourceLanguage':'ja','protectionPolicy':'code-block-only','policyId':policy_id,'entries':list(cached.values())},ensure_ascii=False,indent=2))
    for folder in folders:render(folder)
    counts=Counter(cached.get(s,{}).get('status','missing') for s in sources)
    print(json.dumps({'reports':len(folders),'uniqueSources':len({r['source'] for r in sources.values()}),'uniqueRequests':len(sources),'statuses':dict(counts)},ensure_ascii=False))
    if any(status not in {'translated','preserved_by_policy','skipped_non_source_language'} and count for status,count in counts.items()):
        raise SystemExit(2)

if __name__=='__main__':main()
