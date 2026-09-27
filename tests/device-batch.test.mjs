import test from 'node:test';import assert from 'node:assert/strict';import * as fs from 'node:fs';import {tmpdir} from 'node:os';import {join} from 'node:path';import {stripTypeScriptTypes} from 'node:module';import {createHash} from 'node:crypto';
import * as protocol from '../harmony/shared/D3200Protocol.ts';
let device,joins=0,closes=0,reads=0;
class SoftAp{async credentials(){return new Uint8Array(0);}async connect(){joins++;}async request(id){const head=new Uint8Array(100);head.set(protocol.le(id));head.set(protocol.le(166),4);device.queue.push({type:26,command:7,status:1,payload:head},{type:26,command:8,status:1,payload:new Uint8Array(166)},{type:26,command:10,status:1,payload:new Uint8Array(0)});}async close(){closes++;}cancel(){}}
globalThis.__deviceBatch={...protocol,sha:async b=>new Uint8Array(createHash('sha256').update(b).digest()),hex:b=>Buffer.from(b).toString('hex'),SoftAp,FrameDecoder:protocol.FrameDecoder,DeviceCrypto:class {async file(){}async decryptBatch(){return new Uint8Array(160);}clear(){}},TransferInbox:class{close(){}next(){}},
 statfs:{getFreeSize:async()=>1e9},fs:{OpenMode:{CREATE:fs.constants.O_CREAT,READ_WRITE:fs.constants.O_RDWR,TRUNC:fs.constants.O_TRUNC},openSync:(p,flags)=>({fd:fs.openSync(p,flags)}),closeSync:f=>fs.closeSync(f.fd),statSync:fs.statSync,renameSync:fs.renameSync,fsyncSync:fs.fsyncSync,accessSync:fs.existsSync,unlinkSync:fs.unlinkSync},
 writeFile:(p,s)=>fs.writeFileSync(p,s),writeBytes:(fd,b)=>fs.writeSync(fd,b),hashFile:async p=>createHash('sha256').update(fs.readFileSync(p)).digest('hex'),ble:{},constant:{},liveWindow:()=>{}};
const original=fs.readFileSync(new URL('../harmony/standard-overlay/services/D3200Device.ets',import.meta.url),'utf8').replace(/^import .*;\n/gm,'');
const source='const {'+Object.keys(globalThis.__deviceBatch).join(',')+'}=globalThis.__deviceBatch;\n'+original;
const {D3200Device}=await import('data:text/javascript;base64,'+Buffer.from(stripTypeScriptTypes(source)).toString('base64'));
test('native two-file transfer keeps Wi-Fi and crypto session until batch end, with exact frame validation',async()=>{
 const root=fs.mkdtempSync(join(tmpdir(),'bean-device-batch-'));try{
  device=new D3200Device({root},()=>{});device.deviceId='own';device.useWifi=true;
  device.readRecordingState=async()=>{reads++;device.recordingState=0;};
  device.send=async()=>{device.queue.push({type:26,command:5,status:1,payload:new Uint8Array([1,43,168,192,187,1])});};
  await device.beginDownloadBatch();
  const a=await device.downloadAndDecrypt({deviceId:'own',sourceId:'1790310001',title:'one'});
  assert.equal(joins,1);assert.equal(closes,0);assert.ok(fs.existsSync(a.path));
  const b=await device.downloadAndDecrypt({deviceId:'own',sourceId:'1790310002',title:'two'});
  assert.equal(joins,1);assert.equal(closes,0);assert.ok(fs.existsSync(b.path));assert.equal(reads,2);
  await device.endDownloadBatch();assert.equal(closes,1);
 }finally{fs.rmSync(root,{recursive:true});}
});

test('native identity stays stable across BLE address changes and rejects changed serial in-session',async()=>{
 const root=fs.mkdtempSync(join(tmpdir(),'bean-identity-'));try{
  const d=new D3200Device({root},()=>{});let serial='D3200AB123456789';
  d.send=async()=>{};d.next=async()=>{const payload=new Uint8Array(56);payload.set(Buffer.from(serial),8);return{payload};};
  d.transportId='AA:BB:CC:DD:EE:01';await d.readRecordingState();const stable=d.deviceId;
  d.deviceId='';d.transportId='AA:BB:CC:DD:EE:02';await d.readRecordingState();assert.equal(d.deviceId,stable);assert.match(stable,/^d3200-sn-[a-f0-9]{64}$/);
  serial='D3200AB123456788';await assert.rejects(d.readRecordingState(),/STABLE_ID_CHANGED/);
 }finally{fs.rmSync(root,{recursive:true});}
});
