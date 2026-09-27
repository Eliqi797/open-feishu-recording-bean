// Exercise the actual ArkTS crypto logic with Node/OpenSSL implementing the native
// API surface. This does not claim HarmonyOS native API or device acceptance.
import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {stripTypeScriptTypes} from 'node:module';
import {createHash,createPublicKey,createPrivateKey,generateKeyPairSync,diffieHellman,createDecipheriv,createCipheriv,createHmac} from 'node:crypto';

const spki=Buffer.from('3059301306072a8648ce3d020106082a8648ce3d030107034200','hex');
function pair(publicKey,privateKey){return {pubKey:publicKey?{key:publicKey,getEncoded:()=>({data:new Uint8Array(publicKey.export({format:'der',type:'spki'}))})}:null,priKey:privateKey?{key:privateKey}:null};}
globalThis.__recordingBeanCryptoAdapter={
 CryptoMode:{DECRYPT_MODE:1},
 createSymKeyGenerator:()=>({convertKey:async({data})=>({data})}),
 createCipher:()=>{let cipher;return{init:async(mode,key,spec)=>{cipher=createDecipheriv('aes-256-ctr',key.data,spec.iv.data);},doFinal:async({data})=>({data:new Uint8Array(Buffer.concat([cipher.update(data),cipher.final()]))})};},
 createAsyKeyGenerator:()=>({
  generateKeyPair:async()=>{const p=generateKeyPairSync('ec',{namedCurve:'prime256v1'});return pair(p.publicKey,p.privateKey);},
  convertKey:async(pub,pri)=>{const privateKey=pri?createPrivateKey({key:Buffer.from(pri.data),format:'der',type:'pkcs8'}):null;return pair(pub?createPublicKey({key:Buffer.from(pub.data),format:'der',type:'spki'}):createPublicKey(privateKey),privateKey);}
 }),
 createKeyAgreement:()=>({generateSecret:async(pri,pub)=>({data:new Uint8Array(diffieHellman({privateKey:pri.key,publicKey:pub.key}))})}),
 createMd:()=>{const md=createHash('sha256');return {update:async(blob)=>{md.update(blob.data);},digest:async()=>({data:new Uint8Array(md.digest())})};}
};
let source=readFileSync(new URL('../harmony/entry/src/main/ets/services/DeviceCrypto.ets',import.meta.url),'utf8');
source=source.replace("import { cryptoFramework } from '@kit.CryptoArchitectureKit';",'const cryptoFramework=globalThis.__recordingBeanCryptoAdapter;');
source=source.replace(', AudioSlice','');
source=source.replace("'./D3200Protocol'",JSON.stringify(new URL('../harmony/shared/D3200Protocol.ts',import.meta.url).href));
const {DeviceCrypto}=await import('data:text/javascript;base64,'+Buffer.from(stripTypeScriptTypes(source)).toString('base64'));
delete globalThis.__recordingBeanCryptoAdapter;

async function exchange(){
 const device=new DeviceCrypto(),appPoint=await device.publicKey();
 const peer=generateKeyPairSync('ec',{namedCurve:'prime256v1'});
 const appKey=createPublicKey({key:Buffer.concat([spki,appPoint]),format:'der',type:'spki'});
 const secret=diffieHellman({privateKey:peer.privateKey,publicKey:appKey});
 const payload=new Uint8Array(Buffer.concat([peer.publicKey.export({format:'der',type:'spki'}).subarray(-65),secret]));
 return {device,secret,payload,appPoint};
}
test('actual handshake logic accepts an independent OpenSSL P-256 peer',async()=>{
 const {device,payload,secret}=await exchange();await device.handshake(payload);
 assert.match(device.diagnostics,/原值匹配=true/);assert.ok(!device.diagnostics.includes(secret.toString('hex')));
});
test('mismatching device check remains rejected with secret-free diagnostics',async()=>{
 const {device,payload,secret}=await exchange();payload[65]^=1;
 await assert.rejects(device.handshake(payload),/SHARED_SECRET_MISMATCH/);
 assert.match(device.diagnostics,/原值匹配=false/);assert.ok(!device.diagnostics.includes(secret.toString('hex')));
});
test('fresh session keys stay random and malformed handshake cannot proceed',async()=>{
 const device=new DeviceCrypto(),first=await device.publicKey(),second=await device.publicKey();
 assert.notDeepEqual(first,second);await assert.rejects(device.handshake(new Uint8Array(96)),/HANDSHAKE_INVALID/);
});

test('batch CTR decrypt is byte-identical to individual packets and rejects sequence gaps',async()=>{
 const {device,payload,secret}=await exchange();await device.handshake(payload);
 const hmac=(k,v)=>createHmac('sha256',k).update(v).digest();
 const session=hmac(hmac(Buffer.from([1,2,3]),secret),Buffer.from([1,2,3,1]));
 const key=Buffer.alloc(32,17),nonce=Buffer.alloc(16,9),iv=Buffer.alloc(16,7);
 const encrypt=(k,iv,b)=>{const c=createCipheriv('aes-256-ctr',k,iv);return Buffer.concat([c.update(b),c.final()]);};
 const header=new Uint8Array(87);header.set(nonce,8);header.set(encrypt(session,iv,Buffer.concat([Buffer.from('soundcored3200'),key])),24);header.set(iv,70);
 await device.file(header);
 const packets=Array.from({length:24},(_,i)=>{const sequence=700000+i,counter=Buffer.from(nonce);counter.writeUInt32BE(sequence*10,12);return{sequence,encrypted:new Uint8Array(encrypt(key,counter,Buffer.alloc(160,i)))};});
 const separate=Buffer.concat(await Promise.all(packets.map(p=>device.decrypt(p.sequence,p.encrypted))));
 assert.deepEqual(Buffer.from(await device.decryptBatch(packets)),separate);
 assert.deepEqual(separate,Buffer.concat(packets.map((p,i)=>Buffer.alloc(160,i))));
 const broken=packets.map(p=>({...p}));broken[4].sequence++;await assert.rejects(device.decryptBatch(broken),/SEQUENCE_GAP/);
 await assert.rejects(device.decryptBatch([]),/BATCH_INVALID/);
});
