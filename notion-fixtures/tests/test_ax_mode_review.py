import importlib.util
from pathlib import Path
import sys
import unittest
from unittest.mock import patch
module_path=Path(__file__).resolve().parents[1]/'tools/summarize_ax_mode_review.py'
with patch.object(sys,'argv',['summary','/tmp/activation','/tmp/review']):
 spec=importlib.util.spec_from_file_location('ax_review',module_path)
 module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)

class ModeReviewTests(unittest.TestCase):
 def line(self,start,text,y,height=19):
  return dict(start=start,length=len(text),text=text,box=dict(x=100,y=y,width=100,height=height))
 def test_whole_paragraph_box_is_not_visual_lines(self):
  ref=[self.line(0,'ab',100),self.line(2,'cd',124)]
  fake=[self.line(0,'ab',100,43),self.line(2,'cd',100,43)]
  self.assertFalse(module.exact_lines(fake,ref))
  self.assertFalse(module.exact_lines([self.line(0,'abcd',100,43)],ref))
  self.assertTrue(module.exact_lines(ref,ref))
 def test_node_numbers_do_not_establish_correspondence(self):
  a=[dict(id=1,role='AXStaticText',value='a',frame={'x':1})]
  b=[dict(id=99,role='AXStaticText',value='a',frame={'x':2})]
  result=module.compare(a,b)
  self.assertEqual(result['uniquePairs'],1)
  self.assertEqual(len(result['changes']['frame']),1)
 def test_changed_aggregate_text_is_reported_separately(self):
  a=[dict(id=1,role='AXTextArea',value='original')]
  b=[dict(id=9,role='AXTextArea',value='original original…')]
  diff=module.compare(a,b)
  self.assertEqual(diff['uniquePairs'],0)
  self.assertEqual(len(diff['structurallyUniqueTextChanges']),1)
  self.assertEqual(diff['structurallyUniqueTextChanges'][0]['edits'][0]['operation'],'insert')
 def test_attribute_order_is_not_a_capability_change(self):
  a=[dict(id=1,role='AXStaticText',value='a',attributes=['AXValue','AXRole'])]
  b=[dict(id=2,role='AXStaticText',value='a',attributes=['AXRole','AXValue'])]
  self.assertFalse(module.compare(a,b)['changes']['attributes'])
  b[0]['attributes'].append('AXLanguage')
  self.assertEqual(len(module.compare(a,b)['changes']['attributes']),1)
 def test_repeated_text_is_not_arbitrarily_matched(self):
  a=[dict(id=i,role='AXStaticText',value='same') for i in [1,2]]
  b=[dict(id=i,role='AXStaticText',value='same') for i in [8,9]]
  self.assertEqual(module.compare(a,b)['uniquePairs'],0)
  self.assertEqual(module.compare(a,b)['ambiguousNodes'],4)
if __name__=='__main__':unittest.main()
