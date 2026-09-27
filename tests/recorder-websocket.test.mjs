import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {stripTypeScriptTypes} from 'node:module';
import {createHash,randomBytes} from 'node:crypto';
const leaf=new Uint8Array(readFileSync(new URL('./fixtures/d3200-public-leaf.der',import.meta.url)));
let isBound=false;
let peer=leaf, sends=[],closed=false,callbacks={},events=[];
globalThis.__recorderTest={
 concat:(a,b)=>new Uint8Array([...a,...b]),hex:b=>Buffer.from(b).toString('hex'),sha:async b=>new Uint8Array(createHash('sha256').update(b).digest()),
 util:{Base64Helper:class {encodeToStringSync(b){return Buffer.from(b).toString('base64');}decodeSync(s){return new Uint8Array(Buffer.from(s,'base64'));}}},
 cryptoFramework:{createRandom:()=>({generateRandom:async n=>({data:new Uint8Array(randomBytes(n))})}),createMd:()=>{let h=createHash('sha1');return{update:async({data})=>{h.update(data);},digest:async()=>({data:new Uint8Array(h.digest())})};}},
 socket:{Protocol:{TLSv12:'TLSv1.2'},constructTLSSocketInstance:()=>{isBound=false;return({
 on:(n,fn)=>{assert.equal(isBound,true,"bind must precede TLS listeners");callbacks[n]=fn;},bind:async()=>{isBound=true;},connect:async o=>{assert.equal(o.skipRemoteValidation,true);events.push('tls');},getRemoteCertificate:async()=>{events.push('pin');return{encodingFormat:0,data:peer};},
 send:async(data)=>{sends.push(data);events.push('send');if(typeof data==='string'){
 const key=data.match(/Sec-WebSocket-Key: (.+)\r\n/)[1];const accept=createHash('sha1').update(key+'258EAFA5-E914-47DA-95CA-C5AB0DC85B11').digest('base64');
 const response=Buffer.from(`HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: keep-alive, Upgrade\r\nSec-WebSocket-Accept: ${accept}\r\n\r\n`);
 callbacks.message({message:Uint8Array.from(response).buffer});
 }},close:async()=>{closed=true;}
 });}}
};
let source=readFileSync(new URL('../harmony/standard-overlay/services/RecorderWebSocket.ets',import.meta.url),'utf8').replace(/^import .*;\n/gm,'');
source='const {socket,cryptoFramework,util,concat,hex,sha}=globalThis.__recorderTest;\n'+source;
const {RecorderWebSocket,RecorderFrames,verifyRecorderCertificate,maskedFrame,verifyUpgrade}=await import('data:text/javascript;base64,'+Buffer.from(stripTypeScriptTypes(source)).toString('base64'));
test('pin accepts captured expired certificate DER and PEM; rejects changed certificate',async()=>{
 await verifyRecorderCertificate({data:leaf,encodingFormat:0});
 await verifyRecorderCertificate({data:new Uint8Array(readFileSync(new URL('./fixtures/d3200-public-leaf.pem',import.meta.url))),encodingFormat:1});
 await assert.rejects(verifyRecorderCertificate({data:leaf.slice(1),encodingFormat:0}),/PIN_MISMATCH/);
});
test('wrong peer sends no upgrade, file request or FINISH and closes socket',async()=>{
 peer=leaf.slice(1);sends=[];closed=false;events=[];const ws=new RecorderWebSocket();
 await assert.rejects(ws.connect('192.168.43.1',443,()=>{},()=>{}),/PIN_MISMATCH/);
 await assert.rejects(ws.send('FINISH'),/NOT_READY/);assert.equal(sends.length,0);assert.equal(closed,true);assert.deepEqual(events,['tls','pin']);
});
test('same TLS session verifies pin before upgrade, masks client frames and delivers fragmented messages',async()=>{
 peer=leaf;sends=[];closed=false;events=[];const ws=new RecorderWebSocket(),received=[];
 await ws.connect('192.168.43.1',443,b=>received.push([...b]),e=>assert.fail(e));
 assert.deepEqual(events,['tls','pin','send']);
 callbacks.message({message:new Uint8Array([1,2,97,98,128,2,99,100]).buffer});assert.deepEqual(received,[[171,205]]);
 await ws.send('FINISH');const f=new Uint8Array(sends[1]);assert.equal(f[0],129);assert.equal(f[1],134);assert.equal(Buffer.from(f.slice(6).map((v,i)=>v^f[2+i%4])).toString(),'FINISH');
 ws.cancel();await assert.rejects(ws.send('file'),/NOT_READY/);await ws.close();assert.equal(closed,true);
});
test('compatibility refuses other endpoints before constructing a connection',async()=>{
 events=[];await assert.rejects(new RecorderWebSocket().connect('example.com',443,()=>{},()=>{}),/ENDPOINT_NOT_ALLOWED/);assert.deepEqual(events,[]);
});
test('split headers, coalesced frames, ping within fragments and invalid lengths',()=>{
 const p=new RecorderFrames();assert.deepEqual(p.push(new Uint8Array([2])),[]);assert.deepEqual(p.push(new Uint8Array([2,1,2,137,1,7,128,1,3])),[{opcode:9,data:new Uint8Array([7])},{opcode:2,data:new Uint8Array([1,2,3])}]);
 for(const b of [[130,128],[128,0],[137,126,0,126],[130,127,0,0,0,1,0,0,0,0],[194,0]])assert.throws(()=>new RecorderFrames().push(new Uint8Array(b)));
 assert.deepEqual([...maskedFrame(1,new Uint8Array([1,2]),new Uint8Array([5,6,7,8]))],[129,130,5,6,7,8,4,4]);
});
test('upgrade rejects wrong accept, extension negotiation and non-upgrade status',()=>{
 const h='HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: websocket\r\nSec-WebSocket-Accept: expected';
 verifyUpgrade(h,'expected');assert.throws(()=>verifyUpgrade(h,'other'));assert.throws(()=>verifyUpgrade(h+'\r\nSec-WebSocket-Extensions: deflate','expected'));assert.throws(()=>verifyUpgrade(h.replace('101','200'),'expected'));
});
