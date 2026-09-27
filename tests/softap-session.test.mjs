import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {stripTypeScriptTypes} from 'node:module';
import {concat,le} from '../harmony/shared/D3200Protocol.ts';
const state={joins:0,removes:0,restores:0,ssid:'',sockets:[]};
class MockSocket{
 async connect(ip,port,receive,fail){this.fail=fail;this.sent=[];state.sockets.push(this);}
 async send(s){this.sent.push(s);return true;}
 async close(){} cancel(){}
}
const net={netId:7};
globalThis.__ap={concat,le,hex:b=>Buffer.from(b).toString('hex'),RecorderWebSocket:MockSocket,
 cryptoFramework:{createRandom:()=>({generateRandom:async n=>({data:new Uint8Array(n).fill(1)})})},
 wifiManager:{WifiSecurityType:{WIFI_SEC_TYPE_PSK:2},addCandidateConfig:async c=>{state.ssid=c.ssid;return 1;},connectToCandidateConfigWithUserAction:async()=>{state.joins++;},getLinkedInfo:async()=>({ssid:state.ssid}),removeCandidateConfig:async()=>{state.removes++;}},
 socket:{constructUDPSocketInstance:()=>({bind:async()=>{},send:async()=>{},close:async()=>{}})},
 connection:{NetBearType:{BEARER_WIFI:1},getDefaultNet:async()=>net,getAppNet:async()=>({netId:0}),getAllNets:async()=>[net],getNetCapabilities:async()=>({bearerTypes:[1]}),getConnectionProperties:async()=>({interfaceName:'wlan0',linkAddresses:[{address:{address:'192.168.43.2'},prefixLength:24}]}),setAppNet:async n=>{if(!n.netId)state.restores++;}},webSocket:{}};
const source='const {concat,le,hex,RecorderWebSocket,cryptoFramework,wifiManager,socket,connection,webSocket}=globalThis.__ap;\n'+readFileSync(new URL('../harmony/standard-overlay/services/SoftAp.ets',import.meta.url),'utf8').replace(/^import .*;\n/gm,'');
const {SoftAp}=await import('data:text/javascript;base64,'+Buffer.from(stripTypeScriptTypes(source)).toString('base64'));
test('two files share one Wi-Fi authorization; socket recovery retains Wi-Fi and final cleanup runs once',async()=>{
 const errors=[],ap=new SoftAp();await ap.credentials();
 try{
  await ap.connect(new Uint8Array([1,43,168,192,187,1]),()=>{},e=>errors.push(e));
  await ap.request(123);await ap.request(456);assert.equal(state.joins,1);assert.equal(state.sockets.length,1);assert.equal(state.removes,0);
  state.sockets[0].fail('D3200_PIN_TLS_CLOSED');await ap.request(789);
  assert.equal(state.joins,1);assert.equal(state.sockets.length,2);assert.equal(state.removes,0);
  state.sockets[0].fail('late close');assert.deepEqual(errors,['D3200_PIN_TLS_CLOSED']);
 }finally{await ap.close();}
 assert.equal(state.removes,1);assert.equal(state.restores,1);assert.equal(state.sockets[1].sent.at(-1),'FINISH');
});
