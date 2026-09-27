import { socket } from '@kit.NetworkKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { concat } from './D3200Protocol';
import { sha, hex } from './DeviceCrypto';

// Explicitly approved local-device exception. Never learn a replacement pin from the network.
const RECORDER_PIN='3f2667135cafff135614944392d6b3bc0e991b2ca55dbe9e469caca44d5a0125';
const LIMIT=4*1024*1024;
function ascii(s:string):Uint8Array{return new Uint8Array(Array.from(s).map((c:string)=>c.charCodeAt(0)));}
function text(bytes:Uint8Array):string{return Array.from(bytes).map((v:number)=>String.fromCharCode(v)).join('');}
function wait(ms:number):Promise<void>{return new Promise<void>((resolve)=>{setTimeout(resolve,ms);});}
export async function verifyRecorderCertificate(raw:socket.X509CertRawData):Promise<void>{
  let der=raw.data;
  if(raw.encodingFormat===1){
    const pem=text(raw.data).trim();
    if(!/^-----BEGIN CERTIFICATE-----[\s\S]+-----END CERTIFICATE-----$/.test(pem))throw new Error('D3200_CERT_FORMAT');
    der=new util.Base64Helper().decodeSync(pem.replace('-----BEGIN CERTIFICATE-----','').replace('-----END CERTIFICATE-----','').replace(/\s/g,''));
  }else if(raw.encodingFormat!==0)throw new Error('D3200_CERT_FORMAT');
  if(hex(await sha(der))!==RECORDER_PIN)throw new Error('D3200_CERT_PIN_MISMATCH');
}
export interface RecorderFrame {opcode:number;data:Uint8Array;}
interface NativeSocketError {code?:number;message?:string;errorNumber?:number;errorString?:string;}
export class RecorderFrames {
  private pending:Uint8Array=new Uint8Array(0);
  private fragments:Uint8Array=new Uint8Array(0);
  private fragmentOpcode:number=0;
  push(bytes:Uint8Array):RecorderFrame[]{
    this.pending=concat(this.pending,bytes);const frames:RecorderFrame[]=[];
    while(this.pending.length>=2){
      const b=this.pending,fin=(b[0]&128)!==0,op=b[0]&15;let size=b[1]&127,offset=2;
      if((b[0]&112)!==0||(b[1]&128)!==0||![0,1,2,8,9,10].includes(op))throw new Error('D3200_WS_FRAME_INVALID');
      if(size===126){if(b.length<4)break;size=b[2]*256+b[3];offset=4;if(size<126)throw new Error('D3200_WS_LENGTH');}
      else if(size===127){if(b.length<10)break;if(b.slice(2,6).some((v:number)=>v!==0))throw new Error('D3200_WS_SIZE');size=b[6]*16777216+b[7]*65536+b[8]*256+b[9];offset=10;if(size<65536)throw new Error('D3200_WS_LENGTH');}
      if(size>LIMIT||(op>=8&&(!fin||size>125)))throw new Error('D3200_WS_SIZE');
      if(b.length<offset+size)break;
      const data=b.slice(offset,offset+size);this.pending=b.slice(offset+size);
      if(op>=8){if(op===8&&size===1)throw new Error('D3200_WS_CLOSE_INVALID');frames.push({opcode:op,data});continue;}
      if(op===0){if(!this.fragmentOpcode)throw new Error('D3200_WS_CONTINUATION');}
      else {if(this.fragmentOpcode)throw new Error('D3200_WS_FRAGMENT_ORDER');this.fragmentOpcode=op;}
      if(this.fragments.length+data.length>LIMIT)throw new Error('D3200_WS_SIZE');
      this.fragments=concat(this.fragments,data);
      if(fin){frames.push({opcode:this.fragmentOpcode,data:this.fragments});this.fragments=new Uint8Array(0);this.fragmentOpcode=0;}
    }
    if(this.pending.length>LIMIT+10)throw new Error('D3200_WS_SIZE');return frames;
  }
}
export function maskedFrame(opcode:number,data:Uint8Array,mask:Uint8Array):Uint8Array{
  if(mask.length!==4||data.length>65535||(opcode>=8&&data.length>125))throw new Error('D3200_WS_CLIENT_SIZE');
  const header=data.length<126?new Uint8Array([128|opcode,128|data.length]):new Uint8Array([128|opcode,254,data.length>>8,data.length&255]);
  const body=data.map((v:number,i:number)=>v^mask[i%4]);return concat(concat(header,mask),body);
}
export function verifyUpgrade(header:string,accept:string):void{
  const lines=header.split('\r\n');if(!/^HTTP\/1\.1 101(?: |$)/.test(lines[0]))throw new Error('D3200_WS_UPGRADE_STATUS');
  const fields=new Map<string,string>();
  for(const line of lines.slice(1)){if(!line)continue;const i=line.indexOf(':');if(i<1)throw new Error('D3200_WS_UPGRADE_HEADER');const k=line.slice(0,i).toLowerCase(),v=line.slice(i+1).trim();if(fields.has(k))throw new Error('D3200_WS_UPGRADE_DUPLICATE');fields.set(k,v);}
  if(fields.get('sec-websocket-accept')!==accept||fields.get('upgrade')?.toLowerCase()!=='websocket'||!fields.get('connection')?.toLowerCase().split(',').map((v:string)=>v.trim()).includes('upgrade')||fields.has('sec-websocket-extensions')||fields.has('sec-websocket-protocol'))throw new Error('D3200_WS_UPGRADE_INVALID');
}
export class RecorderWebSocket {
  private trace:(value:string)=>void;
  constructor(trace:(value:string)=>void=()=>{}){this.trace=trace;}
  private tls:socket.TLSSocket|undefined=undefined;
  private pinned:boolean=false;
  private upgraded:boolean=false;
  private closing:boolean=false;
  private failure:string='';
  private incoming:Uint8Array=new Uint8Array(0);
  private parser:RecorderFrames=new RecorderFrames();
  private accept:string='';
  private receive:(bytes:Uint8Array)=>void=()=>{};
  private fail:(reason:string)=>void=()=>{};
  private sends:Promise<void>=Promise.resolve();
  private abort(reason:string):void{
    if(this.closing||this.failure)return;this.failure=reason;this.fail(reason);
    this.pinned=false;this.upgraded=false;this.tls?.close().catch(()=>{});
  }
  async connect(ip:string,port:number,receive:(bytes:Uint8Array)=>void,fail:(reason:string)=>void):Promise<void>{
    // Scope is deliberately narrower than the generic SoftAP endpoint parser.
    if(ip!=='192.168.43.1'||port!==443)throw new Error('D3200_PIN_ENDPOINT_NOT_ALLOWED');
    this.receive=receive;this.fail=fail;
    const tls=socket.constructTLSSocketInstance();this.tls=tls;
    try{
    // Native TLSSocket is created by bind; register events only after it exists.
    await tls.bind({address:'0.0.0.0',port:0,family:1});
    if(this.closing)throw new Error('SYNC_CANCELLED');
    tls.on('error',(e:BusinessError)=>{const info=e as NativeSocketError;this.abort('D3200_PIN_TLS_'+String(info.code??info.errorNumber??'ERROR')+': '+String(info.message||info.errorString||'socket error').slice(0,160));});
    tls.on('close',()=>{this.abort('D3200_PIN_TLS_CLOSED');});
    tls.on('message',(info:socket.SocketMessageInfo)=>{
      if(this.closing||this.failure)return;
      try{
        if(!this.pinned)throw new Error('D3200_TLS_DATA_BEFORE_PIN');
        let bytes=new Uint8Array(info.message);
        if(!this.upgraded)this.trace("TLS received upgrade bytes="+bytes.length);
        if(!this.upgraded){
          this.incoming=concat(this.incoming,bytes);const s=text(this.incoming),end=s.indexOf('\r\n\r\n');
          if(end<0){if(this.incoming.length>16384)throw new Error('D3200_WS_HEADERS_TOO_LARGE');return;}
          if(end>16384)throw new Error('D3200_WS_HEADERS_TOO_LARGE');
          verifyUpgrade(s.slice(0,end),this.accept);this.upgraded=true;bytes=this.incoming.slice(end+4);this.incoming=new Uint8Array(0);
        }
        for(const frame of this.parser.push(bytes)){
          if(frame.opcode===8){this.abort('D3200_PIN_WS_CLOSED');return;}
          if(frame.opcode===9){this.sendFrame(10,frame.data).catch((e:Error)=>{this.abort(e.message);});continue;}
          if(frame.opcode===10)continue;
          if(frame.opcode===1){const s=text(frame.data);if(s==='OK'||s==='ACK')continue;if(!/^(?:[0-9a-fA-F]{2})+$/.test(s))throw new Error('D3200_WIFI_MESSAGE_FORMAT');const data=new Uint8Array(s.length/2);for(let i=0;i<data.length;i++)data[i]=parseInt(s.slice(i*2,i*2+2),16);this.receive(data);}
          else this.receive(frame.data);
        }
      }catch(e){this.abort((e as Error).message);}
    });
      // The SAME TLS session must pass the fixed pin before any HTTP or file request.
      await tls.connect({address:{address:ip,port,family:1},secureOptions:{protocols:[socket.Protocol.TLSv12]},skipRemoteValidation:true,timeout:15000});
      await verifyRecorderCertificate(await tls.getRemoteCertificate());
      if(this.closing||this.failure)throw new Error(this.failure||'SYNC_CANCELLED');
      this.pinned=true;this.trace("TLS fixed certificate matched on live session");
      const key=new util.Base64Helper().encodeToStringSync((await cryptoFramework.createRandom().generateRandom(16)).data);
      const hash=cryptoFramework.createMd('SHA1');await hash.update({data:ascii(key+'258EAFA5-E914-47DA-95CA-C5AB0DC85B11')});this.accept=new util.Base64Helper().encodeToStringSync((await hash.digest()).data);
      if(this.closing||this.failure)throw new Error(this.failure||'SYNC_CANCELLED');
      await tls.send(`GET / HTTP/1.1\r\nHost: ${ip}:${port}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: ${key}\r\nSec-WebSocket-Version: 13\r\nAccept-Encoding: gzip\r\nUser-Agent: okhttp/3.12.13.18\r\n\r\n`);
      this.trace("WebSocket upgrade request sent");
      const until=Date.now()+15000;while(!this.upgraded&&!this.failure&&!this.closing&&Date.now()<until)await wait(50);
      if(this.failure||this.closing||!this.upgraded)throw new Error(this.failure||(this.closing?'SYNC_CANCELLED':'D3200_WS_UPGRADE_TIMEOUT bytes='+this.incoming.length));
    }catch(e){await this.close();throw new Error((e as Error).message||JSON.stringify(e));}
  }
  private sendFrame(op:number,data:Uint8Array):Promise<void>{
    const next=this.sends.then(async()=>{
      if(!this.tls||!this.pinned||!this.upgraded||this.closing||this.failure)throw new Error('D3200_PIN_WS_NOT_READY');
      const mask=(await cryptoFramework.createRandom().generateRandom(4)).data;
      if(this.closing||this.failure)throw new Error('D3200_PIN_WS_NOT_READY');
      await this.tls.send(maskedFrame(op,data,mask).buffer as ArrayBuffer);
    });this.sends=next.catch(()=>{});return next;
  }
  async send(value:string):Promise<boolean>{await this.sendFrame(1,ascii(value));return true;}
  cancel():void{this.closing=true;this.pinned=false;this.upgraded=false;this.tls?.close().catch(()=>{});}
  async close():Promise<void>{this.closing=true;this.pinned=false;this.upgraded=false;try{await this.tls?.close();}catch(_){}this.tls=undefined;}
}
