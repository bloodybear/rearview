import importlib.util
from pathlib import Path
import unittest

path = Path(__file__).resolve().parents[1]/'tools/render_ax_report.py'
spec = importlib.util.spec_from_file_location('report_translation_policy', path)
report = importlib.util.module_from_spec(spec)
spec.loader.exec_module(report)

class ReportTranslationPolicyTests(unittest.TestCase):
    def test_native_source_overrides_parent_and_legacy_reports_remain_readable(self):
        unit = dict(text='\nparent', translationSourceText='real\ntext', protectNonSourceText=False)
        self.assertEqual(report.translation_request(unit)['source'], 'real\ntext')
        del unit['translationSourceText']
        self.assertEqual(report.translation_request(unit)['source'], '\nparent')

    def test_same_source_in_code_and_prose_keeps_distinct_policy(self):
        frame = dict(x=10,y=10,width=100,height=20)
        nodes = [dict(id=0,role='AXGroup',domClasses=['notion-code-block']),
                 dict(id=1,parent=0,role='AXTextArea',value='日本語 English',frame=frame),
                 dict(id=2,parent=1,role='AXStaticText'),
                 dict(id=3,role='AXTextArea',value='日本語 English',frame=frame),
                 dict(id=4,parent=3,role='AXStaticText')]
        selected = [dict(node=i,text='日本語 English',box=frame,textSource='AXValue') for i in [2,4]]
        units,_ = report.build_paragraphs(nodes, selected)
        self.assertEqual([u['protectNonSourceText'] for u in units],[True,False])
        self.assertNotEqual(*[report.translation_cache_key(u['text'],u['protectNonSourceText']) for u in units])
        self.assertEqual(report.entry_cache_key(dict(source='x',protectNonSourceText='true')),
                         report.translation_cache_key('x',True))

    def test_recovered_text_keeps_native_source_and_code_context(self):
        frame = dict(x=10,y=10,width=100,height=20)
        nodes = [dict(id=0,role='AXGroup',domClasses=['notion-code-block']),
                 dict(id=1,parent=0,role='AXButton',title='Expand diagram',frame=frame),
                 dict(id=2,role='AXStaticText',controlTextOwner=1),
                 dict(id=3,role='AXStaticText',controlTextOwner=1)]
        selected = [dict(node=i,text=text,box=frame,textSource='AXValue',controlTextOwner=1)
                    for i,text in [(2,'開始'),(3,'終了')]]
        units,_ = report.build_paragraphs(nodes, selected)
        self.assertEqual([u['text'] for u in units],['開始','終了'])
        self.assertEqual([u['node'] for u in units],[2,3])
        self.assertTrue(all(u['protectNonSourceText'] for u in units))

    def test_math_parts_preserve_paragraph_and_have_isolated_cache_identity(self):
        frame = dict(x=10,y=10,width=100,height=20)
        parts = [dict(kind='text',id=0,text='合計は ',sourceNodes=[1]),
                 dict(kind='math',id=1,node=2,translationExcluded=True),
                 dict(kind='text',id=2,text=' です。',sourceNodes=[3])]
        probe = dict(inlineContent=parts,mathPolicy='math-placeholder-context-v1',lineRanges=[],
                     lineMethod='math-segmented-native',lineSourceText='合計は  です。',sourceNodes=[1,3])
        nodes = [dict(id=0,role='AXTextArea',value='合計は\n残額\nです。',frame=frame,paragraphLineInvestigation=probe),
                 dict(id=1,parent=0,role='AXStaticText'),dict(id=2,parent=0,role='AXGroup',mathOwner=2),
                 dict(id=3,parent=0,role='AXStaticText')]
        selected = [dict(node=i,text=t,box=frame,textSource='AXValue') for i,t in [(1,'合計は '),(3,' です。')]]
        units,_ = report.build_paragraphs(nodes,selected)
        self.assertEqual(len(units),1)
        unit=units[0];self.assertEqual(unit['box'],frame)
        self.assertEqual(unit['text'],nodes[0]['value'])
        request=report.translation_request(unit)
        self.assertEqual(request['parts'],[dict(kind='text',text='合計は '),dict(kind='math'),dict(kind='text',text=' です。')])
        self.assertNotEqual(report.entry_cache_key(request),report.translation_cache_key(unit['text'],False))
        changed=dict(request,parts=[dict(kind='math'),dict(kind='text',text='合計は です。')])
        self.assertNotEqual(report.entry_cache_key(request),report.entry_cache_key(changed))

if __name__ == '__main__':
    unittest.main()
