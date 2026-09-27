import test from 'node:test';import assert from 'node:assert/strict';import {createHash} from 'node:crypto';
import {deviceSerial} from '../harmony/shared/D3200Protocol.ts';
function info(sn){const b=new Uint8Array(56);b.set(Buffer.from(sn),8);return b;}
test('stable identity comes from SN and ignores transport, battery, firmware and case changes',()=>{
 const a=info('D3200AB123456789'),b=info('d3200ab123456789');a[1]=9;b[1]=3;a[39]=1;b[39]=9;
 assert.equal(deviceSerial(a),deviceSerial(b));assert.notEqual(deviceSerial(a),deviceSerial(info('D3200AB123456788')));
 const hash=p=>'d3200-sn-'+createHash('sha256').update(deviceSerial(p)).digest('hex');assert.equal(hash(a),hash(b));
});
test('missing, padded, placeholder and malformed identities fail closed',()=>{
 for(const bytes of [new Uint8Array(),new Uint8Array(56),info('FFFFFFFFFFFFFFFF'),info('0000000000000000'),info('unknown'),info('BAD\u0001SERIAL001234'),info('1234567890123456')])assert.throws(()=>deviceSerial(bytes),/STABLE_ID_UNAVAILABLE/);
 assert.equal(deviceSerial(info('ABCD12345678')),'abcd12345678');
});
