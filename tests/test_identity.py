import hashlib,tempfile,unittest
from pathlib import Path
from bean.core import Store,Problem

class IdentityTests(unittest.TestCase):
 def setUp(self):
  self.tmp=tempfile.TemporaryDirectory();self.store=Store(Path(self.tmp.name),reserve_bytes=0);self.audio=b'identical finished audio';self.stable='d3200-sn-'+'a'*64
 def tearDown(self):self.tmp.cleanup()
 def args(self,device,source='1790335527',audio=None):
  data=self.audio if audio is None else audio
  return dict(device_id=device,source_id=source,title='test',size=len(data),sha256=hashlib.sha256(data).hexdigest(),mime='audio/ogg')
 def archive(self,device,audio=None):
  data=self.audio if audio is None else audio;s=self.store.initiate(self.args(device,audio=data));self.store.put_chunk(s['upload_id'],0,data,hashlib.sha256(data).hexdigest());self.store.complete(s['upload_id']);return s
 def test_legacy_association_preserves_id_publications_and_survives_restart(self):
  old=self.archive('AA:BB:CC:DD:EE:01')
  with self.store.db() as db:db.execute('INSERT INTO publications VALUES(?,?,?,?,?,?,?)',(old['recording_id'],0,'verified','same-doc','hash','title',None))
  new=self.store.initiate(self.args(self.stable));self.assertEqual(new['recording_id'],old['recording_id']);self.assertTrue(new['stored']);self.assertEqual(len(self.store.listing()),1)
  self.store=Store(Path(self.tmp.name),reserve_bytes=0);again=self.store.initiate(self.args(self.stable));self.assertEqual(new,again)
  r=self.store.recording(old['recording_id']);self.assertEqual(r['source_devices'],[self.stable]);self.assertEqual(r['publications'][0]['document_id'],'same-doc');self.assertTrue(self.store.complete(new['upload_id'])['verified'])
 def test_shared_time_is_not_identity_and_distinct_stable_devices_stay_separate(self):
  old=self.archive('AA:BB:CC:DD:EE:01');new=self.store.initiate(self.args(self.stable,audio=b'different audio'));self.assertNotEqual(old['recording_id'],new['recording_id'])
  associated=self.store.initiate(self.args(self.stable));other=self.store.initiate(self.args('d3200-sn-'+'b'*64));self.assertNotEqual(other['recording_id'],associated['recording_id'])
 def test_incomplete_or_corrupt_legacy_archive_never_skips_upload(self):
  old=self.store.initiate(self.args('AA:BB:CC:DD:EE:01'));new=self.store.initiate(self.args(self.stable));self.assertNotEqual(old['recording_id'],new['recording_id'])
  old=self.archive('AA:BB:CC:DD:EE:02');(self.store.root/'audio'/old['recording_id']).write_bytes(b'bad')
  with self.assertRaisesRegex(Problem,'INTEGRITY'):self.store.initiate(self.args('d3200-sn-'+'c'*64))
 def test_legacy_duplicates_remain_but_only_one_canonical_binding_created(self):
  one=self.archive('AA:BB:CC:DD:EE:01');self.archive('AA:BB:CC:DD:EE:02')
  new=self.store.initiate(self.args(self.stable));self.assertEqual(one['recording_id'],new['recording_id']);self.assertEqual(len(self.store.listing()),2)
  other=self.store.initiate(self.args('d3200-sn-'+'b'*64));self.assertNotEqual(other['recording_id'],new['recording_id']);self.assertFalse(other['stored'])
 def test_live_finalization_accepts_only_verified_stable_recording_association(self):
  from bean.live import LiveStore
  old=self.archive('AA:BB:CC:DD:EE:01');self.store.initiate(self.args(self.stable));live=LiveStore(self.store)
  segment=b'OggS'+bytes(160)
  for device,allowed in [(self.stable,True),('d3200-sn-'+'b'*64,False)]:
   sid=live.begin(dict(device_id=device,source_id='capture',original_source_id='1790335527',title='test'))['session_id']
   live.put(sid,0,segment,hashlib.sha256(segment).hexdigest(),20000)
   data=dict(recording_id=old['recording_id'],segment_count=1,device_end_observed=True)
   if allowed:self.assertEqual(live.finish(sid,data)['status'],'completed')
   else:
    with self.assertRaisesRegex(Problem,'MISMATCH'):live.finish(sid,data)
