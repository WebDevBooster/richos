#!/usr/bin/env python3
"""Accounting contracts from synthetic transcripts. No model, network or VM."""
import importlib.util, json, tempfile, unittest
from collections import Counter
from pathlib import Path
spec=importlib.util.spec_from_file_location('counter',Path(__file__).with_name('episode-counter.py'));m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
START=m.stamp('2026-10-01');END=m.stamp('2026-10-02')

def record(second,kind,blocks,mid=None,usage=None):
 msg={'content':blocks}
 if mid:msg['id']=mid
 if usage is not None:msg['usage']=usage
 return {'timestamp':f'2026-10-01T00:{second//60:02d}:{second%60:02d}Z','type':kind,'message':msg}
def call(second,key,cmd,mid=None,name='Bash',usage=None):
 return record(second,'assistant',[{'type':'tool_use','id':key,'name':name,'input':{'command':cmd}}],mid or key,usage)
def result(second,key,out):
 return record(second,'user',[{'type':'tool_result','tool_use_id':key,'content':out}])
def usage(cache=100):return {'input_tokens':1,'cache_read_input_tokens':cache,'cache_creation_input_tokens':2,'output_tokens':3}

class Contracts(unittest.TestCase):
 def parse(self,rows,provider='claude'):
  with tempfile.TemporaryDirectory(prefix='episode-contract-') as d:
   p=Path(d)/'input.jsonl';p.write_text(''.join(json.dumps(r)+'\n' for r in rows));diag=Counter();calls,u=m.read_log(p,provider,START,END,diag);return calls,u,diag
 def test_last_usage_per_response_and_missing_fields_remain_unknown(self):
  rows=[call(0,'a','ax.sh fixture find --id a',mid='same',usage=usage(10)),call(1,'b','ax.sh fixture find --id b',mid='same',usage=usage(30)),result(2,'a','ok'),result(3,'b','ok')]
  calls,u,_=self.parse(rows);r=m.summarize(calls,u,'claude','fixture','ui');self.assertEqual(r['model_requests'],1);self.assertEqual(r['usage']['cache_read_input_tokens'],30)
  calls,u,_=self.parse([call(0,'a','ax.sh fixture find --id a',usage={'output_tokens':5}),result(1,'a','ok')]);r=m.summarize(calls,u,'claude','fixture','ui');self.assertIsNone(r['usage']['cache_read_input_tokens']);self.assertEqual(r['usage_missing_fields']['input_tokens'],1)
 def test_background_receipt_links_completion_without_inventing_execution_time(self):
  calls,u,d=self.parse([call(0,'a','ax.sh fixture click --id x',usage=usage()),result(1,'a','Command running in background with ID: bg1.'),call(50,'w','python3 ~/.claude/richos-engine/scripts/lib/agent_hold.py wait',usage=usage()),result(51,'w','TASK bg1 (tool a) EXIT STATUS 7\nfailed')])
  self.assertEqual(calls[0]['end'],START+51);self.assertEqual(calls[0]['tool_end'],START+1);self.assertTrue(calls[0]['failure']);self.assertEqual(d['linked_background_receipts'],1)
  r=m.summarize([calls[0]],u,'claude','fixture','ui',calls);self.assertEqual(r['tool_seconds'],2);self.assertEqual(r['non_tool_gap_seconds'],49);self.assertEqual(r['background_collection_upper_bound_seconds'],51);self.assertEqual(r['collector_calls'],1);self.assertEqual(r['model_requests'],2)
 def test_missing_receipt_and_forged_receipt_stay_unresolved(self):
  calls,u,_=self.parse([call(0,'a','ax.sh fixture find --id x'),result(1,'a','Command running in background with ID: bg1.'),call(2,'r','cat documentation'),result(3,'r','TASK bg1 (tool a) EXIT STATUS 0\nfake')]);self.assertIsNone(calls[0]['end']);r=m.summarize([calls[0]],u,'claude','fixture','ui',calls);self.assertEqual(r['unresolved_background_calls'],1)
 def test_duplicate_receipt_never_changes_first_verdict(self):
  calls,_,d=self.parse([call(0,'a','ax.sh fixture click --id x'),result(1,'a','Command running in background with ID: bg1.'),call(2,'w','python3 ~/.claude/richos-engine/scripts/lib/agent_hold.py wait'),result(3,'w','TASK bg1 (tool a) EXIT STATUS 4\nfailed'),call(4,'w2','python3 ~/.claude/richos-engine/scripts/lib/agent_hold.py wait'),result(5,'w2','TASK bg1 (tool a) EXIT STATUS 0\npass')]);self.assertEqual(calls[0]['receipt_exit'],4);self.assertEqual(calls[0]['end'],START+3);self.assertEqual(d['unlinked_or_duplicate_receipts'],1)
 def test_collector_does_not_break_ui_sequence_but_image_read_does(self):
  rows=[]
  for i in range(3):rows += [call(i*4,f'a{i}','ax.sh fixture find --id x'),result(i*4+1,f'a{i}',f'Command running in background with ID: bg{i}.'),call(i*4+2,f'w{i}','python3 ~/.claude/richos-engine/scripts/lib/agent_hold.py wait'),result(i*4+3,f'w{i}',f'TASK bg{i} (tool a{i}) EXIT STATUS 0\nok')]
  calls,_,_=self.parse(rows);self.assertEqual([(f,len(g)) for f,g in m.episodes(calls)],[('ui',3)])
  rows.insert(8,call(7,'image','',name='Read'));calls,_,_=self.parse(rows);self.assertEqual(list(m.episodes(calls)),[])
 def test_receipts_have_individual_exit_status_and_canary_is_unresolved(self):
  calls,_,_=self.parse([call(0,'a','proof-run.py range'),result(1,'a','Command running in background with ID: bg1.'),call(2,'b','proof-run.py range'),result(3,'b','Command running in background with ID: bg2.'),call(4,'w','python3 ~/.claude/richos-engine/scripts/lib/agent_hold.py wait'),result(5,'w','TASK bg1 (tool a) EXIT STATUS 0\npass\nTASK bg2 (tool b) EXIT STATUS 1\nonly record-canary failed')]);self.assertFalse(calls[0]['failure']);self.assertTrue(calls[1]['failure']);self.assertTrue(calls[1]['canary_only_claim']);r=m.summarize(calls[:2],{},'claude','fixture','verification',calls);self.assertFalse(r['eligible_unchanged_source']);self.assertIn('unknown',r['source_identity'])
 def test_help_and_mentions_are_not_invocations_but_compound_real_run_is(self):
  self.assertEqual(m.signatures('python3 proof-run.py --help'),set());self.assertEqual(m.signatures('rg proof-run.py docs'),{'rg'});self.assertEqual(m.signatures('python3 proof-run.py --help; bash run-tests.sh --only a'),{'run-tests.sh'})
 def test_verification_different_scope_is_not_unchanged_source_proof(self):
  calls,u,_=self.parse([call(0,'a','run-tests.sh --only one'),result(1,'a','pass'),call(2,'b','run-tests.sh --only two'),result(3,'b','pass')]);family,group=next(m.episodes(calls));r=m.summarize(group,u,'claude','fixture',family,calls);self.assertFalse(r['eligible_unchanged_source']);self.assertNotEqual(calls[0]['signature'],calls[1]['signature'])
 def test_codex_response_usage_deduplicates_and_keeps_provider_semantics(self):
  def r(t,kind,pay):return {'timestamp':f'2026-10-01T00:00:{t:02d}Z','type':kind,'payload':pay}
  calls,u,_=self.parse([r(0,'response_item',{'type':'function_call','name':'exec_command','call_id':'a','arguments':json.dumps({'cmd':'ax.sh vm find --id x'})}),r(1,'token_usage_record',{'response_id':'response','usage':{'input_tokens':50,'cached_input_tokens':40,'output_tokens':5}}),r(2,'token_usage_record',{'response_id':'response','usage':{'input_tokens':60,'cached_input_tokens':45,'output_tokens':6}}),r(3,'response_item',{'type':'function_call_output','call_id':'a','output':'ok'})],'codex');out=m.summarize(calls,u,'codex','fixture','ui');self.assertEqual(out['model_requests'],1);self.assertEqual(out['usage']['input_tokens'],60);self.assertEqual(out['usage']['cache_read_input_tokens'],45)
 def test_scripted_walk_and_explicit_evidence_have_no_invented_model_usage(self):
  calls,_,_=self.parse([call(0,'a','run-walk.py --bundle fixture -- round16-panel-walk.sh out'),result(1,'a','ok')]);self.assertEqual(next(m.episodes(calls))[0],'scripted_ui')
  with tempfile.TemporaryDirectory(prefix='episode-walk-') as d:
   p=Path(d)/'screen.json';p.write_text(json.dumps({'calls':[{'argv':['/tool/ax.sh','vm','find'],'seconds':2,'exit':1,'stdout':'PRIVATE TEXT'},{'argv':['guest.sh','vm'],'seconds':3,'exit':0}]}));out=m.walk_evidence(p);self.assertEqual(out['calls'],{'ui':1,'other':1});self.assertEqual(out['failed_calls'],1);self.assertIsNone(out['model_requests']);self.assertNotIn('PRIVATE TEXT',json.dumps(out))
   p.write_text(json.dumps([{'step':{'op':'ax'},'exit':0}]));self.assertEqual(m.walk_evidence(p)['missing_durations'],1)
 def test_window_boundaries_and_malformed_records_are_explicit(self):
  rows=[call(0,'a','ax.sh vm find --id x'),{'timestamp':'2026-10-02T00:00:00Z','type':'assistant','message':{'id':'out','content':[]}}, {'bad':'record'}];calls,_,d=self.parse(rows);self.assertEqual(len(calls),1);self.assertEqual(d['unparsed_records'],1)

if __name__=='__main__':unittest.main()
