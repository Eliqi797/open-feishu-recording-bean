import { ble, constant } from '@kit.ConnectivityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { DevicePort, RecordingRef, LocalAudio } from './SyncController';
import { DeviceCrypto } from './DeviceCrypto';
import { NativeCache, hashFile, writeBytes, writeFile } from './NativePorts';
import { Frame, FrameDecoder, DeviceFile, command, fileList, le, concat, u32, slices, opusHeaders, oggPage, offlineTransferSize, recordingState } from './D3200Protocol';
import { liveWindow } from './LiveAudio';
export interface LiveCapture { audio:LocalAudio; fromSequence:number; }
export interface LiveSegment { index:number; frames:number; fromSequence:number; audio:LocalAudio; }
const SERVICE='020cf5da-0000-1000-8000-00805f9b34fb';
const WRITE='00007777-0000-1000-8000-00805f9b34fb';
const NOTIFY='00008888-0000-1000-8000-00805f9b34fb';
function sleep(ms:number):Promise<void>{return new Promise<void>((resolve)=>{setTimeout(resolve,ms);});}
export class D3200Device implements DevicePort {
  private client:ble.GattClientDevice|undefined=undefined;
  private characteristic:ble.BLECharacteristic|undefined=undefined;
  private decoder:FrameDecoder=new FrameDecoder();
  private queue:Frame[]=[];
  private fault:string='';
  private crypto:DeviceCrypto=new DeviceCrypto();
  private cache:NativeCache;
  private connected:boolean=false;
  private mtu:number=23;
  private phase:string='idle';
  private recordingState:number=-1;
  isRecording():boolean{return this.recordingState===1;}
  private async readRecordingState():Promise<void>{
    await this.send(command(1,1));const info=await this.next(1,1);this.recordingState=recordingState(info.payload);
  }
  diagnostics():string{return `阶段=${this.phase}；MTU=${this.mtu}；设备录音状态=${this.recordingState}；${this.crypto.diagnostics}`;}
  private mtuChanged=(value:number):void=>{if(value>=23&&value<=517)this.mtu=value;};
  private cancelled:boolean=false;
  deviceId:string='';
  currentRecordingId:string='';
  private progress:(received:number,total:number)=>void;
  constructor(cache:NativeCache,progress:(received:number,total:number)=>void){this.cache=cache;this.progress=progress;}
  private changed=(value:ble.BLECharacteristic):void=>{
    if(value.characteristicUuid.toLowerCase()!==NOTIFY)return;
    try{this.queue=this.queue.concat(this.decoder.push(new Uint8Array(value.characteristicValue)));if(this.queue.length>1024){this.queue=[];this.fault='D3200_RECEIVER_OVERFLOW';}}
    catch(_){this.fault='D3200_INVALID_FRAME';}
  };
  private state=(value:ble.BLEConnectionChangeState):void=>{
    this.connected=value.state===constant.ProfileConnectionState.STATE_CONNECTED;
    if(value.state===constant.ProfileConnectionState.STATE_DISCONNECTED)this.fault='D3200_DISCONNECTED';
  };
  async connect(id:string):Promise<void>{
    const reconnecting=this.client!==undefined;this.close();if(reconnecting)await sleep(800);this.crypto.diagnostics='本次连接尚未进行加密校验';this.deviceId=id;this.fault='';this.cancelled=false;this.decoder=new FrameDecoder();this.queue=[];this.mtu=23;this.phase='connecting';
    try{
    const client=ble.createGattClientDevice(id);this.client=client;
    client.on('BLEMtuChange',this.mtuChanged);client.on('BLEConnectionStateChange',this.state);client.on('BLECharacteristicChange',this.changed);client.connect();
    const until=Date.now()+15000;
    while(!this.connected&&Date.now()<until){if(this.fault)throw new Error(this.fault);await sleep(100);}
    if(!this.connected)throw new Error('D3200_CONNECT_TIMEOUT');
    this.phase='services';const services=await client.getServices();const service=services.find((s:ble.GattService)=>s.serviceUuid.toLowerCase()===SERVICE);
    if(!service)throw new Error('D3200_SERVICE_NOT_FOUND');
    this.characteristic=service.characteristics.find((c:ble.BLECharacteristic)=>c.characteristicUuid.toLowerCase()===WRITE);
    const notify=service.characteristics.find((c:ble.BLECharacteristic)=>c.characteristicUuid.toLowerCase()===NOTIFY);
    if(!this.characteristic||!notify)throw new Error('D3200_CHARACTERISTIC_NOT_FOUND');
    await client.setCharacteristicChangeNotification(notify,true);
    this.phase='negotiating_mtu';client.setBLEMtuSize(185);
    const mtuDeadline=Date.now()+8000;
    while(this.mtu<78&&Date.now()<mtuDeadline){if(this.fault)throw new Error(this.fault);if(this.cancelled)throw new Error('SYNC_CANCELLED');await sleep(50);}
    if(this.mtu<78)throw new Error('D3200_MTU_TOO_SMALL_FOR_HANDSHAKE');
    this.phase='crypto_self_test';const publicKey=await this.crypto.publicKey();
    this.phase='handshake_write';await this.send(command(46,1,publicKey));
    this.phase='handshake_reply';const reply=await this.next(46,1);
    this.phase='handshake_verify';await this.crypto.handshake(reply.payload);
    this.phase='device_info';await this.readRecordingState();this.phase='ready';
    }catch(error){this.close();throw error as Error;}
  }
  private async send(bytes:Uint8Array):Promise<void>{
    if(!this.client||!this.characteristic||!this.connected)throw new Error('D3200_NOT_CONNECTED');
    // One protocol command per GATT write, matching the reference transport.
    // ATT write header occupies 3 bytes; never invent application-level fragments.
    if(bytes.length>this.mtu-3)throw new Error('D3200_FRAME_EXCEEDS_MTU');
    this.characteristic.characteristicValue=bytes.slice().buffer as ArrayBuffer;
    await this.client.writeCharacteristicValue(this.characteristic,ble.GattWriteType.WRITE);
  }
  private async next(type:number=-1,id:number=-1):Promise<Frame>{
    const until=Date.now()+90000;
    while(Date.now()<until){
      if(this.cancelled)throw new Error('SYNC_CANCELLED');if(this.fault)throw new Error(this.fault);
      const frame=this.queue.shift();
      if(frame&&(type<0||frame.type===type)&&(id<0||frame.command===id)){if((frame.status&15)!==1)throw new Error('D3200_COMMAND_REJECTED');return frame;}
      await sleep(10);
    }
    throw new Error('D3200_RECEIVE_TIMEOUT');
  }
  async list():Promise<DeviceFile[]>{
    const all:DeviceFile[]=[];
    for(let page=0;page<4096;page++){
      await this.send(command(26,14,le(page,2)));const payload=(await this.next(26,14)).payload;const found=fileList(payload);
      if(page===0&&payload.length>=2+found.length*8+8)this.currentRecordingId=String(u32(payload,2+found.length*8));if(found.length===0)return all;
      for(const file of found){if(all.some((f:DeviceFile)=>f.id===file.id))throw new Error('D3200_REPEATED_LIST_PAGE');all.push(file);}
    }
    throw new Error('D3200_LIST_LIMIT');
  }
  async downloadAndDecrypt(source:RecordingRef):Promise<LocalAudio>{
    if(source.deviceId!==this.deviceId)throw new Error('D3200_DEVICE_CHANGED');
    const id=Number(source.sourceId);if(!Number.isInteger(id)||id<0||id>4294967295)throw new Error('D3200_INVALID_FILE_ID');
    this.cancelled=false;this.queue=[];await this.readRecordingState();
    if(this.isRecording())throw new Error('D3200_RECORDING_NOT_FINALIZED');
    const path=this.cache.root+'/'+id+'-'+Date.now()+'.ogg';
    const file=fs.openSync(path+'.partial',fs.OpenMode.CREATE|fs.OpenMode.READ_WRITE|fs.OpenMode.TRUNC);
    let frames=0,expected=0,pending:Uint8Array|undefined=undefined;
    try{
      await this.send(command(26,7,concat(concat(le(0),le(id)),new Uint8Array([0]))));
      const head=await this.next(26,7);
      if(u32(head.payload,0)!==id)throw new Error(`D3200_FILE_ID_MISMATCH requested=${id} received=${u32(head.payload,0)} size=${u32(head.payload,4)} headerBytes=${head.payload.length} recordingState=${this.recordingState}`);expected=offlineTransferSize(u32(head.payload,4));
      await this.crypto.file(head.payload);writeBytes(file.fd,opusHeaders());
      while(true){
        const frame=await this.next(26);if(frame.command===10)break;if(frame.command!==8&&frame.command!==18)continue;
        for(const slice of slices(frame.payload)){
          if(slice.sequence!==frames)throw new Error('D3200_SEQUENCE_GAP_OR_DUPLICATE');const clear=await this.crypto.decrypt(slice.sequence,slice.encrypted);
          if(pending)writeBytes(file.fd,oggPage(pending,frames+1,frames*960,0));
          pending=clear;frames++;this.progress(frames*166,expected);
          if(frames*166>expected)throw new Error('D3200_SIZE_PROFILE_MISMATCH');
        }
      }
      // Require exact transfer bytes and the device completion frame; never tolerate partial success.
      if(!pending||frames*166!==expected)throw new Error('D3200_INCOMPLETE_TRANSFER');
      writeBytes(file.fd,oggPage(pending,frames+1,frames*960,4));fs.fsyncSync(file.fd);
    }catch(error){this.cancel();throw error as Error;}finally{fs.closeSync(file);}
    fs.renameSync(path+'.partial',path);return{path,size:fs.statSync(path).size,sha256:await hashFile(path),mime:'audio/ogg'};
  }
  async captureRealtime(source:RecordingRef,onSegment:(segment:LiveSegment)=>Promise<void>,windowSeconds:number=20):Promise<LiveCapture>{
    if(![2,5,10,20].includes(windowSeconds))throw new Error('LIVE_WINDOW_INVALID');
    if(source.deviceId!==this.deviceId)throw new Error('D3200_DEVICE_CHANGED');
    const id=Number(source.sourceId);if(!Number.isInteger(id)||id<=0||id>4294967295)throw new Error('D3200_INVALID_FILE_ID');
    this.cancelled=false;this.queue=[];await this.readRecordingState();
    if(!this.isRecording())throw new Error('D3200_NO_ACTIVE_RECORDING');
    const path=this.cache.root+'/'+id+'-live-'+Date.now()+'.ogg';
    const file=fs.openSync(path+'.partial',fs.OpenMode.CREATE|fs.OpenMode.READ_WRITE|fs.OpenMode.TRUNC);
    let frames=0,index=0,fromSequence=-1;let packets:Uint8Array[]=[];let pending:Uint8Array|undefined=undefined;
    try{
      await this.send(command(26,7,concat(concat(le(0),le(id)),new Uint8Array([1]))));
      const head=await this.next(26,7);
      if(u32(head.payload,0)!==id)throw new Error('D3200_LIVE_FILE_CHANGED');
      await this.crypto.file(head.payload);writeBytes(file.fd,opusHeaders());
      while(true){
        const frame=await this.next(26);
        if(frame.command===10)break;
        if(frame.command===6||frame.command===7)throw new Error('D3200_LIVE_FILE_CHANGED');
        if(frame.command!==8&&frame.command!==18)continue;
        for(const slice of slices(frame.payload)){
          if(fromSequence<0)fromSequence=slice.sequence;
          if(slice.sequence!==fromSequence+frames)throw new Error(`D3200_SEQUENCE_GAP_OR_DUPLICATE expected=${fromSequence+frames} received=${slice.sequence}`);
          const clear=await this.crypto.decrypt(slice.sequence,slice.encrypted);
          if(pending)writeBytes(file.fd,oggPage(pending,frames+1,frames*960,0));
          pending=clear;frames++;packets.push(clear);this.progress(frames*166,0);
          if(packets.length===windowSeconds*50){
            fs.fsyncSync(file.fd);const part=await this.saveLiveWindow(path,index,packets,fromSequence);packets=[];index++;await onSegment(part);
          }
        }
      }
      if(!pending)throw new Error('D3200_EMPTY_LIVE_CAPTURE');
      // Only a device completion message can close the full recording successfully.
      writeBytes(file.fd,oggPage(pending,frames+1,frames*960,4));fs.fsyncSync(file.fd);
      if(packets.length)await onSegment(await this.saveLiveWindow(path,index,packets,fromSequence));
    }catch(error){this.cancel();throw error as Error;}finally{fs.closeSync(file);}
    fs.renameSync(path+'.partial',path);
    return{audio:{path,size:fs.statSync(path).size,sha256:await hashFile(path),mime:'audio/ogg'},fromSequence};
  }
  private async saveLiveWindow(base:string,index:number,packets:Uint8Array[],fromSequence:number):Promise<LiveSegment>{
    const path=base+'.window-'+index+'.ogg';const bytes=liveWindow(packets);writeFile(path,bytes.buffer as ArrayBuffer);
    return{index,frames:packets.length,fromSequence,audio:{path,size:bytes.length,sha256:await hashFile(path),mime:'audio/ogg'}};
  }
  async restoreInternet():Promise<void>{ /* BLE does not switch the internet network. */ }
  cancel():void{this.cancelled=true;if(this.client){try{this.client.disconnect();}catch(_){}}}
  close():void{
    this.cancelled=true;this.crypto.clear();const client=this.client;
    this.client=undefined;this.characteristic=undefined;this.connected=false;
    if(client){
      try{client.off('BLEMtuChange',this.mtuChanged);}catch(_){}
      try{client.off('BLECharacteristicChange',this.changed);}catch(_){}
      try{client.off('BLEConnectionStateChange',this.state);}catch(_){}
      try{client.disconnect();}catch(_){}
      try{client.close();}catch(_){}
    }
  }
}
