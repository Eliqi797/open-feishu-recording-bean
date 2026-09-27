import test from 'node:test';
import assert from 'node:assert/strict';
import {deviceActivity,deviceBattery,deviceConnection} from '../harmony/shared/DevicePresentation.ts';
test('global status never presents stale disconnected battery or recording as current',()=>{
 assert.equal(deviceBattery('disconnected',100,true),'—');assert.equal(deviceActivity('disconnected',1,false,'idle',false),'等待连接');
 assert.equal(deviceConnection('connecting'),'连接中');assert.equal(deviceBattery('ready',null,null),'未知');assert.equal(deviceBattery('ready',NaN,false),'未知');
});
test('connected battery preserves unknown fields, charging, zero and hotspot state',()=>{
 assert.equal(deviceBattery('ready',0,false),'约 0%');assert.equal(deviceBattery('transferring',40,true),'约 40% · 充电中');assert.equal(deviceActivity('ready',-1,false,'idle',false),'录音状态未知');assert.equal(deviceActivity('ready',1,false,'idle',false),'正在录音');
});
test('global cloud transfer stays visible after Bluetooth disconnect',()=>{
 assert.equal(deviceActivity('disconnected',-1,true,'uploading',false),'上传云端中');assert.equal(deviceActivity('ready',0,true,'retrying',false),'网络重试中');assert.equal(deviceActivity('ready',1,false,'idle',true),'实时转写中');
});
