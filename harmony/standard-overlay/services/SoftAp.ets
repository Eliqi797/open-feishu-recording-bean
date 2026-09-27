import { wifiManager } from '@kit.ConnectivityKit';
import { webSocket, socket, connection } from '@kit.NetworkKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { concat, le } from './D3200Protocol';
import { hex } from './DeviceCrypto';
import { RecorderWebSocket } from './RecorderWebSocket';
function wait(ms:number):Promise<void>{return new Promise<void>((resolve)=>{setTimeout(resolve,ms);});}
export function sameIpv4Subnet(local:string,prefix:number,remote:string):boolean{
  const a=local.split('.'),b=remote.split('.');
  if(a.length!==4||b.length!==4||!Number.isInteger(prefix)||prefix<1||prefix>32)return false;
  let x=0,y=0;
  for(let i=0;i<4;i++){
    if(!/^\d{1,3}$/.test(a[i])||!/^\d{1,3}$/.test(b[i]))return false;
    const u=Number(a[i]),v=Number(b[i]);if(u>255||v>255)return false;
    x=(x<<8)|u;y=(y<<8)|v;
  }
  const mask=0xffffffff<<(32-prefix);return x!==0&&x!==y&&(x&mask)===(y&mask);
}
export class SoftAp {
  private trace:(value:string)=>void;
  constructor(trace:(value:string)=>void=()=>{}){this.trace=trace;}
  ssid:string='';
  password:string='';
  private candidate:number=-1;
  private ws:webSocket.WebSocket|undefined=undefined;
  private pinnedWs:RecorderWebSocket|undefined=undefined;
  private udp:socket.UDPSocket|undefined=undefined;
  private timer:number=-1;
  private closing:boolean=false;
  private boundNet:connection.NetHandle|undefined=undefined;
  private previousNetId:number=0;
  private phase:string='idle';
  private endpointIp:string='';
  private endpointPort:number=0;
  private transportClosed:boolean=true;
  private transportGeneration:number=0;
  private receiveData:(bytes:Uint8Array)=>void=()=>{};
  private failed:(reason:string)=>void=()=>{};
  async credentials():Promise<Uint8Array>{
    const random=hex((await cryptoFramework.createRandom().generateRandom(16)).data);
    this.ssid='Bean-'+random.slice(0,8);this.password=random.slice(8);
    const chars=(s:string):Uint8Array=>new Uint8Array(Array.from(s).map((c:string)=>c.charCodeAt(0)));
    return concat(concat(new Uint8Array([this.ssid.length]),chars(this.ssid)),concat(new Uint8Array([this.password.length]),chars(this.password)));
  }
  async connect(payload:Uint8Array,receive:(bytes:Uint8Array)=>void,fail:(reason:string)=>void):Promise<void>{
    try{
    this.phase='endpoint';
    if(payload.length<6)throw new Error('D3200_WIFI_ENDPOINT_INVALID');
    const ip=`${payload[3]}.${payload[2]}.${payload[1]}.${payload[0]}`,port=payload[4]+payload[5]*256;
    const privateIp=payload[3]===10||(payload[3]===192&&payload[2]===168)||(payload[3]===172&&payload[2]>=16&&payload[2]<=31);
    if(!privateIp||port===0)throw new Error('D3200_WIFI_ENDPOINT_INVALID');
    this.trace('endpoint '+ip+':'+port);
    this.phase='wifi_config';
    const config:wifiManager.WifiDeviceConfig={ssid:this.ssid,preSharedKey:this.password,securityType:wifiManager.WifiSecurityType.WIFI_SEC_TYPE_PSK};
    this.candidate=await wifiManager.addCandidateConfig(config);
    if(this.candidate<0)throw new Error('D3200_WIFI_CONFIG_FAILED');
    this.phase='wifi_join';
    this.trace('join Wi-Fi once for download batch');
    await wifiManager.connectToCandidateConfigWithUserAction(this.candidate);
    // User consent can precede association; wait for the actual hotspot connection.
    const until=Date.now()+45000;let joined=false;
    while(Date.now()<until){if(this.closing)throw new Error('SYNC_CANCELLED');const info=await wifiManager.getLinkedInfo();if(info.ssid.replace(/"/g,'')===this.ssid){joined=true;break;}await wait(500);}
    if(!joined)throw new Error('D3200_WIFI_JOIN_TIMEOUT');
    await this.networkDiagnostics();
    this.phase='wifi_route';await this.bindHotspotNetwork(ip);
    this.phase='udp';
    this.udp=socket.constructUDPSocketInstance();await this.udp.bind({address:'0.0.0.0',port:0,family:1});
    const keep=async():Promise<void>=>{try{await this.udp?.send({data:'soundcore-keep-alive-unicast',address:{address:ip,port:32003,family:1}});}catch(_){if(!this.closing)fail('D3200_WIFI_UDP_SEND');}};
    await keep();this.timer=setInterval(()=>{keep();},1000);
    this.endpointIp=ip;this.endpointPort=port;this.receiveData=receive;this.failed=fail;await this.openTransport();
    }catch(error){
      const code=(error as BusinessError).code;
      throw new Error('D3200_WIFI_'+this.phase+'_'+(code?String(code):(error as Error).message));
    }
  }
  private async openTransport():Promise<void>{
    if(this.closing)throw new Error('SYNC_CANCELLED');
    const ip=this.endpointIp,port=this.endpointPort,generation=++this.transportGeneration;
    this.transportClosed=false;
    const receive=(bytes:Uint8Array):void=>{if(generation===this.transportGeneration)this.receiveData(bytes);};
    const fail=(reason:string):void=>{if(generation!==this.transportGeneration||this.closing)return;this.transportClosed=true;this.failed(reason);};
    this.phase='websocket';
    if(port===443){
      if(!/^Bean-[0-9a-f]{8}$/.test(this.ssid)||!/^[0-9a-f]{24}$/.test(this.password)||!this.boundNet)throw new Error('D3200_PIN_SESSION_REQUIRED');
      const pinned=new RecorderWebSocket(this.trace);this.pinnedWs=pinned;
      await pinned.connect(ip,port,receive,fail);
      this.trace('TLS fixed certificate matched; encrypted WebSocket ready');return;
    }
    const ws=webSocket.createWebSocket();this.ws=ws;
    let opened=false;let linkError='';
    ws.on('open',()=>{opened=true;});
    ws.on('message',(error:BusinessError,value:string|ArrayBuffer)=>{
      if(error){fail('D3200_WIFI_MESSAGE_'+error.code);return;}
      if(typeof value==='string'){
        if(value==='OK'||value==='ACK')return;
        if(!/^(?:[0-9a-fA-F]{2})+$/.test(value)){fail('D3200_WIFI_MESSAGE_FORMAT');return;}
        const bytes=new Uint8Array(value.length/2);for(let i=0;i<bytes.length;i++)bytes[i]=parseInt(value.slice(i*2,i*2+2),16);receive(bytes);
      }else receive(new Uint8Array(value));
    });
    ws.on('error',(error:BusinessError)=>{linkError='D3200_WIFI_WS_ERROR_'+error.code+': '+String(error.message||JSON.stringify(error)).slice(0,240);if(!this.closing)fail(linkError);});
    ws.on('close',()=>{if(!linkError)linkError='D3200_WIFI_WS_CLOSED';if(!this.closing)fail(linkError);});
    const scheme=port===443?'wss':'ws';
    if(!await ws.connect(`${scheme}://${ip}:${port}`,{proxy:'no-proxy'}))throw new Error('D3200_WEBSOCKET_FAILED');
    const readyDeadline=Date.now()+15000;
    while(!opened&&!linkError&&!this.closing&&Date.now()<readyDeadline)await wait(50);
    if(this.closing)throw new Error('SYNC_CANCELLED');
    if(linkError){
      this.trace(linkError);
      try{await ws.close();}catch(_){}
      throw new Error(linkError);
    }
    if(!opened)throw new Error('D3200_WIFI_WS_OPEN_TIMEOUT');
  }
  private async bindHotspotNetwork(ip:string):Promise<void>{
    const deadline=Date.now()+45000;
    while(Date.now()<deadline){
      if(this.closing)throw new Error('SYNC_CANCELLED');
      const info=await wifiManager.getLinkedInfo();
      if(info.ssid.replace(/"/g,'')!==this.ssid)throw new Error('D3200_WIFI_LEFT_HOTSPOT');
      for(const net of await connection.getAllNets()){
        const caps=await connection.getNetCapabilities(net);
        if(!caps.bearerTypes.includes(connection.NetBearType.BEARER_WIFI))continue;
        const props=await connection.getConnectionProperties(net);
        if(!props.linkAddresses.some((v:connection.LinkAddress)=>sameIpv4Subnet(v.address.address,v.prefixLength,ip)))continue;
        const previous=await connection.getAppNet();this.previousNetId=previous?previous.netId:0;
        await connection.setAppNet(net);this.boundNet=net;
        this.trace('bound Wi-Fi netId='+net.netId+' iface='+props.interfaceName+' addresses='+props.linkAddresses.map((v:connection.LinkAddress)=>v.address.address).join(','));
        return;
      }
      await wait(500);
    }
    await this.networkDiagnostics();
    throw new Error('D3200_WIFI_IP_ROUTE_NOT_READY');
  }
  private async networkDiagnostics():Promise<void>{
    try{
      const def=await connection.getDefaultNet();this.trace('default netId='+def.netId);
      for(const net of await connection.getAllNets()){
        const caps=await connection.getNetCapabilities(net);
        const props=await connection.getConnectionProperties(net);
        this.trace('netId='+net.netId+' iface='+props.interfaceName+' bearer='+caps.bearerTypes.join(',')+' addresses='+props.linkAddresses.map((v:connection.LinkAddress)=>v.address.address+'/'+v.prefixLength).join(','));
      }
    }catch(error){this.trace('network info '+JSON.stringify(error));}
  }
  async request(fileId:number):Promise<void>{
    if(this.closing)throw new Error('SYNC_CANCELLED');
    if(this.transportClosed){
      // Reconnect only the socket, never rejoin Wi-Fi or request another authorization.
      this.transportGeneration++;
      try{await this.pinnedWs?.close();}catch(_){}try{await this.ws?.close();}catch(_){}
      this.pinnedWs=undefined;this.ws=undefined;
      await this.openTransport();
    }
    this.trace('request file '+fileId+' on current Wi-Fi session');
    const transport=this.pinnedWs||this.ws;
    if(!transport)throw new Error('D3200_WEBSOCKET_NOT_READY');
    // Documented Wi-Fi profile uses a fixed 18-byte hex-text request ending 0x1b.
    const bytes=concat(concat(new Uint8Array([8,238,0,0,0,26,7,18,0]),le(0)),concat(le(fileId),new Uint8Array([27])));
    if(!await transport.send(hex(bytes)))throw new Error('D3200_WEBSOCKET_SEND_FAILED');
  }
  cancel():void{this.closing=true;this.pinnedWs?.cancel();}
  async close():Promise<void>{
    this.closing=true;if(this.timer>=0)clearInterval(this.timer);
    // Attempt every cleanup step, even if the previous transport operation failed.
    try{const transport=this.pinnedWs||this.ws;if(transport)await transport.send('FINISH');}catch(_){}
    try{await this.pinnedWs?.close();}catch(_){}
    try{await this.ws?.close();}catch(_){}
    try{await this.udp?.close();}catch(_){}
    try{
      try{if(this.boundNet){this.boundNet.netId=this.previousNetId;await connection.setAppNet(this.boundNet);this.trace('restored app network '+this.previousNetId);this.boundNet=undefined;}}
      finally{if(this.candidate>=0)await wifiManager.removeCandidateConfig(this.candidate);}
    }
    finally{this.candidate=-1;this.pinnedWs=undefined;this.ws=undefined;this.udp=undefined;this.password='';}
  }

  static async awaitInternet():Promise<void>{
    const until=Date.now()+45000;
    while(Date.now()<until){
      if(await connection.hasDefaultNet()){
        const caps=await connection.getNetCapabilities(await connection.getDefaultNet());
        if(caps.networkCap?.includes(connection.NetCap.NET_CAPABILITY_VALIDATED))return;
      }
      await wait(500);
    }
    throw new Error('RESTORE_INTERNET_REQUIRED_RETRY_FROM_CACHE');
  }
}
