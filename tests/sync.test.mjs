import test from 'node:test';
import assert from 'node:assert/strict';
import {SyncController} from '../harmony/shared/SyncController.ts';
const source={deviceId:'d',sourceId:'s',title:'test'};
function fixture(){
 const stats={downloads:0,removed:0,puts:[],journals:[]};
 const audio={path:'private/test.wav',size:6,sha256:'whole',mime:'audio/wav'};
 const device={downloadAndDecrypt:async()=>{stats.downloads++;return audio},restoreInternet:async()=>{}};
 const cache={findVerified:async()=>undefined,retain:async()=>{},chunk:async(a,o,n)=>({bytes:new Uint8Array(n),sha256:'chunk'+o}),remove:async()=>{stats.removed++},persist:async j=>{stats.journals.push({...j})}};
 const session={upload_id:'u',recording_id:'r',size:6,sha256:'whole',chunk_size:4,stored:false,chunks:[]};
 const cloud={begin:async()=>session,put:async(u,i)=>{stats.puts.push(i)},complete:async()=>({recording_id:'r',stored:true,verified:true,sha256:'whole',size:6})};
 return {stats,audio,device,cache,session,cloud,controller:new SyncController(device,cache,cloud,()=>{})};
}
test('remove local cache only after matching durable receipt',async()=>{const f=fixture();await f.controller.sync(source);assert.equal(f.stats.removed,1);assert.equal(f.stats.journals.at(-1).phase,'completed')});
test('bad receipt never deletes audio',async()=>{const f=fixture();f.cloud.complete=async()=>({recording_id:'wrong',stored:true,verified:true,sha256:'whole',size:6});await assert.rejects(f.controller.sync(source),/RECEIPT/);assert.equal(f.stats.removed,0)});
test('resume keeps local audio and skips verified server chunk',async()=>{const f=fixture();f.cache.findVerified=async()=>f.audio;f.session.chunks=[{idx:0,sha256:'chunk0',size:4}];await f.controller.sync(source);assert.equal(f.stats.downloads,0);assert.deepEqual(f.stats.puts,[1])});
test('network loss preserves local cache',async()=>{const f=fixture();f.cloud.put=async()=>{throw Error('offline')};await assert.rejects(f.controller.sync(source),/offline/);assert.equal(f.stats.removed,0);assert.equal(f.stats.journals.at(-1).phase,'interrupted')});
test('cleanup failure retains cleanup_pending journal',async()=>{const f=fixture();f.cache.remove=async()=>{throw Error('io')};await assert.rejects(f.controller.sync(source));assert.equal(f.stats.journals.at(-1).phase,'cleanup_pending')});
test('duplicate clicks cannot start two downloads',async()=>{const f=fixture();let done;f.device.downloadAndDecrypt=()=>new Promise(resolve=>{done=resolve});const first=f.controller.sync(source);await new Promise(setImmediate);await assert.rejects(f.controller.sync(source),/ALREADY_RUNNING/);done(f.audio);await first});
test('local-only download requires no cloud and retains verified cache for later upload',async()=>{
 const f=fixture();let retained;f.cache.retain=async(s,a)=>{retained=a};
 const local=new SyncController(f.device,f.cache,undefined,()=>{});
 assert.equal(await local.downloadOnly(source),f.audio);assert.equal(retained,f.audio);
 assert.equal(f.stats.removed,0);assert.deepEqual(f.stats.puts,[]);assert.equal(f.stats.journals.at(-1).phase,'cached');
 f.cache.findVerified=async()=>retained;
 await local.downloadOnly(source);assert.equal(f.stats.downloads,1);
 await f.controller.sync(source);assert.equal(f.stats.downloads,1);assert.equal(f.stats.removed,1);
});
test('local download cancellation retains completed audio and rejects concurrent sync',async()=>{
 const f=fixture();let finish;f.device.downloadAndDecrypt=()=>new Promise(resolve=>{finish=resolve});
 const first=f.controller.downloadOnly(source);await new Promise(setImmediate);
 await assert.rejects(f.controller.sync(source),/ALREADY_RUNNING/);f.controller.cancel();finish(f.audio);
 await assert.rejects(first,/SYNC_CANCELLED/);assert.equal(f.stats.removed,0);assert.equal(f.stats.journals.at(-1).phase,'interrupted');
});
test('cache write failure never reports locally saved success',async()=>{
 const f=fixture();f.cache.retain=async()=>{throw Error('disk full')};
 await assert.rejects(f.controller.downloadOnly(source),/disk full/);assert.equal(f.stats.removed,0);assert.equal(f.stats.journals.at(-1).phase,'interrupted');
});
test('transient cloud failure retries the same chunk and keeps one device download',async()=>{
 const f=fixture();let calls=0;const phases=[];
 f.cloud.put=async(u,i)=>{f.stats.puts.push(i);if(++calls===1)throw Error('CLOUD_NETWORK_2300056')};
 const c=new SyncController(f.device,f.cache,f.cloud,p=>phases.push(p));await c.sync(source);
 assert.deepEqual(f.stats.puts,[0,0,1]);assert.equal(f.stats.downloads,1);assert.equal(f.stats.removed,1);assert.ok(phases.includes('retrying'));
});
test('transient completion response loss repeats completion before clearing cache',async()=>{
 const f=fixture();let calls=0;const complete=f.cloud.complete;
 f.cloud.complete=async()=>{if(++calls===1)throw Error('CLOUD_NETWORK_2300056');return complete()};
 await f.controller.sync(source);assert.equal(calls,2);assert.equal(f.stats.removed,1);
});
test('persistent network error has bounded retries and preserves audio',async()=>{
 const f=fixture();let calls=0;f.cloud.begin=async()=>{calls++;throw Error('CLOUD_NETWORK_2300007')};
 await assert.rejects(f.controller.sync(source),/2300007/);assert.equal(calls,3);assert.equal(f.stats.removed,0);
});
test('pause during network retry prevents further requests',async()=>{
 const f=fixture();let calls=0;f.cloud.begin=async()=>{calls++;throw Error('CLOUD_NETWORK_2300056')};
 const c=new SyncController(f.device,f.cache,f.cloud,p=>{if(p==='retrying')c.cancel()});
 await assert.rejects(c.sync(source),/SYNC_CANCELLED/);assert.equal(calls,1);assert.equal(f.stats.removed,0);
});
test('auth and certificate failures are not retried',async()=>{
 for(const code of ['CLOUD_HTTP_401','CLOUD_NETWORK_2300060']){
  const f=fixture();let calls=0;f.cloud.begin=async()=>{calls++;throw Error(code)};
  await assert.rejects(f.controller.sync(source));assert.equal(calls,1);assert.equal(f.stats.removed,0);
 }
});
