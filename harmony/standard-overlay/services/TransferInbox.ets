import { fileIo as fs } from '@kit.CoreFileKit';
import { Frame, FrameDecoder } from './D3200Protocol';
import { writeBytes } from './NativePorts';

// Wi-Fi can deliver a whole recording faster than per-packet native crypto.
// Spool encrypted wire data to disk; only decode a bounded window into memory.
export class TransferInbox {
  private writer:fs.File;
  private reader:fs.File;
  private written:number=0;
  private consumed:number=0;
  private limit:number;
  private closed:boolean=false;
  private ended:string='';
  private decoder:FrameDecoder=new FrameDecoder();
  private ready:Frame[]=[];
  constructor(path:string,limit:number){
    this.limit=limit;
    this.writer=fs.openSync(path,fs.OpenMode.CREATE|fs.OpenMode.READ_WRITE|fs.OpenMode.TRUNC);
    try{this.reader=fs.openSync(path,fs.OpenMode.READ_ONLY);}catch(e){fs.closeSync(this.writer);throw e as Error;}
  }
  append(bytes:Uint8Array):void{
    if(this.closed)throw new Error('D3200_INBOX_CLOSED');
    if(this.ended)throw new Error('D3200_INBOX_ENDED');
    if(this.written+bytes.length>this.limit)throw new Error('PHONE_INSUFFICIENT_STORAGE');
    writeBytes(this.writer.fd,bytes);this.written+=bytes.length;
  }
  next():Frame|undefined{
    if(this.closed)throw new Error('D3200_INBOX_CLOSED');
    while(!this.ready.length&&this.consumed<this.written){
      const count=Math.min(32768,this.written-this.consumed);
      const buffer=new ArrayBuffer(count);const got=fs.readSync(this.reader.fd,buffer,{length:count});
      if(got!==count)throw new Error('D3200_INBOX_TRUNCATED');
      this.consumed+=got;this.ready=this.decoder.push(new Uint8Array(buffer));
    }
    if(this.ready.length)return this.ready.shift();
    if(this.ended)throw new Error(this.ended);
    return undefined;
  }
  // Remote close does not invalidate already received authenticated bytes.
  // The caller must still require the protocol end frame and exact payload size.
  finish(reason:string):void{this.ended=reason||'D3200_INBOX_STREAM_ENDED';}
  size():number{return this.written;}
  close():void{
    if(this.closed)return;this.closed=true;
    try{fs.closeSync(this.writer);}finally{fs.closeSync(this.reader);}
  }
}
