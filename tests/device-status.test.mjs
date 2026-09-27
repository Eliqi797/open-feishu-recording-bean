import {test} from 'node:test';
import assert from 'node:assert/strict';
import {batteryPercent,deviceInfoStatus} from '../harmony/shared/D3200Protocol.ts';
test('battery buckets, literal percentages and invalid values remain distinct',()=>{
 assert.equal(batteryPercent(0),10);assert.equal(batteryPercent(9),100);assert.equal(batteryPercent(47),47);
 for(const n of [undefined,255,-1,101,1.5])assert.equal(batteryPercent(n),null);
});
test('truncated info never invents empty batteries or idle state',()=>{
 assert.deepEqual(deviceInfoStatus(new Uint8Array()),{battery:null,charging:null,caseBattery:null,caseCharging:null,recording:-1});
 const data=new Uint8Array(51).fill(255);data[1]=8;data[2]=1;data[32]=0;data[38]=6;data[50]=1;
 assert.deepEqual(deviceInfoStatus(data),{battery:90,charging:true,caseBattery:70,caseCharging:false,recording:1});
});
