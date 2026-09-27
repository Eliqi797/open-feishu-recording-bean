import { RecordingRef, Receipt, DevicePort, CachePort, CloudPort, SyncController } from './SyncController';
export interface ArchivedSource {device_id:string;source_id:string;stored:number;source_devices?:string[];}
export function pendingRecordings(sources:RecordingRef[],archived:ArchivedSource[]):RecordingRef[]{
  return sources.filter((s:RecordingRef,index:number)=>sources.findIndex((other:RecordingRef)=>other.deviceId===s.deviceId&&other.sourceId===s.sourceId)===index&&!archived.some((r:ArchivedSource)=>!!r.stored&&(r.device_id===s.deviceId||!!r.source_devices?.includes(s.deviceId))&&r.source_id===s.sourceId));
}
export interface BatchDevicePort extends DevicePort {beginDownloadBatch():Promise<void>;endDownloadBatch():Promise<void>;}
export class BatchSync {
  private current:SyncController|undefined=undefined;
  private stopped:boolean=false;
  private running:boolean=false;
  cancel():void{this.stopped=true;this.current?.cancel();}
  async transfer(sources:RecordingRef[],device:BatchDevicePort,cache:CachePort,cloud:CloudPort,
    file:(stage:string,source:RecordingRef,index:number,total:number)=>void,
    progress:(phase:string,done:number,total:number)=>void,
    archived:(source:RecordingRef)=>Promise<void>):Promise<number>{
    if(this.running)throw new Error('SYNC_ALREADY_RUNNING');
    this.running=true;this.stopped=false;let opened=false;let completed=0;
    this.current=new SyncController(device,cache,cloud,progress);
    try{
      try{
        for(let i=0;i<sources.length;i++){
          if(this.stopped)throw new Error('SYNC_CANCELLED');
          file('downloading',sources[i],i,sources.length);
          const cached=await cache.findVerified(sources[i]);
          if(!cached){
            if(this.stopped)throw new Error('SYNC_CANCELLED');
            if(!opened){opened=true;progress('connecting',0,0);await device.beginDownloadBatch();}
            if(this.stopped)throw new Error('SYNC_CANCELLED');
            await this.current.downloadOnly(sources[i],false);
          }else progress('cached',cached.size,cached.size);
        }
      }finally{if(opened){progress('restoring_network',0,0);await device.endDownloadBatch();}}
      if(this.stopped)throw new Error('SYNC_CANCELLED');
      progress('restoring_network',0,0);await device.restoreInternet();
      for(let i=0;i<sources.length;i++){
        if(this.stopped)throw new Error('SYNC_CANCELLED');
        file('uploading',sources[i],i,sources.length);
        await this.current.sync(sources[i],true);await archived(sources[i]);completed++;
      }
      return completed;
    }finally{this.running=false;this.current=undefined;}
  }
  async run(sources:RecordingRef[],transfer:(source:RecordingRef,index:number,total:number)=>Promise<Receipt>):Promise<number>{
    if(this.running)throw new Error('SYNC_ALREADY_RUNNING');
    this.running=true;this.stopped=false;let completed=0;
    try{for(let index=0;index<sources.length;index++){
      if(this.stopped)throw new Error('SYNC_CANCELLED');
      const receipt=await transfer(sources[index],index,sources.length);
      if(!receipt.stored||!receipt.verified)throw new Error('CLOUD_RECEIPT_MISMATCH');
      completed++;
    }return completed;}finally{this.running=false;}
  }
}
