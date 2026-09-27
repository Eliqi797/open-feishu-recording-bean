import { fileIo as fs } from '@kit.CoreFileKit';
import { D3200Device, LiveSegment } from './D3200Device';
import { NativeCache, NativeCloud, writeFile } from './NativePorts';
import { LocalAudio, RecordingRef, SyncController } from './SyncController';

export interface LiveStatusSegment { idx:number; status:string; text:string; error:string|null; duration_ms:number; }
export interface LiveStatus { session_id:string; status:string; received_ms:number; text:string; segments:LiveStatusSegment[]; }
export interface LiveAck { verified:boolean; sha256:string; idx:number; size:number; }
interface LiveJournal {
  version:number; endpoint:string; source:RecordingRef; captureSource:RecordingRef;
  sessionId:string; fromSequence:number; pending:LiveSegment[]; count:number;
  state:string; windowSeconds?:number; cleanup?:LocalAudio[];
}
export class LiveController {
  private sessionId:string='';
  private cloud:NativeCloud;
  private cache:NativeCache;
  private device:D3200Device;
  private stopped:boolean=false;
  private notify:(message:string)=>void;
  private journal:LiveJournal|undefined=undefined;
  private journalPath:string='';
  private uploading:Promise<void>|undefined=undefined;
  constructor(device:D3200Device,cache:NativeCache,cloud:NativeCloud,notify:(message:string)=>void){this.device=device;this.cache=cache;this.cloud=cloud;this.notify=notify;}
  cancel():void{this.stopped=true;this.device.cancel();}
  async status():Promise<LiveStatus|undefined>{return this.sessionId?this.cloud.liveStatus(this.sessionId):undefined;}
  private persist():void{if(this.journal&&this.journalPath)writeFile(this.journalPath,JSON.stringify(this.journal));}
  private async cleanupAcknowledged():Promise<void>{
    const journal=this.journal;if(!journal)return;
    while(journal.cleanup&&journal.cleanup.length){await this.cache.remove(journal.cleanup[0]);journal.cleanup.shift();this.persist();}
  }
  private async drain():Promise<void>{
    const journal=this.journal;if(!journal)return;await this.cleanupAcknowledged();
    if(!journal.sessionId&&journal.pending.length&&!this.stopped){
      const session=await this.cloud.liveBegin(journal.captureSource,journal.source.sourceId,journal.fromSequence*20,(journal.windowSeconds||20)*1000);
      journal.sessionId=session.session_id;this.sessionId=session.session_id;this.persist();
    }
    while(journal.pending.length&&!this.stopped){
      const segment=journal.pending[0];
      const chunk=await this.cache.chunk(segment.audio,0,segment.audio.size);
      if(chunk.sha256!==segment.audio.sha256)throw new Error('LIVE_CACHE_CHECKSUM_MISMATCH');
      const receipt=await this.cloud.livePut(journal.sessionId,segment.index,chunk,segment.frames*20);
      if(!receipt.verified||receipt.sha256!==segment.audio.sha256||receipt.idx!==segment.index||receipt.size!==segment.audio.size)throw new Error('LIVE_RECEIPT_MISMATCH');
      journal.cleanup=(journal.cleanup||[]).concat([segment.audio]);journal.pending.shift();journal.count=segment.index+1;this.persist();await this.cleanupAcknowledged();
      this.notify(`实时音频已保存到 ${(segment.index*(journal.windowSeconds||20)+segment.frames/50).toFixed(1)} 秒；转写在后台继续。`);
    }
  }
  private flush():Promise<void>{
    if(this.uploading)return this.uploading;
    this.uploading=this.drain().finally(()=>{this.uploading=undefined;});return this.uploading;
  }
  private validate(journal:LiveJournal):void{
    if(journal.version!==1||journal.endpoint!==this.cloud.endpoint()||!journal.source||!journal.captureSource||!Array.isArray(journal.pending)||!Number.isInteger(journal.count)||journal.count<0||!Number.isInteger(journal.fromSequence)||journal.fromSequence<0)throw new Error('LIVE_JOURNAL_INVALID_OR_OTHER_CLOUD');
    if(![2,5,10,20].includes(journal.windowSeconds||20))throw new Error('LIVE_JOURNAL_INVALID_WINDOW');
    for(const audio of journal.cleanup||[]){if(!audio.path.startsWith(this.cache.root+'/')||audio.path.includes('..')||audio.size<1||!/^[a-f0-9]{64}$/.test(audio.sha256))throw new Error('LIVE_CLEANUP_INVALID');}
    for(let i=0;i<journal.pending.length;i++){
      const segment=journal.pending[i];
      if(segment.index!==journal.count+i||!Number.isInteger(segment.frames)||segment.frames<1||segment.frames>(journal.windowSeconds||20)*50||segment.fromSequence!==journal.fromSequence||!segment.audio.path.startsWith(this.cache.root+'/')||segment.audio.path.includes('..')||segment.audio.size<1||segment.audio.size>4*1024*1024||!/^[a-f0-9]{64}$/.test(segment.audio.sha256))throw new Error('LIVE_JOURNAL_INVALID');
    }
  }
  async recoverPending():Promise<number>{
    this.stopped=false;let recovered=0;
    for(const name of fs.listFileSync(this.cache.root).filter((n:string)=>/^live-journal-[0-9]+\.json$/.test(n)).sort()){
      if(this.stopped)throw new Error('SYNC_CANCELLED');
      const path=this.cache.root+'/'+name;const journal=JSON.parse(fs.readTextSync(path)) as LiveJournal;
      this.validate(journal);if(journal.state==='completed')continue;
      this.journal=journal;this.journalPath=path;this.sessionId=journal.sessionId;
      if(journal.state==='capturing')journal.state='interrupted';this.persist();
      const before=journal.pending.length;await this.flush();recovered+=before-journal.pending.length;
    }
    this.notify(`已恢复上传 ${recovered} 段。实时片段仅为草稿，完整录音仍需从录音豆同步。`);
    return recovered;
  }
  async start(source:RecordingRef,windowSeconds:number=5):Promise<string>{
    if(![2,5,10,20].includes(windowSeconds))throw new Error('LIVE_WINDOW_INVALID');
    this.stopped=false;const timestamp=Date.now();
    const captureSource:RecordingRef={deviceId:source.deviceId,sourceId:source.sourceId+':capture:'+timestamp,title:source.title};
    this.journalPath=this.cache.root+'/live-journal-'+timestamp+'.json';
    this.journal={version:1,endpoint:this.cloud.endpoint(),source,captureSource,sessionId:'',fromSequence:0,pending:[],count:0,state:'capturing',windowSeconds};this.persist();
    let ended=false;
    try{
      const captured=await this.device.captureRealtime(source,async(segment:LiveSegment):Promise<void>=>{
        const journal=this.journal;if(!journal)throw new Error('LIVE_JOURNAL_MISSING');
        journal.fromSequence=segment.fromSequence;journal.pending.push(segment);this.persist();
        // Network stalls must not stop BLE reception. One serialized upload drains
        // the durable queue; the next window retries failures with the same index.
        this.flush().catch((error:Error)=>{this.notify('实时上传暂时中断：'+error.message+'；分段已保存，可继续接收或重启后恢复上传。');});
      },windowSeconds);
      ended=true;if(this.journal){this.journal.state='awaiting_archive';this.persist();}
      if(this.stopped)throw new Error('SYNC_CANCELLED');
      if(captured.fromSequence===0)await this.cache.retain(source,captured.audio);
      else this.notify('已结束实时接收；从设备重新取回完整录音后才会归档。');
      await this.flush();
      if(!this.journal||this.journal.pending.length)throw new Error('LIVE_UPLOAD_PENDING');
      const syncer=new SyncController(this.device,this.cache,this.cloud,()=>{});
      const receipt=await syncer.sync(source);
      await this.cloud.liveFinish(this.journal.sessionId,receipt.recording_id,this.journal.count);
      this.journal.state='completed';this.persist();return receipt.recording_id;
    }finally{
      if(!ended){this.stopped=true;await this.uploading?.catch(()=>{});if(this.journal){this.journal.state='interrupted';this.persist();}}
    }
  }
}
