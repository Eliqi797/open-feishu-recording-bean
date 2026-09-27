import test from 'node:test';
import assert from 'node:assert/strict';
import {command,FrameDecoder,fileList,le,concat,slices,counter,oggPage,opusHeaders,offlineTransferSize,recordingState} from '../harmony/shared/D3200Protocol.ts';
function rx(payload) {const b=new Uint8Array(payload.length+10);b.set([9,255,0,0,1,26,14]);b.set(le(b.length,2),7);b.set(payload,9);b[b.length-1]=b.slice(0,-1).reduce((a,b)=>(a+b)&255,0);return b;}
test('fragmented and coalesced frames have bounded validated parsing',()=>{const frame=rx(concat(le(1,2),concat(le(123),le(166))));const d=new FrameDecoder();assert.deepEqual(d.push(frame.slice(0,8)),[]);const result=d.push(concat(frame.slice(8),frame));assert.equal(result.length,2);assert.deepEqual(fileList(result[0].payload),[{id:123,transferBytes:166}]);frame[10]^=1;assert.throws(()=>d.push(frame),/CHECKSUM/)});
test('destructive and unknown commands are unreachable',()=>{for(const [t,i] of [[26,16],[11,135],[1,184]])assert.throws(()=>command(t,i),/NOT_ALLOWED/);assert.equal(command(26,14,le(0,2)).length,12)});
test('truncated lists/slices rejected and counters use packet sequence',()=>{assert.throws(()=>fileList(new Uint8Array([2,0,0])),/TRUNCATED/);assert.throws(()=>slices(new Uint8Array(165)),/UNVERIFIED/);assert.equal(new DataView(counter(new Uint8Array(16),7).buffer).getUint32(12),70);assert.throws(()=>counter(new Uint8Array(16),429496730),/INVALID/)});
test('Ogg headers and packet payload are preserved, including trailing zeros',()=>{assert.equal(new TextDecoder().decode(opusHeaders().slice(0,4)),'OggS');const b=oggPage(new Uint8Array(160),2,960,4);assert.equal(b[5],4);assert.equal(b[27],160);assert.equal(b.length,188);assert.equal(new DataView(b.buffer).getUint32(6,true),960)});
test('an unfinished recording length is never treated as a 4 GB completed file',()=>{
 assert.throws(()=>offlineTransferSize(0xffffffff),/RECORDING_NOT_FINALIZED/);
 for(const size of [0,-1,NaN,Infinity,1.5,0x100000000])assert.throws(()=>offlineTransferSize(size),/FILE_SIZE_INVALID/);
 assert.equal(offlineTransferSize(166*5000),830000);
});

test('device recording state stays unknown for short or unrecognized firmware fields',()=>{
 assert.equal(recordingState(new Uint8Array(50)),-1);
 const payload=new Uint8Array(56);assert.equal(recordingState(payload),0);
 payload[50]=1;assert.equal(recordingState(payload),1);
 payload[50]=255;assert.equal(recordingState(payload),-1);
});
