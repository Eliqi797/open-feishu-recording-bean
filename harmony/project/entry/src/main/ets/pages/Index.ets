import BuildProfile from 'BuildProfile';
import { fileIo as fs } from '@kit.CoreFileKit';
import { LiveController, LiveStatusSegment } from '../services/LiveController';
import { ble } from '@kit.ConnectivityKit';
import { abilityAccessCtrl, common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { NativeCache, NativeCloud } from '../services/NativePorts';
import { D3200Device } from '../services/D3200Device';
import { DeviceFile } from '../services/D3200Protocol';
import { SyncController, RecordingRef } from '../services/SyncController';

interface DebugCloud { origin:string; token:string; }
interface DeviceCandidate { id:string; name:string; number:number; lastSeen:number; }

@Entry
@Component
struct Index {
  @State liveText:string='';
  @State liveStatus:string='';
  private live:LiveController|undefined=undefined;
  private liveTimer:number=-1;
  private pollingLive:boolean=false;
  @State status:string='连接设备后读取录音；正在录音时可开启实时记录。';
  @State devices:DeviceCandidate[]=[];
  @State showDiagnostics:boolean=false;
  @State connectionError:string='';
  @State connectionDetails:string='';
  @State connectedName:string='';
  @State listLoaded:boolean=false;
  @State files:DeviceFile[]=[];
  @State scanning:boolean=false;
  @State busy:boolean=false;
  @State origin:string='';
  @State token:string='';
  @State progress:number=0;
  @State canResume:boolean=false;
  private timer:number=-1;
  private cache:NativeCache|undefined=undefined;
  private device:D3200Device|undefined=undefined;
  private syncer:SyncController|undefined=undefined;
  private lastSource:RecordingRef|undefined=undefined;
  private found=(results:ble.ScanResult[]):void=>{
    for(const result of results){
      const found=this.devices.findIndex((candidate:DeviceCandidate)=>candidate.id===result.deviceId);
      const reported=result.deviceName?result.deviceName.trim():'';
      const name=reported&&reported.toUpperCase()!==result.deviceId.toUpperCase()?reported:'';
      if(found<0){this.devices=this.devices.concat([{id:result.deviceId,name:name||'D3200 录音豆',number:this.devices.length+1,lastSeen:Date.now()}]);}
      else{
        const updated=this.devices.slice();updated[found]={id:result.deviceId,name:name||this.devices[found].name,number:this.devices[found].number,lastSeen:Date.now()};this.devices=updated;
      }
    }
  };
  aboutToAppear():void{
    const context=this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.cache=new NativeCache(context.filesDir);
    if(BuildProfile.DEBUG){const path=context.filesDir+'/debug-cloud.json';if(fs.accessSync(path)){
      const config=JSON.parse(fs.readTextSync(path)) as DebugCloud;
      if(config.origin==='usb://local'){NativeCloud.enableDebugUsb(context.filesDir);this.origin=config.origin;this.token=config.token;}
      else if(config.origin.startsWith('https://')){this.origin=config.origin;this.token=config.token;}
    }}
    this.device=new D3200Device(this.cache,(done:number,total:number)=>{this.progress=total?Math.floor(done/total*100):0;this.status=total?`下载解密 ${done} / ${total} 字节`:`实时接收中 · 已保存 ${(done/1024).toFixed(0)} KB`;});
    const journal=this.cache.lastJournal();if(journal&&journal.phase!=='completed'){this.lastSource=journal.source;this.canResume=true;this.status='有未完成同步。已完整缓存的文件可续传；下载中断请重新连接设备。';}
  }
  private stopScan():void{
    if(this.timer>=0)clearTimeout(this.timer);
    if(this.scanning){try{ble.stopBLEScan();ble.off('BLEDeviceFind',this.found);}catch(_){}}
    this.scanning=false;
  }
  private async scan():Promise<void>{
    this.stopScan();try{
      const context=this.getUIContext().getHostContext() as common.UIAbilityContext;
      const permission=await abilityAccessCtrl.createAtManager().requestPermissionsFromUser(context,['ohos.permission.ACCESS_BLUETOOTH']);
      if(permission.authResults.some((v:number)=>v!==0)){this.status='请在系统授权蓝牙访问';return;}
      this.devices=[];this.connectionError='';this.connectionDetails='';ble.on('BLEDeviceFind',this.found);this.scanning=true;
      ble.startBLEScan([{serviceUuid:'020cf5da-0000-1000-8000-00805f9b34fb'}]);
      this.status='扫描 D3200 服务；只连接你自己的录音豆。';this.timer=setTimeout(()=>{this.stopScan();this.status=`找到 ${this.devices.length} 个候选设备`;},10000);
    }catch(error){this.stopScan();this.status=`扫描失败，错误码 ${(error as BusinessError).code}`;}
  }
  private async connect(id:string):Promise<void>{
    if(!this.device||this.busy)return;
    const candidate=this.devices.find((item:DeviceCandidate)=>item.id===id);
    if(!candidate||Date.now()-candidate.lastSeen>60000){await this.scan();this.status='设备列表已过期，正在重新扫描；找到后请重新选择录音豆。';return;}
    this.stopScan();this.busy=true;this.files=[];this.listLoaded=false;this.connectedName='';this.connectionError='';this.connectionDetails='';this.status='连接并协商加密会话…';
    try{await this.device.connect(id);this.files=await this.device.list();this.listLoaded=true;const candidate=this.devices.find((item:DeviceCandidate)=>item.id===id);this.connectedName=candidate?candidate.name:'D3200 录音豆';this.status=`已读到 ${this.files.length} 条录音。`+(this.device.isRecording()?'设备正在录音，可开启实时记录；完整下载需等录音结束。':'原文件保留在录音豆。');}
    catch(error){this.connectionDetails=this.device.diagnostics();this.connectionError=(error as Error).message;if(this.connectionError==='D3200_CONNECT_TIMEOUT'||this.connectionError==='D3200_DISCONNECTED')this.devices=[];this.status=this.connectionError==='D3200_SHARED_SECRET_MISMATCH'?'设备已找到，但加密连接校验未通过，尚未读取录音。':'设备连接未完成，请保持录音豆唤醒并重新扫描。可展开诊断信息。';}finally{this.busy=false;}
  }
  private async pollLive():Promise<void>{
    if(!this.live||this.pollingLive)return;this.pollingLive=true;
    try{const state=await this.live.status();if(state){this.liveText=state.text;
      const pending=state.segments.filter((s:LiveStatusSegment)=>s.status==='queued'||s.status==='running').length;
      const failed=state.segments.filter((s:LiveStatusSegment)=>s.status==='failed').length;
      const quiet=state.segments.filter((s:LiveStatusSegment)=>s.status==='no_speech').length;
      this.liveStatus=`已上传 ${(state.received_ms/1000).toFixed(1)} 秒；待转写 ${pending} 段；失败 ${failed} 段；未识别到语音 ${quiet} 段。`;
    }}catch(_){this.liveStatus='暂时无法读取转写进度，手机继续保留音频。';}finally{this.pollingLive=false;}
  }
  private async checkCloud():Promise<void>{
    if(this.busy)return;this.busy=true;
    try{await new NativeCloud(this.origin.trim(),this.token.trim()).check();this.status='云端连接成功，访问口令已通过验证。';}
    catch(error){this.status='云端连接失败：'+(error as Error).message;}finally{this.busy=false;}
  }
  private async startLive():Promise<void>{
    if(!this.device||!this.cache||this.busy)return;this.busy=true;this.liveText='';this.liveStatus='连接实时服务…';
    try{
      const cloud=new NativeCloud(this.origin.trim(),this.token.trim());
      this.live=new LiveController(this.device,this.cache,cloud,(message:string)=>{this.liveStatus=message;});
      this.liveTimer=setInterval(()=>{this.pollLive();},3000);
      const id=this.device.currentRecordingId;if(!id||id==='0')throw new Error('D3200_NO_ACTIVE_RECORDING');
      const recording=await this.live.start({deviceId:this.device.deviceId,sourceId:id,title:'实时录音 '+id});
      await this.pollLive();this.status='完整录音已校验归档：'+recording+'，后台继续生成最终纪要。';
    }catch(error){this.status='实时接收已停止：'+(error as Error).message+'。设备原件和手机分段保留；中断不会被标记为完整录音。';}
    finally{if(this.liveTimer>=0)clearInterval(this.liveTimer);this.liveTimer=-1;this.busy=false;}
  }
  private async downloadOnly(source:RecordingRef):Promise<void>{
    if(!this.device||!this.cache||this.busy)return;this.busy=true;this.lastSource=source;this.canResume=true;
    try{
      this.syncer=new SyncController(this.device,this.cache,undefined,(phase:string,done:number,total:number)=>{this.progress=total?Math.floor(done/total*100):0;this.status=`${phase} · ${done} / ${total}`;});
      const audio=await this.syncer.downloadOnly(source);
      this.status=`已下载并校验 ${(audio.size/1048576).toFixed(2)} MB。仅保存在手机缓存，尚未上传；设备原件保留。`;
    }catch(error){const code=(error as Error).message;this.status=code==='D3200_RECORDING_NOT_FINALIZED'?'这条录音尚未结束。请在录音豆上停止录音，再重新连接、刷新列表后下载。':`下载未完成：${code}。缓存和设备原件保留，可重新连接后重试。`;}
    finally{this.busy=false;}
  }
  private async sync(source:RecordingRef):Promise<void>{
    if(!this.device||!this.cache)return;this.busy=true;this.lastSource=source;this.canResume=true;
    try{
      const cloud=new NativeCloud(this.origin.trim(),this.token.trim());
      this.syncer=new SyncController(this.device,this.cache,cloud,(phase:string,done:number,total:number)=>{this.progress=total?Math.floor(done/total*100):0;this.status=`${phase} · ${done} / ${total}`;});
      const receipt=await this.syncer.sync(source);this.status=`已保存并校验：${receipt.recording_id}。手机缓存已清理，录音豆原件保留。`;this.canResume=false;
    }catch(error){this.status=`同步未完成：${(error as Error).message}。请保留原件，重新点击可重试。`;}
    finally{this.busy=false;}
  }
  aboutToDisappear():void{this.stopScan();this.syncer?.cancel();this.live?.cancel();if(this.liveTimer>=0)clearInterval(this.liveTimer);this.device?.close();this.token='';}
  build(){
    Scroll(){Column({space:14}){
      Text('录音豆').fontSize(28).fontWeight(FontWeight.Bold).width('100%')
      Text('前台同步 · 校验后清理缓存 · 保留设备原件').fontSize(14).width('100%')
      Text('云端地址（可稍后填写）').fontSize(14).width('100%')
      TextInput({placeholder:'云端地址 https://…',text:this.origin}).onChange((v:string)=>{this.origin=v;}).enabled(!this.busy)
      Text('云端访问口令').fontSize(14).width('100%')
      TextInput({placeholder:'云端访问口令（仅本次打开保存）',text:this.token}).type(InputType.Password).onChange((v:string)=>{this.token=v;}).enabled(!this.busy)
      Button('检查云端连接').enabled(!this.busy).onClick(()=>{this.checkCloud();})
      Text('完整文件经云端校验后，才清理手机缓存。').fontSize(13).width('100%')
      Text('附近的录音豆').fontSize(20).fontWeight(FontWeight.Bold).width('100%')
      Button(this.scanning?'正在扫描':'扫描录音豆').height(48).width('100%').enabled(!this.scanning&&!this.busy).onClick(()=>{this.scan();})
      ForEach(this.devices,(candidate:DeviceCandidate)=>{
        Column({space:8}){
          Text(candidate.name).fontSize(18).fontWeight(FontWeight.Medium).width('100%')
          Text('附近设备 '+candidate.number).fontSize(14).width('100%')
          Button('连接此录音豆').height(48).width('100%').enabled(!this.busy).onClick(()=>{this.connect(candidate.id);})
          if(this.showDiagnostics){Text('蓝牙 ID：'+candidate.id).fontSize(13).width('100%')}
        }.width('100%').padding(12).border({width:1,color:'#dbe4e0'}).borderRadius(8)
      },(candidate:DeviceCandidate)=>candidate.id)
      Text(this.status).fontSize(15).width('100%')
      Button(this.showDiagnostics?'收起诊断信息':'查看诊断信息').height(48).enabled(!this.busy).onClick(()=>{this.showDiagnostics=!this.showDiagnostics;})
      if(this.showDiagnostics&&this.connectionError){Text('连接诊断：'+this.connectionError).fontSize(13).width('100%');Text(this.connectionDetails).fontSize(13).width('100%')}
      Progress({value:this.progress,total:100,type:ProgressType.Linear}).width('100%')
      if(this.busy){Button('中断并保留缓存').height(48).onClick(()=>{this.syncer?.cancel();this.live?.cancel();this.device?.cancel();})}
      if(this.canResume){Button('继续上次同步').height(48).enabled(!this.busy).onClick(()=>{if(this.lastSource)this.sync(this.lastSource);})}
      if(this.listLoaded){
        Button('实时记录当前录音').height(48).enabled(!this.busy).onClick(()=>{this.startLive();})
        Text('每约 20 秒更新一段文字；停止接收不会结束录音豆录音。').fontSize(13).width('100%')
      }
      if(this.liveStatus){Text(this.liveStatus).fontSize(14).width('100%')}
      if(this.liveText){Text('实时转写草稿').fontSize(18).width('100%');Text(this.liveText).fontSize(16).width('100%')}
      Text('设备中的录音').fontSize(20).fontWeight(FontWeight.Bold).width('100%')
      if(!this.listLoaded){Text('连接成功后，这里会显示录音列表。').fontSize(14).width('100%')}
      else{Text(this.connectedName+' · '+this.files.length+' 条录音').fontSize(14).width('100%')}
      ForEach(this.files,(file:DeviceFile,index:number)=>{
        Column({space:8}){Text('录音 '+(index+1)).fontSize(18)
          Text('完整大小将在下载时核验').fontSize(14)
          if(this.showDiagnostics){Text('设备文件编号：'+file.id+'；列表原始值：'+file.transferBytes).fontSize(13)}
          Button('仅下载到手机缓存').height(48).enabled(!this.busy).onClick(()=>{if(this.device)this.downloadOnly({deviceId:this.device.deviceId,sourceId:String(file.id),title:'录音 '+(index+1)});})
          Button('同步这条录音').height(48).enabled(!this.busy).onClick(()=>{if(this.device)this.sync({deviceId:this.device.deviceId,sourceId:String(file.id),title:'录音 '+(index+1)});})
        }.width('100%').padding(12).border({width:1,color:'#dbe4e0'}).borderRadius(8)
      },(file:DeviceFile)=>String(file.id))
      Text('真机验收待完成；不会解绑、恢复出厂、升级固件或删除录音。').fontSize(13).width('100%')
    }.padding(24).width('100%')}.width('100%').height('100%')
  }
}
