import hashlib, sqlite3, tempfile, unittest
from pathlib import Path
from bean.core import Store,Problem
class RecordingDatesTests(unittest.TestCase):
 def test_explicit_recording_date_is_distinct_from_upload_date(self):
  with tempfile.TemporaryDirectory() as d:
   store=Store(Path(d),reserve_bytes=0);payload={'device_id':'device','source_id':'source','title':'date test','size':1,'sha256':hashlib.sha256(b'x').hexdigest(),'recorded_at':1790310884}
   result=store.initiate(payload);row=store.recording(result['recording_id'])
   self.assertEqual(row['recorded_at'],1790310884);self.assertNotEqual(row['recorded_at'],row['created'])
   self.assertEqual(store.initiate(payload)['recording_id'],row['id'])
   for bad in [True,'1790310884',0,999999999999]:
    with self.assertRaises(Problem):store.initiate(dict(payload,recorded_at=bad))
 def test_legacy_ble_dates_migrate_but_synthetic_ids_stay_unknown(self):
  with tempfile.TemporaryDirectory() as d:
   root=Path(d);store=Store(root,reserve_bytes=0)
   data={'device_id':'AA:BB:CC:DD:EE:FF','source_id':'1790310884','title':'legacy','size':1,'sha256':hashlib.sha256(b'x').hexdigest()}
   rid=store.initiate(data)['recording_id'];other=store.initiate(dict(data,device_id='synthetic'))['recording_id']
   with store.db() as db:db.execute('ALTER TABLE recordings DROP COLUMN recorded_at')
   migrated=Store(root,reserve_bytes=0)
   self.assertEqual(migrated.recording(rid)['recorded_at'],1790310884);self.assertIsNone(migrated.recording(other)['recorded_at'])
