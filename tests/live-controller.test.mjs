import test from 'node:test';
import assert from 'node:assert/strict';
import * as fs from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {stripTypeScriptTypes} from 'node:module';
const hash='a'.repeat(64);
globalThis.__liveTest={fs:{listFileSync:fs.readdirSync,readTextSync:p=>fs.readFileSync(p,'utf8')},writeFile:(p,s)=>fs.writeFileSync(p,s),SyncController:class {async sync(){throw Error('Must not archive interrupted capture');}}};
let source=fs.readFileSync(new URL('../harmony/entry/src/main/ets/services/LiveController.ets',import.meta.url),'utf8').replace(/^import .*;\n/gm,'');
source='const {fs,writeFile,SyncController}=globalThis.__liveTest;\n'+source;
const {LiveController}=await import('data:text/javascript;base64,'+Buffer.from(stripTypeScriptTypes(source)).toString('base64'));
function setup(){
 const removed=[];const root=fs.mkdtempSync(join(tmpdir(),'bean-live-')),sent=[],begins=[];
 const cache={root,remove:async(audio)=>{removed.push(audio.path);},chunk:async()=>({bytes:new Uint8Array(10),sha256:hash})};
 const cloud={endpoint:()=> 'https://cloud.example',liveBegin:async(...args)=>{begins.push(args);return{session_id:'session'};},livePut:async(id,idx,c)=>{sent.push(idx);return{verified:true,sha256:c.sha256,idx,size:10};},liveStatus:async()=>({session_id:'session'}),liveFinish:()=>assert.fail('Interrupted capture must not finish')};
 const segment=i=>({index:i,frames:1000,fromSequence:17,audio:{path:join(root,`window-${i}.ogg`),size:10,sha256:hash,mime:'audio/ogg'}});
 const recording={deviceId:'device',sourceId:'recording',title:'meeting'};
 return{root,sent,begins,cache,cloud,segment,recording,removed};
}
test('network outage leaves a durable ordered queue and a fresh controller recovers without capture or finish',async()=>{
 const x=setup();try{
  x.cloud.livePut=async()=>{throw Error('offline');};
  const device={cancel:()=>{},captureRealtime:async(s,on)=>{await on(x.segment(0));await on(x.segment(1));throw Error('BLE disconnected');}};
  await assert.rejects(new LiveController(device,x.cache,x.cloud,()=>{}).start(x.recording,20),/BLE disconnected/);
  const path=join(x.root,fs.readdirSync(x.root)[0]);let saved=JSON.parse(fs.readFileSync(path));
  assert.equal(saved.state,'interrupted');assert.deepEqual(saved.pending.map(s=>s.index),[0,1]);
  x.cloud.livePut=async(id,idx,c)=>{x.sent.push(idx);return{verified:true,sha256:c.sha256,idx,size:10};};
  const fresh=new LiveController({cancel:()=>{},captureRealtime:()=>assert.fail('Must not re-record')},x.cache,x.cloud,()=>{});
  assert.equal(await fresh.recoverPending(),2);assert.deepEqual(x.sent,[0,1]);
  saved=JSON.parse(fs.readFileSync(path));assert.equal(saved.pending.length,0);assert.equal(saved.count,2);assert.equal(saved.state,'interrupted');assert.equal(x.removed.length,2);assert.equal(saved.cleanup.length,0);
  assert.equal(await fresh.recoverPending(),0);assert.deepEqual(x.sent,[0,1]);
 }finally{fs.rmSync(x.root,{recursive:true});}
});
test('slow network does not block capture callback; invalid receipt keeps the pending segment',async()=>{
 const x=setup();let release,started;const pending=new Promise(r=>release=r),ready=new Promise(r=>started=r);let controller;
 try{
  x.cloud.livePut=async()=>{started();await pending;return{verified:true,sha256:'b'.repeat(64),idx:0,size:10};};
  const device={cancel:()=>{},captureRealtime:async(s,on)=>{await on(x.segment(0));await ready;await on(x.segment(1));assert.equal(JSON.parse(fs.readFileSync(join(x.root,fs.readdirSync(x.root)[0]))).pending.length,2);release();throw Error('capture stopped');}};
  controller=new LiveController(device,x.cache,x.cloud,()=>{});await assert.rejects(controller.start(x.recording,20),/capture stopped/);
  const journal=JSON.parse(fs.readFileSync(join(x.root,fs.readdirSync(x.root)[0])));assert.equal(journal.pending.length,2);assert.equal(journal.count,0);
 }finally{release?.();fs.rmSync(x.root,{recursive:true});}
});
test('lost upload acknowledgement retries the same index; corrupt or other-cloud journals fail closed',async()=>{
 const x=setup();try{
  const journal={version:1,endpoint:x.cloud.endpoint(),source:x.recording,captureSource:{...x.recording,sourceId:'capture-stable'},sessionId:'session',fromSequence:17,pending:[x.segment(0)],count:0,state:'capturing'};
  const path=join(x.root,'live-journal-1.json');fs.writeFileSync(path,JSON.stringify(journal));
  const c=new LiveController({cancel:()=>{}},x.cache,x.cloud,()=>{});await c.recoverPending();assert.deepEqual(x.sent,[0]);assert.equal(JSON.parse(fs.readFileSync(path)).state,'interrupted');
  journal.pending[0].audio.path='/other/file';fs.writeFileSync(path,JSON.stringify(journal));await assert.rejects(c.recoverPending(),/JOURNAL_INVALID/);
  journal.endpoint='https://other.example';fs.writeFileSync(path,JSON.stringify(journal));await assert.rejects(c.recoverPending(),/OTHER_CLOUD/);assert.deepEqual(x.sent,[0]);
 }finally{fs.rmSync(x.root,{recursive:true});}
});

test('acknowledged cleanup retries after restart without uploading again',async()=>{
 const x=setup();try{
  const journal={version:1,endpoint:x.cloud.endpoint(),source:x.recording,captureSource:x.recording,sessionId:'session',fromSequence:17,pending:[],count:1,state:'interrupted',cleanup:[x.segment(0).audio]};
  const path=join(x.root,'live-journal-9.json');fs.writeFileSync(path,JSON.stringify(journal));
  const c=new LiveController({cancel:()=>{}},x.cache,x.cloud,()=>{});await c.recoverPending();assert.equal(x.removed.length,1);assert.equal(x.sent.length,0);assert.equal(JSON.parse(fs.readFileSync(path)).cleanup.length,0);
 }finally{fs.rmSync(x.root,{recursive:true});}
});

test('short-window selection survives restart and is sent when creating the session',async()=>{
 const x=setup();try{
  const notices=[];
  x.cloud.liveBegin=async()=>{throw Error('offline');};
  const segment={...x.segment(0),frames:100};
  const device={cancel:()=>{},captureRealtime:async(s,on,seconds)=>{assert.equal(seconds,2);await on(segment);throw Error('disconnected');}};
  await assert.rejects(new LiveController(device,x.cache,x.cloud,()=>{}).start(x.recording,2),/disconnected/);
  const path=join(x.root,fs.readdirSync(x.root)[0]);assert.equal(JSON.parse(fs.readFileSync(path)).windowSeconds,2);
  x.cloud.liveBegin=async(...args)=>{x.begins.push(args);return{session_id:'session'};};
  await new LiveController({cancel:()=>{}},x.cache,x.cloud,s=>notices.push(s)).recoverPending();
  assert.equal(x.begins[0][3],2000);assert.equal(x.begins[0][2],340);assert.match(notices[0],/2.0 秒/);assert.deepEqual(x.sent,[0]);
 }finally{fs.rmSync(x.root,{recursive:true});}
});
