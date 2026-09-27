import test from 'node:test';
import assert from 'node:assert/strict';
import { liveWindow } from '../harmony/shared/LiveAudio.ts';
import { cloudOriginAllowed } from '../harmony/shared/CloudPolicy.ts';
test('live Ogg windows have complete EOS and exact local granules',()=>{
 const bytes=liveWindow([new Uint8Array(160),new Uint8Array(160)]);
 let at=0,pages=[];while(at<bytes.length){const n=bytes[at+26];let length=27+n;for(let i=0;i<n;i++)length+=bytes[at+27+i];pages.push(bytes.slice(at,at+length));at+=length;}
 assert.equal(pages.length,4);assert.equal(pages[0][28+10],0);assert.equal(pages.at(-1)[5],4);
 assert.equal(new DataView(pages.at(-1).buffer).getUint32(6,true),1920);
 assert.throws(()=>liveWindow([]),/INVALID/);assert.throws(()=>liveWindow([new Uint8Array(159)]),/INVALID/);
});
test('USB file relay is debug only and HTTP stays forbidden',()=>{
 assert.equal(cloudOriginAllowed('usb://local',true),true);
 for(const origin of ['http://127.0.0.1:8765','http://localhost:8765','http://192.168.1.1','http://127.0.0.1:8766','http://127.0.0.1:8765@evil.com','http://127.0.0.1:8765.evil.com']){
  assert.equal(cloudOriginAllowed(origin,false),false);
  assert.equal(cloudOriginAllowed(origin,true),false);
 }
 assert.equal(cloudOriginAllowed('usb://local',false),false);
 assert.equal(cloudOriginAllowed('https://example.com',false),true);
});
