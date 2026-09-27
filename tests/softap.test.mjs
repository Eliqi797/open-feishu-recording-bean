import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {stripTypeScriptTypes} from 'node:module';
const callbacks={};
let removed=false,netReads=0;const bound=[];
globalThis.__softApTest={
 wifiManager:{WifiSecurityType:{WIFI_SEC_TYPE_PSK:2},addCandidateConfig:async()=>3,connectToCandidateConfigWithUserAction:async()=>{},getLinkedInfo:async()=>({ssid:'Bean-test'}),removeCandidateConfig:async()=>{removed=true;}},
 connection:{NetBearType:{BEARER_WIFI:1},getDefaultNet:async()=>({netId:101}),getAppNet:async()=>null,getAllNets:async()=>++netReads<3?[{netId:101}]:[{netId:101},{netId:301}],getNetCapabilities:async n=>({bearerTypes:[n.netId===101?0:1]}),getConnectionProperties:async n=>({interfaceName:n.netId===101?'rmnet0':'wlan0',linkAddresses:[{address:{address:n.netId===101?'10.0.0.1':'192.168.4.2'},prefixLength:24}]}),setAppNet:async n=>{bound.push(n.netId);}},
 socket:{constructUDPSocketInstance:()=>({bind:async()=>{},send:async()=>{},close:async()=>{}})},
 webSocket:{createWebSocket:()=>({on:(name,callback)=>{callbacks[name]=callback;},connect:async()=>{assert.deepEqual(bound,[301]);callbacks.error({code:200});return true;},send:async()=>true,close:async()=>{}})}
};
let source=readFileSync(new URL('../harmony/standard-overlay/services/SoftAp.ets',import.meta.url),'utf8');
source=source.replace(/^import .*;\n/gm,'');
source='const {wifiManager,socket,webSocket,connection}=globalThis.__softApTest;\n'+source;
const {SoftAp,sameIpv4Subnet}=await import('data:text/javascript;base64,'+Buffer.from(stripTypeScriptTypes(source)).toString('base64'));
test('platform WebSocket error without message is reported and cleans up instead of throwing in callback',async()=>{
 const ap=new SoftAp();ap.ssid='Bean-test';const failures=[];
 try{await assert.rejects(ap.connect(new Uint8Array([1,4,168,192,80,0]),()=>{},reason=>failures.push(reason)),/D3200_WIFI_WS_ERROR_200:.*code.*200/);}
 finally{await ap.close();}
 assert.equal(failures.length,1);assert.equal(removed,true);assert.deepEqual(bound,[301,0]);assert.ok(netReads>=3);
});

test('hotspot routing uses the actual IPv4 prefix and rejects unrelated interfaces',()=>{
 assert.equal(sameIpv4Subnet('192.168.43.12',24,'192.168.43.1'),true);
 assert.equal(sameIpv4Subnet('192.168.42.12',23,'192.168.43.1'),true);
 for(const [ip,prefix] of [['10.0.0.1',24],['0.0.0.0',24],['192.168.43.1',24],['192.168.43.999',24],['fe80::1',64],['192.168.43.12',0]])assert.equal(sameIpv4Subnet(ip,prefix,'192.168.43.1'),false);
});

test('cancel interrupts waiting for a usable hotspot route',async()=>{
 const ap=new SoftAp();ap.ssid='Bean-test';ap.cancel();
 await assert.rejects(ap.bindHotspotNetwork('192.168.4.1'),/SYNC_CANCELLED/);
});
