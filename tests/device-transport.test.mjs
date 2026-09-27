// Exercise real transport control flow with only platform boundaries replaced.
import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {stripTypeScriptTypes} from 'node:module';

let disconnects=0,closes=0;
class Crypto { diagnostics=''; clear(){} }
class Wifi {
 async credentials(){return new Uint8Array(1);}
 async connect(){}
 async request(){throw new Error('ORIGINAL_TRANSFER_FAILURE');}
 async close(){throw new Error('SECONDARY_CLEANUP_FAILURE');}
}
const sdk={
 ble:{createGattClientDevice:()=>({on(){},off(){},connect(){throw new Error('CONNECT_REFUSED');},disconnect(){disconnects++;},close(){closes++;}})},
 constant:{ProfileConnectionState:{STATE_CONNECTED:2,STATE_DISCONNECTED:0}},
 fs:{OpenMode:{CREATE:1,READ_WRITE:2,TRUNC:4},openSync:()=>({fd:1}),closeSync(){}},
 statfs:{getFreeSize:async()=>1e9},Crypto,Wifi
};
globalThis.__beanTransportTest=sdk;
let source=readFileSync(new URL('../harmony/standard-overlay/services/D3200Device.ets',import.meta.url),'utf8');
source=source.replace("import { ble, constant } from '@kit.ConnectivityKit';",'const {ble,constant}=globalThis.__beanTransportTest;')
 .replace("import { fileIo as fs, statfs } from '@kit.CoreFileKit';",'const {fs,statfs}=globalThis.__beanTransportTest;')
 .replace("import { DevicePort, RecordingRef, LocalAudio } from './SyncController';",'')
 .replace("import { DeviceCrypto, sha, hex } from './DeviceCrypto';",'const DeviceCrypto=globalThis.__beanTransportTest.Crypto;')
 .replace("import { NativeCache, hashFile, writeBytes, writeFile } from './NativePorts';",'const hashFile=async()=>"hash";const writeBytes=()=>{};const writeFile=()=>{};')
 .replace("import { SoftAp } from './SoftAp';",'const SoftAp=globalThis.__beanTransportTest.Wifi;')
 .replace("import { TransferInbox } from './TransferInbox';",'class TransferInbox {close(){} append(){} next(){return undefined;}}')
 .replace('Frame, FrameDecoder, DeviceFile,','FrameDecoder,')
 .replace("'./D3200Protocol'",JSON.stringify(new URL('../harmony/shared/D3200Protocol.ts',import.meta.url).href))
 .replace("'./LiveAudio'",JSON.stringify(new URL('../harmony/shared/LiveAudio.ts',import.meta.url).href));
const {D3200Device}=await import('data:text/javascript;base64,'+Buffer.from(stripTypeScriptTypes(source)).toString('base64'));

const make=()=>new D3200Device({root:'/test'},()=>{});
test('Wi-Fi cleanup cannot replace the original transfer failure',async()=>{
 const device=make();device.deviceId='test';device.useWifi=true;
 device.readRecordingState=async()=>{};
 device.send=async(bytes)=>{if(bytes[6]===2)throw new Error('BLE_ALREADY_DISCONNECTED');};
 device.next=async()=>({payload:new Uint8Array(6)});
 await assert.rejects(device.downloadAndDecrypt({deviceId:'test',sourceId:'123',title:'test'}),/ORIGINAL_TRANSFER_FAILURE/);
 assert.equal(device.wifi,undefined);
 assert.equal(device.cancelled,true);
});
test('BLE disconnect only stops transfer when no Wi-Fi handoff is active',()=>{
 const device=make();device.wifi={};device.state({state:0});assert.equal(device.fault,'');
 device.wifi=undefined;device.state({state:0});assert.equal(device.fault,'D3200_DISCONNECTED');
});
test('failed connection releases native GATT resources',async()=>{
 const device=make();disconnects=0;closes=0;
 await assert.rejects(device.connect('test'),/CONNECT_REFUSED/);
 assert.equal(disconnects,1);assert.equal(closes,1);assert.equal(device.client,undefined);
});
