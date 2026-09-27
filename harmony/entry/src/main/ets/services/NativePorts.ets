import { media } from '@kit.MediaKit';
import BuildProfile from 'BuildProfile';
import { BusinessError } from '@kit.BasicServicesKit';
import { cloudOriginAllowed } from './CloudPolicy';
import { LiveStatus, LiveAck } from './LiveController';
import { util } from '@kit.ArkTS';
import { fileIo as fs } from '@kit.CoreFileKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { http } from '@kit.NetworkKit';
import { CachePort, CloudPort, RecordingRef, LocalAudio, Chunk, SyncJournal, UploadSession, Receipt } from './SyncController';
import { sha, hex } from './DeviceCrypto';

interface UsbRequest { path:string; method:string; body:string; binary:boolean; sha256:string; duration:number; }
interface UsbResponse { status:number; body:string; }
interface TransferSource {source:RecordingRef;path:string;}
interface PendingBatch {endpoint:string;sources:RecordingRef[];}
interface CacheEntry { source: RecordingRef; audio: LocalAudio; }
interface BeginBody { recorded_at:number|null; device_id: string; source_id: string; title: string; mime: string; size: number; sha256: string; }
interface RequestHeaders { Authorization: string; 'Content-Type': string; 'X-Chunk-SHA256': string; 'X-Audio-Duration-Ms':string; }
export interface ProviderSettings {revision:number;values:Record<string,string>;secrets_configured:Record<string,boolean>;}
interface SettingsUpdate {revision:number;values:Record<string,string>;clear_secrets:string[];}
export interface CloudJob {stage:string;status:string;error:string|null;}
export interface CloudDocument {document_id:string|null;status:string;title:string;}
export interface CloudRecording {source_devices?:string[];device_id:string;source_id:string;sha256:string;recorded_at:number|null;created:number;id:string;title:string;size:number;stored:number;jobs:CloudJob[];publications:CloudDocument[];}
interface CloudListing {recordings:CloudRecording[];}
export interface CloudAction {task:string;owner:string|null;due_date:string|null;}
export interface CloudSummary {summary:string;decisions:string[];actions:CloudAction[];uncertainties:string[];}
export interface CloudTranscript {text:string;coverage?:CloudCoverage;}
interface CloudCoverage {status:string;}
export function writeBytes(fd: number, bytes: Uint8Array): void {
  let offset=0;
  while(offset<bytes.length){const count=fs.writeSync(fd,bytes.slice(offset).buffer as ArrayBuffer);if(count<=0)throw new Error('CACHE_WRITE_INCOMPLETE');offset+=count;}
}
export function writeFile(path: string, data: string | ArrayBuffer): void {
  const file = fs.openSync(path + '.tmp', fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
  try {writeBytes(file.fd,typeof data==='string'?new util.TextEncoder().encodeInto(data):new Uint8Array(data));fs.fsyncSync(file.fd);} finally {fs.closeSync(file);}
  fs.renameSync(path + '.tmp', path);
}
export async function hashFile(path: string): Promise<string> {
  const file = fs.openSync(path, fs.OpenMode.READ_ONLY), md = cryptoFramework.createMd('SHA256');
  try {const buffer = new ArrayBuffer(1024 * 1024);let got = 0;do {got = fs.readSync(file.fd, buffer);if (got > 0) await md.update({data: new Uint8Array(buffer.slice(0, got))});} while (got > 0);} finally {fs.closeSync(file);}
  return hex((await md.digest()).data);
}
export class NativeCache implements CachePort {
  root: string;
  constructor(filesDir: string) {this.root = filesDir + '/recordings';if (!fs.accessSync(this.root)) fs.mkdirSync(this.root);}
  private async entryPath(source: RecordingRef): Promise<string> {
    const bytes: number[] = [];
    const key = source.deviceId + ':' + source.sourceId;
    for (let i=0;i<key.length;i++) {bytes.push(key.charCodeAt(i) & 255);bytes.push(key.charCodeAt(i) >>> 8);}
    return this.root + '/' + hex(await sha(new Uint8Array(bytes))) + '.json';
  }
  async findVerified(source: RecordingRef): Promise<LocalAudio | undefined> {
    const path = await this.entryPath(source); if (!fs.accessSync(path)) return undefined;
    const entry = JSON.parse(fs.readTextSync(path)) as CacheEntry;
    if (entry.source.deviceId !== source.deviceId || entry.source.sourceId !== source.sourceId || !entry.audio.path.startsWith(this.root + '/') || entry.audio.path.includes('..')) throw new Error('CACHE_METADATA_INVALID');
    if (!fs.accessSync(entry.audio.path)) return undefined;
    if (fs.statSync(entry.audio.path).size !== entry.audio.size || await hashFile(entry.audio.path) !== entry.audio.sha256) throw new Error('CACHE_CHECKSUM_MISMATCH');
    return entry.audio;
  }
  async retain(source: RecordingRef, audio: LocalAudio): Promise<void> {
    if (await hashFile(audio.path) !== audio.sha256 || fs.statSync(audio.path).size !== audio.size) throw new Error('CACHE_CHECKSUM_MISMATCH');
    const entry: CacheEntry = {source, audio}; writeFile(await this.entryPath(source), JSON.stringify(entry));
  }
  async chunk(audio: LocalAudio, offset: number, length: number): Promise<Chunk> {
    if (length < 1 || length > 4*1024*1024) throw new Error('CHUNK_SIZE_INVALID');
    const file = fs.openSync(audio.path, fs.OpenMode.READ_ONLY), buffer = new ArrayBuffer(length);
    try {if (fs.readSync(file.fd, buffer, {offset, length}) !== length) throw new Error('CACHE_TRUNCATED');} finally {fs.closeSync(file);}
    const bytes = new Uint8Array(buffer); return {bytes, sha256: hex(await sha(bytes))};
  }
  async remove(audio: LocalAudio, source?:RecordingRef): Promise<void> {
    const allowed=(path:string):boolean=>path.startsWith(this.root+'/')&&!path.includes('..')&&!path.slice(this.root.length+1).includes('/');
    if(!allowed(audio.path))throw new Error('CACHE_PATH_INVALID');
    if(source){
      for(const name of fs.listFileSync(this.root).filter((n:string)=>/^[0-9]+-(live-)?[0-9]+\.ogg\.source\.json$/.test(n))){
        const manifest=this.root+'/'+name;const entry=JSON.parse(fs.readTextSync(manifest)) as TransferSource;
        if(entry.source.deviceId!==source.deviceId||entry.source.sourceId!==source.sourceId)continue;
        if(!allowed(entry.path)||manifest!==entry.path+'.source.json')throw new Error('CACHE_PATH_INVALID');
        const base=entry.path.slice(this.root.length+1);
        for(const item of fs.listFileSync(this.root)){
          if(item===base+'.partial'||item===base+'.wire'||(item.startsWith(base+'.window-')&&item.endsWith('.ogg'))||(item===base&&entry.path!==audio.path))fs.unlinkSync(this.root+'/'+item);
        }
        fs.unlinkSync(manifest);
      }
    }
    if(fs.accessSync(audio.path))fs.unlinkSync(audio.path);
    if(fs.accessSync(audio.path+'.wire'))fs.unlinkSync(audio.path+'.wire');
    for(const name of fs.listFileSync(this.root).filter((n:string)=>/^[a-f0-9]{64}\.json$/.test(n))){
      const path=this.root+'/'+name;const entry=JSON.parse(fs.readTextSync(path)) as CacheEntry;
      if(entry.audio.path===audio.path)fs.unlinkSync(path);
    }
  }
  async pruneArchived(recordings:CloudRecording[]):Promise<number>{
    let removed=0;
    for(const name of fs.listFileSync(this.root).filter((n:string)=>/^[a-f0-9]{64}\.json$/.test(n))){
      const entry=JSON.parse(fs.readTextSync(this.root+'/'+name)) as CacheEntry;
      if(recordings.some((r:CloudRecording)=>!!r.stored&&r.sha256===entry.audio.sha256&&r.size===entry.audio.size)){
        await this.remove(entry.audio,entry.source);removed++;
      }
    }
    return removed;
  }
  async persist(journal: SyncJournal): Promise<void> {writeFile(this.root + '/last-sync.json', JSON.stringify(journal));}
  savePendingBatch(endpoint:string,sources:RecordingRef[]):void{const batch:PendingBatch={endpoint,sources};writeFile(this.root+'/pending-batch.json',JSON.stringify(batch));}
  pendingBatch(endpoint:string):RecordingRef[]{
    const path=this.root+'/pending-batch.json';if(!fs.accessSync(path))return [];
    const batch=JSON.parse(fs.readTextSync(path)) as PendingBatch;
    if(batch.endpoint!==endpoint)return [];
    if(!Array.isArray(batch.sources)||batch.sources.some((source:RecordingRef)=>!source.deviceId||!/^\d{9,10}$/.test(source.sourceId)))throw new Error('BATCH_JOURNAL_INVALID');
    // Pre-SN batches cannot safely identify a device. Preserve their complete manifest,
    // but require a fresh stable-device read instead of silently resuming under a MAC.
    const legacy=batch.sources.filter((source:RecordingRef)=>/^(?:[0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$/.test(source.deviceId));
    if(legacy.length){const preserved=this.root+'/legacy-batch-'+Date.now()+'.json';writeFile(preserved,JSON.stringify(batch));batch.sources=batch.sources.filter((source:RecordingRef)=>!legacy.includes(source));writeFile(path,JSON.stringify(batch));}
    return batch.sources;
  }
  lastJournal(): SyncJournal | undefined {const path=this.root+'/last-sync.json';return fs.accessSync(path) ? JSON.parse(fs.readTextSync(path)) as SyncJournal : undefined;}
}
export class NativeCloud implements CloudPort {
  private static usbRoot:string='';
  private static serial:number=0;
  static enableDebugUsb(filesDir:string):void{
    if(!BuildProfile.DEBUG)return;
    NativeCloud.usbRoot=filesDir+'/cloud-bridge';if(!fs.accessSync(NativeCloud.usbRoot))fs.mkdirSync(NativeCloud.usbRoot);
  }
  private async usbRequest(path:string,body:string|ArrayBuffer,hash:string,duration:number,get:boolean):Promise<string>{
    if(!BuildProfile.DEBUG||!NativeCloud.usbRoot)throw new Error('DEBUG_USB_NOT_AVAILABLE');
    const name=NativeCloud.usbRoot+'/r'+Date.now()+'-'+(++NativeCloud.serial);
    const request:UsbRequest={path,method:get?'GET':(hash?'PUT':'POST'),body:typeof body==='string'?body:new util.Base64Helper().encodeToStringSync(new Uint8Array(body)),binary:typeof body!=='string',sha256:hash,duration};
    writeFile(name+'.req.json',JSON.stringify(request));const deadline=Date.now()+90000;
    try{
      while(Date.now()<deadline){
        if(fs.accessSync(name+'.ready')){const response=JSON.parse(fs.readTextSync(name+'.res.json')) as UsbResponse;if(response.status!==200)throw new Error('CLOUD_HTTP_'+response.status);return response.body;}
        await new Promise<void>((resolve)=>{setTimeout(resolve,100);});
      }
      throw new Error('DEBUG_USB_RELAY_TIMEOUT');
    }finally{try{fs.unlinkSync(name+'.ready');}catch(_){}try{fs.unlinkSync(name+'.req.json');}catch(_){}try{fs.unlinkSync(name+'.res.json');}catch(_){}}
  }
  private origin: string;
  private token: string;
  constructor(origin: string, token: string) {
    this.origin = origin.replace(/\/$/, '');this.token = token;
    if (!cloudOriginAllowed(this.origin,BuildProfile.DEBUG) || token.length < 20) throw new Error('CLOUD_HTTPS_AND_TOKEN_REQUIRED');
  }
  private async request(path: string, body: string | ArrayBuffer, hash: string = '', duration:number=0, get:boolean=false,progress:((sent:number)=>void)|undefined=undefined): Promise<string> {
    if(this.origin==='usb://local')return this.usbRequest(path,body,hash,duration,get);
    const client = http.createHttp();
    if(progress)client.on('dataSendProgress',(info:http.DataSendProgressInfo)=>{progress(info.sendSize);});
    const headers: RequestHeaders = {Authorization: 'Bearer ' + this.token, 'Content-Type': hash ? 'application/octet-stream' : 'application/json', 'X-Chunk-SHA256': hash, 'X-Audio-Duration-Ms':String(duration)};
    try {
      const response = await client.request(this.origin + path, {method: get?http.RequestMethod.GET:(hash ? http.RequestMethod.PUT : http.RequestMethod.POST), header: headers, extraData: body, expectDataType: http.HttpDataType.STRING, connectTimeout: 15000, readTimeout: 90000, usingCache: false});
      if (response.responseCode !== 200) throw new Error('CLOUD_HTTP_' + response.responseCode);
      return response.result as string;
    } catch(error) {
      const code=(error as BusinessError).code;
      throw new Error(code?'CLOUD_NETWORK_'+code:(error as Error).message);
    } finally {client.destroy();}
  }
  async settings():Promise<ProviderSettings>{return JSON.parse(await this.request('/api/settings','', '',0,true)) as ProviderSettings;}
  async saveSettings(revision:number,values:Record<string,string>,clear:string[]):Promise<ProviderSettings>{const body:SettingsUpdate={revision:revision,values:values,clear_secrets:clear};return JSON.parse(await this.request('/api/settings',JSON.stringify(body))) as ProviderSettings;}
  endpoint():string{return this.origin;}
  private recordingPath(id:string):string{if(!/^[a-f0-9]{32}$/.test(id))throw new Error('RECORDING_ID_INVALID');return '/api/recordings/'+id;}
  async recordings():Promise<CloudRecording[]>{return (JSON.parse(await this.request('/api/recordings','','',0,true)) as CloudListing).recordings;}
  async recording(id:string):Promise<CloudRecording>{return JSON.parse(await this.request(this.recordingPath(id),'','',0,true)) as CloudRecording;}
  async pipeline(id:string):Promise<CloudRecording>{return JSON.parse(await this.request(this.recordingPath(id)+'/pipeline','{}')) as CloudRecording;}
  async summary(id:string):Promise<CloudSummary>{return JSON.parse(await this.request(this.recordingPath(id)+'/result/summary','','',0,true)) as CloudSummary;}
  async transcript(id:string):Promise<CloudTranscript>{return JSON.parse(await this.request(this.recordingPath(id)+'/result/asr','','',0,true)) as CloudTranscript;}
  audioSource(id:string):media.MediaSource{
    if(!this.origin.startsWith('https://'))throw new Error('PLAYBACK_HTTPS_REQUIRED');
    return media.createMediaSourceWithUrl(this.origin+this.recordingPath(id)+'/audio',{Authorization:'Bearer '+this.token});
  }
  async check():Promise<void>{await this.request('/api/capabilities','','',0,true);}
  async liveBegin(source:RecordingRef,originalId:string,startMs:number,windowMs:number=20000):Promise<LiveStatus>{
    return JSON.parse(await this.request('/api/live',JSON.stringify({device_id:source.deviceId,source_id:source.sourceId,title:source.title,original_source_id:originalId,start_ms:startMs,window_ms:windowMs}))) as LiveStatus;
  }
  async livePut(id:string,index:number,chunk:Chunk,duration:number):Promise<LiveAck>{
    return JSON.parse(await this.request(`/api/live/${id}/segments/${index}`,chunk.bytes.buffer as ArrayBuffer,chunk.sha256,duration)) as LiveAck;
  }
  async liveStatus(id:string):Promise<LiveStatus>{return JSON.parse(await this.request(`/api/live/${id}`,'','',0,true)) as LiveStatus;}
  async liveFinish(id:string,recordingId:string,count:number):Promise<LiveStatus>{
    return JSON.parse(await this.request(`/api/live/${id}/finish`,JSON.stringify({recording_id:recordingId,segment_count:count,device_end_observed:true}))) as LiveStatus;
  }
  async begin(source: RecordingRef, audio: LocalAudio): Promise<UploadSession> {
    const stamp=Number(source.sourceId);const recordedAt=/^\d{9,10}$/.test(source.sourceId)&&stamp>=946684800&&stamp<=4102444800?stamp:null;
    const body: BeginBody = {recorded_at:recordedAt,device_id:source.deviceId, source_id:source.sourceId,title:source.title,mime:audio.mime,size:audio.size,sha256:audio.sha256};
    return JSON.parse(await this.request('/api/uploads',JSON.stringify(body))) as UploadSession;
  }
  async put(id: string, index: number, chunk: Chunk,progress?:((sent:number)=>void)): Promise<void> {await this.request(`/api/uploads/${id}/chunks/${index}`,chunk.bytes.buffer as ArrayBuffer,chunk.sha256,0,false,progress);}
  async complete(id: string): Promise<Receipt> {return JSON.parse(await this.request(`/api/uploads/${id}/complete`,'{}')) as Receipt;}
}
