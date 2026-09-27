import test from 'node:test';
import assert from 'node:assert/strict';
import {TransferSpeed,transferBytes} from '../harmony/shared/TransferProgress.ts';
test('transfer speed uses byte deltas, resets per file and drops to zero when stalled',()=>{
 const meter=new TransferSpeed();meter.reset(0);meter.add(1000,2048);assert.equal(meter.value(1000),2048);meter.add(1500,2048);assert.equal(meter.value(3600),0);
 meter.reset(4000,50000);meter.add(5000,51024);assert.equal(meter.value(5000),1024);meter.add(6000,200);assert.equal(meter.value(6000),0);
});
test('sizes and throughput labels switch consistently across B KB MB',()=>{assert.equal(transferBytes(512),'512 B');assert.equal(transferBytes(2048),'2.0 KB');assert.equal(transferBytes(1048576),'1.0 MB');assert.equal(transferBytes(NaN),'0 B');});
