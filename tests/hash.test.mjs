import test from 'node:test';
import assert from 'node:assert/strict';
import {createHash, randomBytes} from 'node:crypto';
import {SHA256} from '../web/sha256.js';
for(const size of [0,1,3,55,56,63,64,65,1000,1048583]){
 test(`incremental file hash agrees with native SHA-256 (${size} bytes)`,()=>{
  const bytes=randomBytes(size);const hasher=new SHA256();
  for(let i=0;i<size;i+=317)hasher.update(bytes.subarray(i,i+317));
  assert.equal(hasher.hex(),createHash('sha256').update(bytes).digest('hex'));
 });
}
