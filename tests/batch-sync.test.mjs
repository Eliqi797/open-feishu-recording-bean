import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {stripTypeScriptTypes} from 'node:module';
import {SyncController} from '../harmony/shared/SyncController.ts';
globalThis.__batchSync=SyncController;
const sourceCode='const SyncController=globalThis.__batchSync;\n'+readFileSync(new URL('../harmony/shared/BatchSync.ts',import.meta.url),'utf8').replace(/^import .*;\n/gm,'');
const {BatchSync,pendingRecordings}=await import('data:text/javascript;base64,'+Buffer.from(stripTypeScriptTypes(sourceCode)).toString('base64'));
const source=(id,device='d')=>({deviceId:device,sourceId:id,title:'录音'});
test('automatic queue skips only stored exact sources, preserving device isolation and list order',()=>{
 const pending=pendingRecordings([source('1'),source('2'),source('2'),source('3')],[{device_id:'d',source_id:'1',stored:1},{device_id:'other',source_id:'2',stored:1},{device_id:'d',source_id:'3',stored:0}]);
 assert.deepEqual(pending.map(x=>x.sourceId),['2','3']);
});
test('batch stops on failure; reconnect plans only the remaining recordings',async()=>{
 const batch=new BatchSync(),sent=[];
 await assert.rejects(batch.run([source('1'),source('2'),source('3')],async(s)=>{sent.push(s.sourceId);if(s.sourceId==='2')throw Error('offline');return{stored:true,verified:true};}),/offline/);
 assert.deepEqual(sent,['1','2']);
 const retry=pendingRecordings([source('1'),source('2'),source('3')],[{device_id:'d',source_id:'1',stored:1}]);
 assert.equal(await batch.run(retry,async()=>({stored:true,verified:true})),2);
});
test('pause prevents next file; duplicate start is rejected and bad receipts fail closed',async()=>{
 const batch=new BatchSync(),sent=[];
 await assert.rejects(batch.run([source('1'),source('2')],async(s)=>{sent.push(s.sourceId);await assert.rejects(batch.run([],async()=>({})),/ALREADY_RUNNING/);batch.cancel();return{stored:true,verified:true};}),/CANCELLED/);
 assert.deepEqual(sent,['1']);
 await assert.rejects(batch.run([source('3')],async()=>({stored:true,verified:false})),/RECEIPT_MISMATCH/);
});

function batchFixture(){
 const log=[],stored=new Map(),removed=[];const audio=id=>({path:id,size:6,sha256:'whole',mime:'audio/ogg'});
 const device={beginDownloadBatch:async()=>log.push('join'),endDownloadBatch:async()=>log.push('leave'),restoreInternet:async()=>log.push('internet'),downloadAndDecrypt:async s=>{log.push('download:'+s.sourceId);return audio(s.sourceId);}};
 const cache={findVerified:async s=>stored.get(s.sourceId),retain:async(s,a)=>stored.set(s.sourceId,a),persist:async()=>{},chunk:async()=>({bytes:new Uint8Array(6),sha256:'chunk'}),remove:async(a)=>{removed.push(a.path);stored.delete(a.path);}};
 const cloud={begin:async(s,a)=>{log.push('upload:'+s.sourceId);return{upload_id:s.sourceId,recording_id:s.sourceId,size:6,sha256:'whole',chunk_size:6,stored:false,chunks:[]};},put:async(id,i,c,progress)=>{progress?.(3);progress?.(6);},complete:async id=>({recording_id:id,stored:true,verified:true,sha256:'whole',size:6})};
 return{device,cache,cloud,stored,removed,log,audio};
}
test('one Wi-Fi batch downloads all before leaving once and uploading, with live byte progress',async()=>{
 const f=batchFixture(),updates=[],archived=[];
 assert.equal(await new BatchSync().transfer([source('1'),source('2')],f.device,f.cache,f.cloud,()=>{},(...a)=>updates.push(a),async s=>archived.push(s.sourceId)),2);
 assert.deepEqual(f.log,['join','download:1','download:2','leave','internet','upload:1','upload:2']);
 assert.deepEqual(archived,['1','2']);assert.deepEqual(f.removed,['1','2']);assert.ok(updates.some(x=>x[0]==='uploading'&&x[1]===3));
});
test('cached restart needs no Wi-Fi or device; missing cache never silently switches back to Wi-Fi mid-upload',async()=>{
 const f=batchFixture();f.stored.set('1',f.audio('1'));f.stored.set('2',f.audio('2'));
 await new BatchSync().transfer([source('1'),source('2')],f.device,f.cache,f.cloud,()=>{},()=>{},async()=>{});
 assert.deepEqual(f.log,['internet','upload:1','upload:2']);
 const f2=batchFixture();f2.device.restoreInternet=async()=>{f2.stored.delete('1');};
 await assert.rejects(new BatchSync().transfer([source('1')],f2.device,f2.cache,f2.cloud,()=>{},()=>{},async()=>{}),/CACHED_AUDIO_REQUIRED/);
 assert.equal(f2.log.filter(x=>x==='join').length,1);assert.ok(!f2.log.some(x=>x.startsWith('upload')));
});
test('failed or cancelled batch closes Wi-Fi and preserves earlier verified downloads',async()=>{
 for(const cancel of [false,true]){
  const f=batchFixture(),batch=new BatchSync();const original=f.device.downloadAndDecrypt;
  f.device.downloadAndDecrypt=async s=>{if(s.sourceId==='2'){if(cancel)batch.cancel();throw Error(cancel?'SYNC_CANCELLED':'disk full');}return original(s);};
  await assert.rejects(batch.transfer([source('1'),source('2')],f.device,f.cache,f.cloud,()=>{},()=>{},async()=>{}));
  assert.deepEqual(f.log,['join','download:1','leave']);assert.ok(f.stored.has('1'));assert.deepEqual(f.removed,[]);
 }
});
test('verified per-recording stable identities prevent reconnect downloads without cross-device guessing',()=>{
 const archived=[{device_id:'old-mac',source_id:'1',stored:1,source_devices:['stable-a']}];
 assert.deepEqual(pendingRecordings([source('1','stable-a')],archived),[]);
 assert.equal(pendingRecordings([source('1','stable-b')],archived).length,1);
 assert.equal(pendingRecordings([source('2','stable-a')],archived).length,1);
});
