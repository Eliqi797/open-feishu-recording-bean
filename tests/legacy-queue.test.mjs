import test from 'node:test';import assert from 'node:assert/strict';import * as fs from 'node:fs';import {tmpdir} from 'node:os';import {join} from 'node:path';import {stripTypeScriptTypes} from 'node:module';
const source=fs.readFileSync(new URL('../harmony/entry/src/main/ets/services/NativePorts.ets',import.meta.url),'utf8');
globalThis.__legacy={fs:{accessSync:fs.existsSync,mkdirSync:fs.mkdirSync,readTextSync:p=>fs.readFileSync(p,'utf8')},writeFile:(p,s)=>fs.writeFileSync(p,s)};
const code='const {fs,writeFile}=globalThis.__legacy;\n'+source.slice(source.indexOf('export class NativeCache'),source.indexOf('export class NativeCloud'));
const {NativeCache}=await import('data:text/javascript;base64,'+Buffer.from(stripTypeScriptTypes(code)).toString('base64'));
test('legacy MAC queues are preserved separately, never uploaded under an invented identity',()=>{
 const dir=fs.mkdtempSync(join(tmpdir(),'bean-legacy-'));try{
  const cache=new NativeCache(dir),stable={deviceId:'d3200-sn-'+'a'.repeat(64),sourceId:'1790335527',title:'a'},legacy={...stable,deviceId:'AA:BB:CC:DD:EE:01'};
  cache.savePendingBatch('https://example.test',[legacy,stable]);assert.deepEqual(cache.pendingBatch('https://other.test'),[]);
  assert.deepEqual(cache.pendingBatch('https://example.test'),[stable]);assert.deepEqual(cache.pendingBatch('https://example.test'),[stable]);
  const preserved=fs.readdirSync(cache.root).filter(n=>n.startsWith('legacy-batch-'));assert.equal(preserved.length,1);
  assert.deepEqual(JSON.parse(fs.readFileSync(join(cache.root,preserved[0]))).sources,[legacy,stable]);
 }finally{fs.rmSync(dir,{recursive:true});}
});
