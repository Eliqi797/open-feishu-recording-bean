import test from 'node:test';
import assert from 'node:assert/strict';
import * as io from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {stripTypeScriptTypes} from 'node:module';
import {FrameDecoder,le} from '../harmony/shared/D3200Protocol.ts';
let largestRead=0;
globalThis.__inboxTest={FrameDecoder,
 fs:{OpenMode:{CREATE:io.constants.O_CREAT,READ_WRITE:io.constants.O_RDWR,READ_ONLY:io.constants.O_RDONLY,TRUNC:io.constants.O_TRUNC},openSync:(p,flags)=>({fd:io.openSync(p,flags,0o600)}),closeSync:f=>io.closeSync(f.fd),readSync:(fd,b,{length})=>{largestRead=Math.max(largestRead,length);return io.readSync(fd,new Uint8Array(b),0,length,null);}},
 writeBytes:(fd,bytes)=>{let off=0;while(off<bytes.length)off+=io.writeSync(fd,bytes,off,bytes.length-off);}
};
let source=io.readFileSync(new URL('../harmony/standard-overlay/services/TransferInbox.ets',import.meta.url),'utf8').replace(/^import .*;\n/gm,'');
source='const {fs,writeBytes,FrameDecoder}=globalThis.__inboxTest;\n'+source;
const {TransferInbox}=await import('data:text/javascript;base64,'+Buffer.from(stripTypeScriptTypes(source)).toString('base64'));
function frame(i){const b=new Uint8Array(176);b.set([9,255,0,0,1,26,8]);b.set(le(b.length,2),7);b.set(le(i),9);b[175]=b.slice(0,-1).reduce((a,b)=>(a+b)&255,0);return b;}
test('fast producer over 1024 frames drains in order through bounded disk windows',()=>{
 const dir=io.mkdtempSync(join(tmpdir(),'bean-inbox-')),p=join(dir,'wire'),inbox=new TransferInbox(p,4e6);
 try{
  const all=Buffer.concat(Array.from({length:6000},(_,i)=>frame(i)));
  inbox.append(all.subarray(0,100));assert.equal(inbox.next(),undefined);inbox.append(all.subarray(100));
  let count=0;for(let i=0;i<7000&&count<6000;i++){const f=inbox.next();if(f){assert.equal(new DataView(f.payload.buffer,f.payload.byteOffset).getUint32(0,true),count++);}}
  assert.equal(count,6000);assert.equal(inbox.next(),undefined);assert.ok(largestRead<=32768);assert.equal(inbox.size(),all.length);
 }finally{inbox.close();io.rmSync(dir,{recursive:true});}
 assert.throws(()=>inbox.append(frame(0)),/CLOSED/);
});
test('disk quota and truncated spool fail without pretending transfer completion',()=>{
 const dir=io.mkdtempSync(join(tmpdir(),'bean-inbox-')),p=join(dir,'wire'),inbox=new TransferInbox(p,176);
 try{inbox.append(frame(0));assert.throws(()=>inbox.append(frame(1)),/INSUFFICIENT_STORAGE/);io.truncateSync(p,1);assert.throws(()=>inbox.next(),/TRUNCATED/);}finally{inbox.close();io.rmSync(dir,{recursive:true});}
});
test('remote close drains the authenticated spool; exhausted or partial input still fails',()=>{
 const dir=io.mkdtempSync(join(tmpdir(),'bean-inbox-')),inbox=new TransferInbox(join(dir,'wire'),4e6);
 try{
  inbox.append(Buffer.concat(Array.from({length:6000},(_,i)=>frame(i))));
  inbox.finish('D3200_PIN_TLS_CLOSED');
  for(let i=0;i<6000;i++)assert.equal(new DataView(inbox.next().payload.buffer).getUint32(0,true),i);
  assert.throws(()=>inbox.next(),/TLS_CLOSED/);
 }finally{inbox.close();io.rmSync(dir,{recursive:true});}
 const dir2=io.mkdtempSync(join(tmpdir(),'bean-inbox-')),partial=new TransferInbox(join(dir2,'wire'),1000);
 try{partial.append(frame(0).slice(0,100));partial.finish('D3200_PIN_TLS_CLOSED');assert.throws(()=>partial.next(),/TLS_CLOSED/);}
 finally{partial.close();io.rmSync(dir2,{recursive:true});}
});
