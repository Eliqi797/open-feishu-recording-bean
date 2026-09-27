import { DeviceFile } from '../services/D3200Protocol';
import { TransferPanel } from './TransferPanel';
import { TransferView, emptyTransfer } from '../services/TransferProgress';
import { surface, ink, muted, accent, background, recordingDate, line, inset, attention } from '../services/AppTheme';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { media } from '@kit.MediaKit';
import { NativeCloud, CloudRecording, CloudJob, CloudDocument, CloudAction } from '../services/NativePorts';

function jobText(job:CloudJob):string{
  const names:Record<string,string>={'asr':'转写','diarization':'说话人字段处理','summary':'总结','feishu':'飞书文档'};
  const states:Record<string,string>={'pending':'等待','queued':'排队','running':'处理中','completed':'已处理','failed':'失败','blocked':'待解决','interrupted':'已中断'};
  return (names[job.stage]||job.stage)+'：'+(states[job.status]||job.status)+(job.error?' · '+job.error:'');
}
function clock(ms:number):string{const s=Math.max(0,Math.floor(ms/1000));return Math.floor(s/3600)+':'+String(Math.floor(s/60)%60).padStart(2,'0')+':'+String(s%60).padStart(2,'0');}
@Component
export struct CloudLibrary {
  @Builder emptyConnection(){}
  @BuilderParam connectionContent:()=>void=this.emptyConnection;
  @Prop @Watch('showHome') homeRequest:number=0;
  @Prop deviceFiles:DeviceFile[]=[];
  @Prop deviceId:string='';
  @Prop deviceListLoaded:boolean=false;
  onDownload:(file:DeviceFile)=>void=()=>{};
  onSync:(file:DeviceFile)=>void=()=>{};
  private scroller:Scroller=new Scroller();
  private showHome():void{this.stop();this.selected=undefined;this.scroller.scrollTo({xOffset:0,yOffset:0});}
  private pendingDeviceFiles():DeviceFile[]{return this.deviceListLoaded?this.deviceFiles.filter((f:DeviceFile)=>!this.recordings.some((r:CloudRecording)=>!!r.stored&&(r.device_id===this.deviceId||!!r.source_devices?.includes(this.deviceId))&&r.source_id===String(f.id))):[];}
  @Prop dark:boolean=false;
  @Prop deviceConnected:boolean=false;
  @Prop autoUpload:boolean=true;
  @Prop @Watch('transferChanged') transferView:TransferView=emptyTransfer();
  @Prop transferLocked:boolean=false;
  @Prop resumable:boolean=false;
  onAutoUpload:(enabled:boolean)=>void=()=>{};
  onHighSpeed:()=>void=()=>{};
  onStopTransfer:()=>void=()=>{};
  onSetup:()=>void=()=>{};
  @State resultTab:number=0;
  private docsOrigin:string='https://www.feishu.cn';
  @Prop @Watch('connectionChanged') origin:string='';
  @Prop active:boolean=true;
  private refreshTimer:number=-1;
  private wasTransferring:boolean=false;
  @Prop token:string='';
  @State recordings:CloudRecording[]=[];
  @State cloudLoaded:boolean=false;
  @State selected:CloudRecording|undefined=undefined;
  @State summaryText:string='';
  @State transcriptText:string='';
  @State transcriptPage:number=0;
  @State message:string='点击刷新，查看云端已保存的录音。';
  @State busy:boolean=false;
  @State playing:boolean=false;
  @State playback:string='';
  @State playbackMs:number=0;
  @State duration:number=0;
  private player:media.AVPlayer|undefined=undefined;
  private playerGeneration:number=0;
  private cloud():NativeCloud{return new NativeCloud(this.origin.trim(),this.token.trim());}
  private async refresh():Promise<void>{
    if(this.busy||this.transferView.active)return;this.busy=true;
    try{this.recordings=await this.cloud().recordings();this.cloudLoaded=true;try{this.docsOrigin=(await this.cloud().settings()).values['FEISHU_DOCS_ORIGIN']||'https://www.feishu.cn';}catch(_){}this.message=`云端 ${this.recordings.length} 条录音。`;if(this.selected)await this.details(this.selected.id);}
    catch(e){if(!this.transferView.active)this.message='读取失败：'+(e as Error).message;}finally{this.busy=false;}
  }
  private async details(id:string):Promise<void>{
    const cloud=this.cloud(),recording=await cloud.recording(id);this.selected=recording;this.summaryText='';this.transcriptText='';this.transcriptPage=0;
    if(recording.jobs.some((j:CloudJob)=>j.stage==='asr'&&j.status==='completed')){
      const transcript=await cloud.transcript(id);this.transcriptText=transcript.text;
      if(transcript.coverage?.status==='partial')this.summaryText='转写不完整：部分时段没有识别文字，请结合原音核对。\n\n';
    }
    if(recording.jobs.some((j:CloudJob)=>j.stage==='summary'&&j.status==='completed')){
      const summary=await cloud.summary(id);
      this.summaryText+=summary.summary+'\n\n结论\n'+summary.decisions.join('\n')+'\n\n待办\n'+summary.actions.map((a:CloudAction)=>a.task+' · 责任人：'+(a.owner||'待确认')+' · 日期：'+(a.due_date||'待确认')).join('\n')+'\n\n待确认\n'+summary.uncertainties.join('\n');
    }
  }
  private openCard(recording:CloudRecording):void{const doc=recording.publications.find((d:CloudDocument)=>d.status==='verified'&&!!d.document_id);if(doc)this.openDocument(doc.document_id);else this.select(recording.id);}
  private async select(id:string):Promise<void>{
    if(this.busy||this.transferView.active)return;this.busy=true;
    try{await this.stop();await this.details(id);this.message='已读取处理结果；说话人准确性仍需核验。';}
    catch(e){this.message='读取结果失败：'+(e as Error).message;}finally{this.busy=false;}
  }
  private async retry():Promise<void>{
    if(!this.selected||this.busy)return;this.busy=true;
    try{await this.cloud().pipeline(this.selected.id);await this.details(this.selected.id);this.message='已继续未完成阶段，点击刷新查看进度。';}
    catch(e){this.message='继续处理失败：'+(e as Error).message;}finally{this.busy=false;}
  }
  private async stop():Promise<void>{
    this.playerGeneration++;const player=this.player;this.player=undefined;this.playing=false;this.playbackMs=0;this.duration=0;
    try{await player?.release();}catch(_){}
  }
  private async play():Promise<void>{
    if(!this.selected)return;
    try{
      if(this.player?.state==='playing'){await this.player.pause();return;}
      if(this.player?.state==='paused'){await this.player.play();return;}
      await this.stop();const generation=this.playerGeneration;this.playback='正在连接受保护音频…';
      const player=await media.createAVPlayer();if(generation!==this.playerGeneration){await player.release();return;}this.player=player;
      player.on('stateChange',(state:string)=>{
        if(this.player!==player)return;
        this.playing=state==='playing';
        if(state==='initialized')player.prepare().catch((e:Error)=>{this.playback='音频准备失败：'+e.message;});
        if(state==='prepared'){this.duration=player.duration;player.play().catch((e:Error)=>{this.playback='播放失败：'+e.message;});}
        if(state==='playing')this.playback='受保护回听中';
        if(state==='paused')this.playback='已暂停';
        if(state==='completed')this.playback='播放结束';
      });
      player.on('timeUpdate',(ms:number)=>{if(this.player===player)this.playbackMs=ms;});
      player.on('error',(e:BusinessError)=>{if(this.player===player){this.playing=false;this.playback='回听失败，错误码 '+e.code;}});
      await player.setMediaSource(this.cloud().audioSource(this.selected.id));
    }catch(e){this.playback='回听未开始：'+(e as Error).message;}
  }
  private seek(delta:number):void{
    if(this.player&&['playing','paused','prepared','completed'].includes(this.player.state))this.player.seek(Math.max(0,Math.min(this.duration-1,this.playbackMs+delta)));
  }
  private async openDocument(id:string|null):Promise<void>{
    if(!id||!/^[A-Za-z0-9_-]{8,100}$/.test(id))return;
    try{const context=this.getUIContext().getHostContext() as common.UIAbilityContext;if(!/^https:\/\/[A-Za-z0-9-]+\.(feishu\.cn|larksuite\.com)\/?$/.test(this.docsOrigin))throw new Error('FEISHU_ORIGIN_INVALID');const docUrl=this.docsOrigin.replace(/\/$/,'')+'/docx/'+id;await context.openLink('https://applink.feishu.cn/client/docs/open?url='+encodeURIComponent(docUrl));}
    catch(e){this.message='打开飞书失败：'+(e as Error).message;}
  }
  aboutToAppear():void{if(this.origin&&this.token)this.refresh();this.refreshTimer=setInterval(()=>{if(this.active&&!this.busy&&!this.transferView.active&&this.origin&&this.token)this.refresh();},15000);}
  private transferChanged():void{const finished=this.wasTransferring&&!this.transferView.active;this.wasTransferring=this.transferView.active;if(finished&&this.origin&&this.token)this.refresh();}
  private connectionChanged():void{this.stop();this.recordings=[];this.cloudLoaded=false;this.selected=undefined;this.summaryText='';this.transcriptText='';}
  aboutToDisappear():void{if(this.refreshTimer>=0)clearInterval(this.refreshTimer);this.stop();}
  build(){
    Scroll(this.scroller){Column({space:18}){
      Row(){Text(this.selected?'录音详情':'录音').fontSize(30).fontWeight(FontWeight.Bold).fontColor(ink(this.dark)).layoutWeight(1);Button(this.busy?'读取中':'刷新').height(48).fontSize(15).fontColor(accent(this.dark)).backgroundColor(Color.Transparent).enabled(!this.busy&&!this.transferView.active&&!!this.origin).onClick(()=>{this.refresh();})}.width('100%')
      if(!this.selected){this.connectionContent()}
      if(!this.selected){TransferPanel({dark:this.dark,view:this.transferView,autoUpload:this.autoUpload,locked:this.transferLocked,connected:this.deviceConnected,resumable:this.resumable,onAutoUpload:this.onAutoUpload,onStart:this.onHighSpeed,onPause:this.onStopTransfer})}
      if(!this.selected&&!this.transferView.active&&this.pendingDeviceFiles().length){
        Text((this.cloudLoaded?'待同步录音':'设备录音')+' · '+this.pendingDeviceFiles().length+' 条').fontSize(16).fontWeight(FontWeight.Medium).fontColor(ink(this.dark)).width('100%')
        ForEach(this.pendingDeviceFiles(),(file:DeviceFile)=>{
          Column({space:10}){
            Row({space:12}){Image($r('app.media.tab_recordings')).width(28).height(28).fillColor(accent(this.dark));Column({space:6}){Text('录音 '+recordingDate(file.id)).fontSize(16).fontWeight(FontWeight.Medium).fontColor(ink(this.dark));Text('设备原件 · '+(this.deviceConnected?'可同步':'请重新连接')).fontSize(12).fontColor(muted(this.dark))}.layoutWeight(1).alignItems(HorizontalAlign.Start)}.width('100%')
            Row({space:8}){Button('下载到手机').height(48).layoutWeight(1).fontSize(14).fontColor(accent(this.dark)).backgroundColor(Color.Transparent).enabled(this.deviceConnected&&!this.transferLocked).onClick(()=>{this.onDownload(file);});Button('上传云端').height(48).layoutWeight(1).fontSize(14).fontColor(accent(this.dark)).backgroundColor(Color.Transparent).enabled(this.deviceConnected&&!this.transferLocked&&!!this.origin).onClick(()=>{this.onSync(file);})}.width('100%')
          }.padding(18).width('100%').backgroundColor(surface(this.dark)).borderRadius(16)
        },(file:DeviceFile)=>String(file.id))
      }
      if(!this.origin){
        Column({space:18}){Image($r('app.media.tab_recordings')).width(52).height(52);Text('让录音变成有用的记录').fontSize(21).fontWeight(FontWeight.Medium).fontColor(ink(this.dark));Text('连接你自己的服务，保存录音、回听原音，查看转写与总结。').fontSize(15).fontColor(muted(this.dark)).textAlign(TextAlign.Center).lineHeight(24);Button('设置服务连接').type(ButtonType.Normal).borderRadius(12).height(50).width('100%').backgroundColor(accent(this.dark)).fontColor(this.dark?'#102A27':'#FFFFFF').onClick(()=>{this.onSetup();})}.padding(20).width('100%').backgroundColor(surface(this.dark)).borderRadius(16)
      }else if(!this.selected){
        Row(){Text('云端录音').fontSize(18).fontWeight(FontWeight.Medium).fontColor(ink(this.dark)).layoutWeight(1);Text(this.cloudLoaded?this.recordings.length+' 条':'正在读取').fontSize(13).fontColor(muted(this.dark))}.width('100%').margin({top:8})
        if(!this.message.startsWith('云端 ')){Text(this.message).fontSize(13).fontColor(muted(this.dark)).width('100%')}
        if(!this.recordings.length&&!this.busy){Text('还没有云端录音\n连接录音豆，同步第一条录音。').fontSize(16).fontColor(muted(this.dark)).lineHeight(28).padding({top:48,bottom:48}).textAlign(TextAlign.Center).width('100%')}
        Column(){
          ForEach(this.recordings,(recording:CloudRecording,index:number)=>{
            Column({space:8}){
              Column({space:8}){
                Text(recording.title).fontSize(17).fontWeight(FontWeight.Medium).fontColor(ink(this.dark)).lineHeight(25).maxLines(3).textOverflow({overflow:TextOverflow.Ellipsis}).width('100%')
                Text(recording.recorded_at?'录于 '+recordingDate(recording.recorded_at):'录制时间未知 · 上传于 '+recordingDate(recording.created)).fontSize(12).fontColor(muted(this.dark)).width('100%')
              }.width('100%').alignItems(HorizontalAlign.Start).onClick(()=>{this.openCard(recording);})
              Row({space:8}){
                Text((recording.size/1048576).toFixed(1)+' MB · '+(recording.jobs.some((j:CloudJob)=>j.status==='running')?'正在处理':recording.jobs.some((j:CloudJob)=>j.status==='failed'||j.status==='blocked')?'需要处理':recording.jobs.some((j:CloudJob)=>j.stage==='summary'&&j.status==='completed')?'总结就绪':'已保存')).fontSize(12).fontColor(recording.jobs.some((j:CloudJob)=>j.status==='failed'||j.status==='blocked')?attention(this.dark):muted(this.dark)).layoutWeight(1)
                Button('回听',{type:ButtonType.Normal}).borderRadius(10).height(48).fontSize(13).padding({left:12,right:12}).fontColor(accent(this.dark)).backgroundColor(Color.Transparent).onClick(()=>{this.select(recording.id);})
                Button(recording.publications.some((d:CloudDocument)=>d.status==='verified'&&!!d.document_id)?'飞书文档':'查看详情',{type:ButtonType.Normal}).borderRadius(10).height(48).fontSize(13).padding({left:12,right:12}).fontColor(accent(this.dark)).backgroundColor(inset(this.dark)).onClick(()=>{this.openCard(recording);})
              }.width('100%')
            }.padding({top:18,bottom:14,left:18,right:18}).width('100%')
            if(index<this.recordings.length-1){Divider().color(line(this.dark)).margin({left:18,right:18})}
          },(recording:CloudRecording)=>recording.id+':'+recording.jobs.map((j:CloudJob)=>j.status).join(','))
        }.width('100%').backgroundColor(surface(this.dark)).borderRadius(16).clip(true)
      }else{
        Button('返回录音列表').height(48).fontColor(accent(this.dark)).backgroundColor(Color.Transparent).onClick(()=>{this.stop();this.selected=undefined;})
        Text(this.selected.recorded_at?'开始 '+recordingDate(this.selected.recorded_at):'录制时间未知').fontSize(13).fontColor(muted(this.dark)).width('100%')
        Text(this.selected.title).fontSize(23).fontWeight(FontWeight.Medium).fontColor(ink(this.dark)).width('100%')
        if(this.selected.stored){
          Column({space:16}){
            Text('原始录音').fontSize(15).fontWeight(FontWeight.Medium).fontColor(ink(this.dark)).width('100%')
            Row({space:8}){Button('−30 秒').height(48).layoutWeight(1).fontSize(14).fontColor(accent(this.dark)).backgroundColor(Color.Transparent).onClick(()=>{this.seek(-30000);});Button(this.playing?'暂停':'播放').height(52).layoutWeight(1).backgroundColor(accent(this.dark)).fontColor(this.dark?'#102A27':'#FFFFFF').onClick(()=>{this.play();});Button('+30 秒').height(48).layoutWeight(1).fontSize(14).fontColor(accent(this.dark)).backgroundColor(Color.Transparent).onClick(()=>{this.seek(30000);})}
            Progress({value:this.playbackMs,total:Math.max(1,this.duration),type:ProgressType.Linear}).color(accent(this.dark)).width('100%')
            Text(this.duration?clock(this.playbackMs)+' / '+clock(this.duration):'播放后显示时长').fontSize(13).fontColor(muted(this.dark))
            if(this.playback){Text(this.playback).fontSize(12).fontColor(muted(this.dark))}
          }.padding(20).width('100%').backgroundColor(surface(this.dark)).borderRadius(16)
        }
        Row({space:8}){ForEach(['总结','转写','处理状态'],(title:string,index:number)=>{Button(title,{type:ButtonType.Normal}).borderRadius(12).height(48).layoutWeight(1).fontSize(14).backgroundColor(this.resultTab===index?accent(this.dark):surface(this.dark)).fontColor(this.resultTab===index?(this.dark?'#102A27':'#FFFFFF'):ink(this.dark)).onClick(()=>{this.resultTab=index;})})}.width('100%')
        if(this.resultTab===0){
          Text(this.summaryText||(this.busy?'正在读取总结…':'总结尚未生成。可在处理状态中继续任务。')).fontSize(16).fontColor(this.summaryText?ink(this.dark):muted(this.dark)).lineHeight(27).copyOption(CopyOptions.LocalDevice).padding(20).width('100%').backgroundColor(surface(this.dark)).borderRadius(16)
          ForEach(this.selected.publications,(doc:CloudDocument)=>{if(doc.document_id){Button('在飞书中打开').height(48).width('100%').fontColor(accent(this.dark)).backgroundColor(surface(this.dark)).onClick(()=>{this.openDocument(doc.document_id);})}},(doc:CloudDocument)=>doc.document_id||doc.title)
        }else if(this.resultTab===1){
          Text(this.transcriptText?this.transcriptText.slice(this.transcriptPage*4000,(this.transcriptPage+1)*4000):(this.busy?'正在读取转写…':'转写尚未生成。')).fontSize(16).fontColor(ink(this.dark)).lineHeight(27).copyOption(CopyOptions.LocalDevice).padding(20).width('100%').backgroundColor(surface(this.dark)).borderRadius(16)
          if(this.transcriptText.length>4000){Row({space:8}){Button('上一页').height(48).enabled(this.transcriptPage>0).onClick(()=>{this.transcriptPage--;});Text(String(this.transcriptPage+1)).fontColor(muted(this.dark));Button('下一页').height(48).enabled((this.transcriptPage+1)*4000<this.transcriptText.length).onClick(()=>{this.transcriptPage++;})}}
        }else{
          Column({space:14}){ForEach(this.selected.jobs,(job:CloudJob)=>{Text(jobText(job)).fontSize(14).fontColor(ink(this.dark)).width('100%')},(job:CloudJob)=>(this.selected?this.selected.id:'')+':'+job.stage+':'+job.status+':'+(job.error||''));Button('继续处理 / 重试').height(48).width('100%').enabled(!this.busy).backgroundColor(accent(this.dark)).fontColor(this.dark?'#102A27':'#FFFFFF').onClick(()=>{this.retry();})}.padding(20).width('100%').backgroundColor(surface(this.dark)).borderRadius(16)
          Text(this.message).fontSize(13).fontColor(muted(this.dark)).width('100%')
        }
      }
    }.padding(20).width('100%').alignItems(HorizontalAlign.Start)}.align(Alignment.TopStart).width('100%').height('100%')
  }
}
