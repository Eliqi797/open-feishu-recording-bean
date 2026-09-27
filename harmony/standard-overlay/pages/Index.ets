import { DeviceStatusBar } from './DeviceStatusBar';
import { TransferPanel } from './TransferPanel';
import { TransferView, TransferSpeed, emptyTransfer } from '../services/TransferProgress';
import { BatchSync, pendingRecordings } from '../services/BatchSync';
import { window } from '@kit.ArkUI';
import { SettingsPanel } from './SettingsPanel';
import { AppPreferences } from '../services/AppPreferences';
import { background, surface, ink, muted, accent, line, recordingDate } from '../services/AppTheme';
import { ConfigurationConstant } from '@kit.AbilityKit';
import { CloudLibrary } from './CloudLibrary';
import BuildProfile from 'BuildProfile';
import { fileIo as fs } from '@kit.CoreFileKit';
import { LiveController, LiveStatusSegment } from '../services/LiveController';
import { ble } from '@kit.ConnectivityKit';
import { abilityAccessCtrl, common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { NativeCache, NativeCloud } from '../services/NativePorts';
import { D3200Device, DeviceStatus } from '../services/D3200Device';
import { DeviceFile } from '../services/D3200Protocol';
import { SyncController, RecordingRef, Receipt } from '../services/SyncController';

interface DebugCloud { origin:string; token:string; }
interface DeviceCandidate { id:string; name:string; number:number; lastSeen:number; }

@Entry
@Component
struct Index {
  @State showDeviceControls:boolean=false;
  @State homeRequest:number=0;
  @State transferView:TransferView=emptyTransfer();
  @State batchSources:RecordingRef[]=[];
  private speed:TransferSpeed=new TransferSpeed();
  private transferTick:number=-1;
  private lastPaint:number=0;
  @State autoUpload:boolean=true;
  @State batchActive:boolean=false;
  @State transferStatus:string='';
  private batch:BatchSync|undefined=undefined;
  private autoTimer:number=-1;
  private stopRequested:boolean=false;
  private autoPaused:boolean=false;
  @State liveWindowSeconds:number=5;
  @State keepAwake:boolean=false;
  @State link:string='disconnected';
  @State battery:number|null=null;
  @State charging:boolean|null=null;
  @State caseBattery:number|null=null;
  @State caseCharging:boolean|null=null;
  @State recording:number=-1;
  @State deviceUpdated:number=0;
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
  @State tab:number=0;
  @State theme:string='system';
  @StorageLink('beanSystemDark') @Watch('systemThemeChanged') systemDark:boolean=false;
  @State dark:boolean=false;
  @State liveActive:boolean=false;
  @State settingsMessage:string='';
  private preferences:AppPreferences|undefined=undefined;
  @State token:string='';
  @State progress:number=0;
  @State wifi:boolean=true;
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
    this.preferences=new AppPreferences(context.filesDir);
    try{const prefs=this.preferences.read();this.origin=prefs.origin;this.theme=prefs.theme;this.wifi=prefs.wifi;this.autoUpload=prefs.autoUpload!==false;this.keepAwake=prefs.keepAwake||false;this.liveWindowSeconds=[2,5,10,20].includes(prefs.liveWindowSeconds||5)?prefs.liveWindowSeconds||5:5;this.token=this.preferences.token(this.origin);
      if(!this.origin&&BuildProfile.DEBUG){const path=context.filesDir+'/debug-cloud.json';if(fs.accessSync(path)){const config=JSON.parse(fs.readTextSync(path)) as DebugCloud;if(config.origin.startsWith('https://')){this.preferences.save({origin:config.origin,theme:this.theme,wifi:this.wifi},config.token);this.origin=config.origin;this.token=config.token;fs.unlinkSync(path);}}}
    }catch(_){this.settingsMessage='无法读取安全存储，请重新设置服务连接。';}
    this.updateTheme(this.theme);
    this.device=new D3200Device(this.cache,(done:number,total:number)=>{if(this.liveActive){this.progress=0;return;}this.updateTransfer('downloading',done,total);});
    this.device.onStatus=(state:DeviceStatus)=>{this.link=state.link;this.battery=state.battery;this.charging=state.charging;this.caseBattery=state.caseBattery;this.caseCharging=state.caseCharging;this.recording=state.recording;this.deviceUpdated=state.updated;if(state.link==='disconnected'){this.listLoaded=false;}};
    if(this.origin&&this.token){new NativeCloud(this.origin,this.token).recordings().then(async(recordings)=>{if(!this.busy)await this.cache?.pruneArchived(recordings);}).catch(()=>{});}
    this.autoTimer=setInterval(()=>{if(this.autoUpload&&!this.autoPaused&&!this.busy&&this.link==='ready'&&this.origin)this.syncAll(this.wifi,true);},15000);
    try{this.batchSources=this.cache.pendingBatch(this.origin);}catch(_){this.status='传输记录读取失败，缓存保留';}
    this.transferTick=setInterval(()=>{if(this.transferView.active){const v=this.transferView;this.transferView={active:v.active,phase:v.phase,fileTitle:v.fileTitle,index:v.index,count:v.count,downloaded:v.downloaded,uploaded:v.uploaded,done:v.done,total:v.total,speed:['downloading','uploading'].includes(v.phase)?this.speed.value(Date.now()):0,message:v.message};}},500);
    const journal=this.cache.lastJournal();if(journal&&journal.phase!=='completed'){this.lastSource=journal.source;this.canResume=true;this.status='有未完成同步。已完整缓存的文件可续传；下载中断请重新连接设备。';}
  }
  private systemThemeChanged():void{if(this.theme==='system'){this.dark=this.systemDark;this.updateBars();}}
  private updateBars():void{const context=this.getUIContext().getHostContext() as common.UIAbilityContext;window.getLastWindow(context).then((win:window.Window)=>{win.setWindowKeepScreenOn(this.keepAwake).catch(()=>{});win.setWindowSystemBarProperties({statusBarColor:background(this.dark),navigationBarColor:surface(this.dark),statusBarContentColor:ink(this.dark),navigationBarContentColor:ink(this.dark)});}).catch(()=>{});}
  private updateTheme(mode:string):void{
    this.theme=mode;
    const context=this.getUIContext().getHostContext() as common.UIAbilityContext;
    context.getApplicationContext().setColorMode(mode==='dark'?ConfigurationConstant.ColorMode.COLOR_MODE_DARK:mode==='light'?ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT:ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
    this.dark=mode==='dark'||(mode==='system'&&this.systemDark);this.updateBars();
    try{this.preferences?.save({origin:this.origin,theme:mode,wifi:this.wifi},'');}catch(_){this.settingsMessage='外观暂未保存，重新打开后可能恢复默认。';}
  }
  private async saveConnection(origin:string,token:string):Promise<void>{
    if(this.busy)return;this.busy=true;
    try{await new NativeCloud(origin,token).check();this.preferences?.save({origin:origin,theme:this.theme,wifi:this.wifi},token);this.origin=origin;this.token=token;this.settingsMessage='连接验证通过，已安全保存。';}
    catch(_){this.settingsMessage='连接或安全保存失败，请检查 HTTPS 地址和访问口令。';}finally{this.busy=false;}
  }
  private async refreshDevice():Promise<void>{if(this.busy||this.link!=='ready')return;this.busy=true;try{await this.device?.refreshStatus();this.status='设备状态已更新';}catch(_){this.status='状态更新失败，请检查设备连接';}finally{this.busy=false;}}
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
    this.autoPaused=false;this.stopScan();this.busy=true;this.files=[];this.listLoaded=false;this.connectedName='';this.connectionError='';this.connectionDetails='';this.status='连接并协商加密会话…';
    try{await this.device.connect(id);this.files=await this.device.list();this.listLoaded=true;const candidate=this.devices.find((item:DeviceCandidate)=>item.id===id);this.connectedName=candidate?candidate.name:'D3200 录音豆';this.showDeviceControls=false;this.status=`已读到 ${this.files.length} 条录音。`+(this.device.isRecording()?'设备正在录音，可开启实时记录；完整下载需等录音结束。':'原文件保留在录音豆。');}
    catch(error){this.connectionDetails=this.device.diagnostics();this.connectionError=(error as Error).message;if(this.connectionError==='D3200_CONNECT_TIMEOUT'||this.connectionError==='D3200_DISCONNECTED')this.devices=[];this.status=this.connectionError==='D3200_STABLE_ID_UNAVAILABLE'?'未取得有效设备序列号，已停止同步以避免重复归档。可展开诊断信息。':this.connectionError==='D3200_SHARED_SECRET_MISMATCH'?'设备已找到，但加密连接校验未通过，尚未读取录音。':'设备连接未完成，请保持录音豆唤醒并重新扫描。可展开诊断信息。';}finally{this.busy=false;}
    if(this.autoUpload&&this.listLoaded&&this.origin)await this.syncAll(this.wifi,true);
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
  private async recoverLive():Promise<void>{
    if(!this.device||!this.cache||this.busy)return;this.busy=true;
    try{
      this.live=new LiveController(this.device,this.cache,new NativeCloud(this.origin.trim(),this.token.trim()),(message:string)=>{this.liveStatus=message;});
      await this.live.recoverPending();await this.pollLive();this.status='实时分段恢复完成；仍需同步设备完整录音才能归档。';
    }catch(error){this.status='实时恢复未完成：'+(error as Error).message+'。手机分段保留，可重试。';}
    finally{this.busy=false;}
  }
  private async startLive():Promise<void>{
    if(!this.device||!this.cache||this.busy)return;this.busy=true;this.liveActive=true;this.liveText='';this.liveStatus='连接实时服务…';
    try{
      const cloud=new NativeCloud(this.origin.trim(),this.token.trim());
      this.live=new LiveController(this.device,this.cache,cloud,(message:string)=>{this.liveStatus=message;});
      this.liveTimer=setInterval(()=>{this.pollLive();},1000);
      const id=this.device.currentRecordingId;if(!id||id==='0')throw new Error('D3200_NO_ACTIVE_RECORDING');
      const recording=await this.live.start({deviceId:this.device.deviceId,sourceId:id,title:'实时录音 '+id},this.liveWindowSeconds);
      await this.pollLive();this.status='完整录音已校验归档：'+recording+'，后台继续生成最终纪要。';
    }catch(error){this.status='实时接收已停止：'+(error as Error).message+'。设备原件和手机分段保留；中断不会被标记为完整录音。';}
    finally{if(this.liveTimer>=0)clearInterval(this.liveTimer);this.liveTimer=-1;this.busy=false;this.liveActive=false;}
  }
  private async downloadOnly(source:RecordingRef):Promise<void>{
    if(!this.device||!this.cache||this.busy)return;this.busy=true;this.lastSource=source;this.canResume=true;this.device.useWifi=this.wifi;this.transferView=emptyTransfer();this.transferFile('checking',source,0,1);
    try{
      this.syncer=new SyncController(this.device,this.cache,undefined,(phase:string,done:number,total:number)=>{this.updateTransfer(phase,done,total,true);});
      const audio=await this.syncer.downloadOnly(source);
      this.status=`已下载并校验 ${(audio.size/1048576).toFixed(2)} MB。仅保存在手机缓存，尚未上传；设备原件保留。`;
    }catch(error){const code=(error as Error).message;this.status=code==='D3200_RECORDING_NOT_FINALIZED'?'这条录音尚未结束。请在录音豆上停止录音，再重新连接、刷新列表后下载。':`下载未完成：${code}。缓存和设备原件保留，可重新连接后重试。`;}
    finally{this.finishTransfer(this.canResume?'paused':'completed',this.status);this.busy=false;}
  }
  private async sync(source:RecordingRef):Promise<void>{
    if(!this.device||!this.cache)return;this.busy=true;this.lastSource=source;this.canResume=true;this.device.useWifi=this.wifi;this.transferView=emptyTransfer();this.transferFile('checking',source,0,1);
    try{
      const cloud=new NativeCloud(this.origin.trim(),this.token.trim());
      this.syncer=new SyncController(this.device,this.cache,cloud,(phase:string,done:number,total:number)=>{this.updateTransfer(phase,done,total,true);});
      const receipt=await this.syncer.sync(source);this.status=`已保存并校验：${receipt.recording_id}。手机缓存已清理，录音豆原件保留。`;this.canResume=false;
    }catch(error){this.status=`同步未完成：${(error as Error).message}。请保留原件，重新点击可重试。`;}
    finally{this.finishTransfer(this.canResume?'paused':'completed',this.status);this.busy=false;}
  }
  private setAutoUpload(enabled:boolean):void{
    this.autoUpload=enabled;if(enabled)this.autoPaused=false;try{this.preferences?.save({origin:this.origin,theme:this.theme,wifi:this.wifi,autoUpload:enabled},'');}catch(_){this.settingsMessage='自动上传偏好保存失败';}
    if(enabled&&!this.busy&&this.link==='ready'&&this.origin)this.syncAll(this.wifi,true);
  }
  private stopSync():void{this.autoPaused=true;this.stopRequested=true;this.batch?.cancel();this.syncer?.cancel();this.device?.cancel();}
  private updateTransfer(phase:string,done:number,total:number,force:boolean=false):void{
    if(!this.transferView.active)return;
    const now=Date.now(),changed=phase!==this.transferView.phase;
    if(changed||phase==='resuming')this.speed.reset(now,done);else this.speed.add(now,done);
    if(!force&&!changed&&now-this.lastPaint<250&&done!==total)return;
    this.lastPaint=now;
    const previous=this.transferView;
    this.transferView={active:true,phase,fileTitle:previous.fileTitle,index:previous.index,count:previous.count,
      downloaded:phase==='cached'?Math.max(previous.downloaded,previous.index):previous.downloaded,
      uploaded:phase==='completed'?Math.max(previous.uploaded,previous.index):previous.uploaded,
      done,total,speed:['downloading','uploading'].includes(phase)?this.speed.value(now):0,message:''};
    this.progress=total?Math.min(100,Math.floor(done/total*100)):0;
  }
  private transferFile(phase:string,source:RecordingRef,index:number,count:number):void{
    const previous=this.transferView;this.speed.reset(Date.now());
    this.transferView={active:true,phase,fileTitle:source.title,index:index+1,count,downloaded:phase==='uploading'?count:previous.downloaded,uploaded:previous.uploaded,done:0,total:0,speed:0,message:''};
    this.lastSource=source;this.canResume=true;
  }
  private finishTransfer(phase:string,message:string):void{
    const old=this.transferView;
    this.transferView={active:false,phase,fileTitle:old.fileTitle,index:old.index,count:old.count,downloaded:old.downloaded,uploaded:old.uploaded,done:old.done,total:old.total,speed:0,message};
    this.transferStatus=message;this.status=message;
  }
  private async syncAll(highSpeed:boolean,automatic:boolean=false):Promise<void>{
    if(this.busy||!this.device||!this.cache)return;
    if(!this.origin){this.tab=2;this.settingsMessage='请先设置云端连接';return;}
    if(automatic&&this.autoPaused)return;
    this.busy=true;this.stopRequested=false;
    const device=this.device,cache=this.cache,cloud=new NativeCloud(this.origin.trim(),this.token.trim());
    try{
      let sources=cache.pendingBatch(this.origin);
      if(this.link==='ready'){
        await device.refreshStatus();
        if(device.isRecording()){this.finishTransfer('idle','录音进行中，结束后自动上传');return;}
        this.files=await device.list();this.listLoaded=true;
        sources=sources.concat(this.files.map((file:DeviceFile)=>{const ref:RecordingRef={deviceId:device.deviceId,sourceId:String(file.id),title:'录音 '+recordingDate(file.id)};return ref;}));
      }else if(!sources.length){if(!automatic)this.openDeviceControls();return;}
      const pending=pendingRecordings(sources,await cloud.recordings());
      this.batchSources=pending;cache.savePendingBatch(this.origin,pending);
      if(!pending.length){this.finishTransfer('completed','全部录音已上传');return;}
      let missing=false;
      for(const source of pending){if(!await cache.findVerified(source))missing=true;}
      if(missing&&this.link!=='ready'){this.finishTransfer('paused','部分录音尚未下载，请连接录音豆继续');if(!automatic)this.openDeviceControls();return;}
      if(this.stopRequested)throw new Error('SYNC_CANCELLED');
      this.autoPaused=false;this.batchActive=true;device.useWifi=highSpeed;this.batch=new BatchSync();
      this.transferView=emptyTransfer();this.transferFile('checking',pending[0],0,pending.length);
      const completed=await this.batch.transfer(pending,device,cache,cloud,
        (phase:string,source:RecordingRef,index:number,count:number)=>{this.transferFile(phase,source,index,count);},
        (phase:string,done:number,total:number)=>{this.updateTransfer(phase,done,total);},
        async(source:RecordingRef):Promise<void>=>{this.batchSources=this.batchSources.filter((s:RecordingRef)=>s.deviceId!==source.deviceId||s.sourceId!==source.sourceId);cache.savePendingBatch(this.origin,this.batchSources);});
      this.canResume=false;this.finishTransfer('completed','已上传 '+completed+' 条录音，手机缓存已清理');
    }catch(error){
      this.autoPaused=true;this.connectionError=(error as Error).message;this.connectionDetails=device.diagnostics();
      const message=this.stopRequested?'已暂停，已下载文件保留，可继续传输':this.connectionError.includes('INSUFFICIENT_STORAGE')?'手机空间不足，已下载文件保留；腾出空间后继续':this.connectionError.includes('CLOUD')||this.connectionError.includes('INTERNET')?'云端暂时无法连接，音频已缓存，可继续上传':'传输中断，已下载文件保留，可继续传输';
      this.finishTransfer(this.stopRequested?'paused':'failed',message);
    }finally{this.busy=false;this.batchActive=false;this.batch=undefined;}
  }
  aboutToDisappear():void{if(this.transferTick>=0)clearInterval(this.transferTick);if(this.autoTimer>=0)clearInterval(this.autoTimer);this.batch?.cancel();this.stopScan();this.syncer?.cancel();this.live?.cancel();if(this.liveTimer>=0)clearInterval(this.liveTimer);this.device?.close();this.token='';}
  @Builder tabLabel(index:number,label:string,icon:Resource){
    Column({space:4}){Image(icon).width(23).height(23).fillColor(this.tab===index?accent(this.dark):muted(this.dark));Text(label).fontSize(12).fontWeight(this.tab===index?FontWeight.Bold:FontWeight.Regular).fontColor(this.tab===index?accent(this.dark):muted(this.dark))}.width('100%').height(60).justifyContent(FlexAlign.Center).backgroundColor(surface(this.dark))
  }
  private openDeviceControls():void{this.tab=0;this.showDeviceControls=true;this.homeRequest++;}
  private source(file:DeviceFile):RecordingRef{return {deviceId:this.device?this.device.deviceId:'',sourceId:String(file.id),title:'录音 '+recordingDate(file.id)};}
  @Builder deviceControls(){
    if(this.showDeviceControls){
      Column({space:12}){
        Row(){Text(this.listLoaded?(this.connectedName||'我的录音豆'):'连接录音豆').fontSize(18).fontWeight(FontWeight.Medium).fontColor(ink(this.dark)).layoutWeight(1);if(this.listLoaded){Button('收起').height(48).fontSize(14).fontColor(muted(this.dark)).backgroundColor(Color.Transparent).onClick(()=>{this.showDeviceControls=false;})}}.width('100%')
        if(this.link==='ready'){
          Text('设备有 '+this.files.length+' 条录音 · 状态更新于 '+recordingDate(this.deviceUpdated/1000).slice(11)).fontSize(12).fontColor(muted(this.dark)).width('100%')
          Button('刷新设备状态').height(48).width('100%').fontColor(accent(this.dark)).backgroundColor(Color.Transparent).enabled(!this.busy).onClick(()=>{this.refreshDevice();})
        }else{Text('唤醒录音豆并放在手机旁，连接后自动读取录音。').fontSize(14).fontColor(muted(this.dark)).width('100%')}
        Button(this.scanning?'正在寻找设备…':this.listLoaded?'重新扫描':'扫描录音豆').height(48).width('100%').backgroundColor(accent(this.dark)).fontColor(this.dark?'#102A27':'#FFFFFF').enabled(!this.scanning&&!this.busy).onClick(()=>{this.scan();})
        ForEach(this.devices,(candidate:DeviceCandidate)=>{Row(){Text(candidate.name).fontSize(15).fontColor(ink(this.dark)).layoutWeight(1);Button('连接').height(48).fontColor(accent(this.dark)).backgroundColor(Color.Transparent).enabled(!this.busy).onClick(()=>{this.connect(candidate.id);})}.width('100%')},(candidate:DeviceCandidate)=>candidate.id)
        Text(this.status).fontSize(13).fontColor(muted(this.dark)).width('100%')
        Button(this.showDiagnostics?'收起诊断信息':'查看诊断信息').height(48).fontSize(13).fontColor(muted(this.dark)).backgroundColor(Color.Transparent).onClick(()=>{this.showDiagnostics=!this.showDiagnostics;})
        if(this.showDiagnostics){Text(this.connectionError+'\n'+this.connectionDetails).fontSize(12).fontColor(muted(this.dark)).width('100%')}
      }.padding(18).width('100%').backgroundColor(surface(this.dark)).borderRadius(16)
    }
  }
  @Builder realtimePage(){
    Scroll(){Column({space:16}){
      Text('实时转写').fontSize(30).fontWeight(FontWeight.Bold).fontColor(ink(this.dark)).width('100%')
      Text('边录音，边看文字').fontSize(14).fontColor(muted(this.dark)).width('100%')
      Column({space:16}){
        Row({space:12}){Image($r('app.media.tab_live')).width(28).height(28).fillColor(accent(this.dark));Text(this.liveActive?'正在接收录音':this.listLoaded?'准备开始':'先连接录音豆').fontSize(20).fontWeight(FontWeight.Medium).fontColor(ink(this.dark)).layoutWeight(1)}.width('100%')
        Text('在设备上开始录音，每 '+this.liveWindowSeconds+' 秒上传一段，识别后显示文字。').fontSize(14).fontColor(muted(this.dark)).width('100%').lineHeight(23)
        Button(this.liveActive?'停止接收':this.listLoaded?'开始实时转写':'前往连接设备').type(ButtonType.Normal).borderRadius(12).height(52).width('100%').fontColor(this.dark?'#102A27':'#FFFFFF').backgroundColor(accent(this.dark)).enabled(this.liveActive||!this.busy).onClick(()=>{if(this.liveActive)this.live?.cancel();else if(!this.listLoaded)this.openDeviceControls();else if(!this.origin){this.tab=2;this.settingsMessage='请先设置服务连接。';}else this.startLive();})
        Text('停止接收不会结束设备录音，也不会删除原件。').fontSize(12).fontColor(muted(this.dark)).width('100%').lineHeight(20)
      }.padding(20).width('100%').backgroundColor(surface(this.dark)).borderRadius(16)
      if(this.liveStatus){Text(this.liveStatus).fontSize(14).fontColor(muted(this.dark)).width('100%')}
      if(this.liveText){Column({space:14}){Text('转写草稿').fontSize(17).fontWeight(FontWeight.Medium).fontColor(ink(this.dark)).width('100%');Text(this.liveText).fontSize(17).fontColor(ink(this.dark)).lineHeight(28).copyOption(CopyOptions.LocalDevice).width('100%')}.padding(20).backgroundColor(surface(this.dark)).borderRadius(16).width('100%')}
      if(!this.liveText){Text(this.liveActive?'正在等待识别结果…':'转写文字会显示在这里，可随时复制。').fontSize(14).fontColor(muted(this.dark)).lineHeight(24).width('100%').padding({top:20,bottom:20})}
      Button('恢复未上传分段').height(48).fontColor(accent(this.dark)).backgroundColor(Color.Transparent).enabled(!this.busy&&!!this.origin).onClick(()=>{this.recoverLive();})
    }.padding(20).width('100%')}.align(Alignment.TopStart).height('100%').width('100%')
  }
  build(){
    Column(){
      DeviceStatusBar({dark:this.dark,link:this.link,battery:this.battery,charging:this.charging,caseBattery:this.caseBattery,caseCharging:this.caseCharging,recording:this.recording,transferActive:this.transferView.active,transferPhase:this.transferView.phase,live:this.liveActive,onManage:()=>{this.openDeviceControls();}})
      if(this.tab===2&&this.settingsMessage){Text(this.settingsMessage).fontSize(13).fontColor(ink(this.dark)).padding(12).width('100%').backgroundColor(surface(this.dark))}
      Tabs({barPosition:BarPosition.End,index:this.tab}){
        TabContent(){CloudLibrary({connectionContent:()=>{this.deviceControls();},homeRequest:this.homeRequest,deviceFiles:this.files,deviceId:this.device?this.device.deviceId:'',deviceListLoaded:this.listLoaded,onDownload:(file:DeviceFile)=>{this.downloadOnly(this.source(file));},onSync:(file:DeviceFile)=>{this.sync(this.source(file));},origin:this.origin,token:this.token,active:this.tab===0,dark:this.dark,deviceConnected:this.link==='ready'||this.link==='transferring',autoUpload:this.autoUpload,transferView:this.transferView,transferLocked:this.busy||this.liveActive,resumable:this.batchSources.length>0,onAutoUpload:(enabled:boolean)=>{this.setAutoUpload(enabled);},onHighSpeed:()=>{this.syncAll(true);},onStopTransfer:()=>{this.stopSync();},onSetup:()=>{this.tab=2;}})}.tabBar(this.tabLabel(0,'录音',$r('app.media.tab_recordings')))
        TabContent(){this.realtimePage()}.tabBar(this.tabLabel(1,'实时',$r('app.media.tab_live')))
        TabContent(){SettingsPanel({origin:this.origin,token:this.token,dark:this.dark,theme:this.theme,wifi:this.wifi,locked:this.busy,autoUpload:this.autoUpload,onAutoUpload:(enabled:boolean)=>{this.setAutoUpload(enabled);},keepAwake:this.keepAwake,liveWindowSeconds:this.liveWindowSeconds,onLiveWindow:(seconds:number)=>{this.liveWindowSeconds=seconds;this.preferences?.save({origin:this.origin,theme:this.theme,wifi:this.wifi,liveWindowSeconds:seconds},'');},onKeepAwake:(enabled:boolean)=>{this.keepAwake=enabled;this.preferences?.save({origin:this.origin,theme:this.theme,wifi:this.wifi,keepAwake:enabled},'');this.updateBars();},onConnection:(origin:string,token:string)=>{this.saveConnection(origin,token);},onTheme:(mode:string)=>{this.updateTheme(mode);},onWifi:(wifi:boolean)=>{this.wifi=wifi;try{this.preferences?.save({origin:this.origin,theme:this.theme,wifi:wifi},'');}catch(_){this.settingsMessage='传输偏好保存失败';}}})}.tabBar(this.tabLabel(2,'设置',$r('app.media.tab_settings')))
      }.layoutWeight(1).width('100%').barHeight(68).scrollable(false).animationDuration(180).onChange((index:number)=>{this.tab=index;this.dark=this.theme==='dark'||(this.theme==='system'&&this.systemDark);})
    }.align(Alignment.TopStart).width('100%').height('100%').backgroundColor(background(this.dark))
  }
}
