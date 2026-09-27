import { fileIo as fs } from '@kit.CoreFileKit';
import { D3200Device, LiveSegment } from './D3200Device';
import { NativeCache, NativeCloud } from './NativePorts';
import { LocalAudio, RecordingRef, SyncController } from './SyncController';

export interface LiveStatusSegment { idx:number; status:string; text:string; error:string|null; duration_ms:number; }
export interface LiveStatus { session_id:string; status:string; received_ms:number; text:string; segments:LiveStatusSegment[]; }
export interface LiveAck { verified:boolean; sha256:string; idx:number; size:number; }
export class LiveController {
  private pending:LiveSegment[]=[];
  private sessionId:string='';
  private cloud:NativeCloud;
  private cache:NativeCache;
  private device:D3200Device;
  private stopped:boolean=false;
  private count:number=0;
  private notify:(message:string)=>void;
  constructor(device:D3200Device,cache:NativeCache,cloud:NativeCloud,notify:(message:string)=>void){this.device=device;this.cache=cache;this.cloud=cloud;this.notify=notify;}
  cancel():void{this.stopped=true;this.device.cancel();}
  async status():Promise<LiveStatus|undefined>{return this.sessionId?this.cloud.liveStatus(this.sessionId):undefined;}
  private async flush():Promise<void>{
    while(this.pending.length&&!this.stopped){
      const segment=this.pending[0];const chunk=await this.cache.chunk(segment.audio,0,segment.audio.size);
      const receipt=await this.cloud.livePut(this.sessionId,segment.index,chunk,segment.frames*20);
      if(!receipt.verified||receipt.sha256!==segment.audio.sha256||receipt.idx!==segment.index||receipt.size!==segment.audio.size)throw new Error('LIVE_RECEIPT_MISMATCH');
      this.pending.shift();this.count=segment.index+1;
      // Retain preview windows for recovery until the full capture has a cloud receipt.
      this.notify(`实时音频已保存到 ${(segment.index*20+segment.frames/50).toFixed(1)} 秒；转写在后台继续。`);
    }
  }
  async start(source:RecordingRef):Promise<string>{
    this.stopped=false;const captureSource:RecordingRef={deviceId:source.deviceId,sourceId:source.sourceId+':capture:'+Date.now(),title:source.title};
    const captured=await this.device.captureRealtime(source,async(segment:LiveSegment):Promise<void>=>{
      this.pending.push(segment);
      try{if(!this.sessionId){const session=await this.cloud.liveBegin(captureSource,source.sourceId,segment.fromSequence*20);this.sessionId=session.session_id;}await this.flush();}catch(error){this.notify('实时上传暂时中断：'+(error as Error).message+'；音频仍在手机保存，下一段继续重试。');}
    });
    if(this.stopped)throw new Error('SYNC_CANCELLED');
    if(captured.fromSequence===0)await this.cache.retain(source,captured.audio);
    else this.notify('已结束实时接收；从设备重新取回完整录音后才会归档。');
    await this.flush();
    if(this.pending.length)throw new Error('LIVE_UPLOAD_PENDING');
    const syncer=new SyncController(this.device,this.cache,this.cloud,()=>{});
    const receipt=await syncer.sync(source);
    await this.cloud.liveFinish(this.sessionId,receipt.recording_id,this.count);
    return receipt.recording_id;
  }
}
