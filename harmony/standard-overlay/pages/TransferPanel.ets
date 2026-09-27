import { TransferView, emptyTransfer, transferBytes } from '../services/TransferProgress';
import { surface, ink, muted, accent, inset, attention } from '../services/AppTheme';
function phaseTitle(phase:string):string{
  const names:Record<string,string>={'retrying':'网络波动，正在重试','checking':'检查录音','connecting':'连接录音豆 Wi-Fi','downloading':'下载到手机','cached':'文件已缓存','restoring_network':'恢复互联网','uploading':'上传到云端','resuming':'核对续传位置','verifying':'云端校验','completed':'传输完成','paused':'传输已暂停','failed':'需要继续传输'};
  return names[phase]||'准备传输';
}
@Component
export struct TransferPanel {
  @Prop dark:boolean=false;
  @Prop view:TransferView=emptyTransfer();
  @Prop autoUpload:boolean=true;
  @Prop locked:boolean=false;
  @Prop connected:boolean=false;
  @Prop resumable:boolean=false;
  onAutoUpload:(enabled:boolean)=>void=()=>{};
  onStart:()=>void=()=>{};
  onPause:()=>void=()=>{};
  build(){
    Column({space:12}){
      if(this.view.active){
        Row(){Text(phaseTitle(this.view.phase)).fontSize(18).fontWeight(FontWeight.Medium).fontColor(ink(this.dark)).layoutWeight(1);Text(this.view.index+' / '+this.view.count).fontSize(14).fontColor(muted(this.dark))}.width('100%')
        Text(this.view.fileTitle).fontSize(13).fontColor(muted(this.dark)).maxLines(1).textOverflow({overflow:TextOverflow.Ellipsis}).width('100%')
        if(['downloading','uploading','resuming','verifying','cached'].includes(this.view.phase)){
          Row(){Text(transferBytes(this.view.done)+(this.view.total?' / '+transferBytes(this.view.total):'')).fontSize(14).fontColor(ink(this.dark)).layoutWeight(1);Text(['downloading','uploading'].includes(this.view.phase)?transferBytes(this.view.speed)+'/s':this.view.phase==='verifying'?'等待核验':'—').fontSize(14).fontColor(accent(this.dark))}.width('100%')
          Progress({value:this.view.total?Math.min(100,this.view.done/this.view.total*100):0,total:100,type:ProgressType.Linear}).color(accent(this.dark)).width('100%')
        }else{LoadingProgress().width(26).height(26).color(accent(this.dark))}
        Text('已下载 '+this.view.downloaded+'/'+this.view.count+' · 已上传 '+this.view.uploaded+'/'+this.view.count).fontSize(12).fontColor(muted(this.dark)).width('100%')
        Text(this.view.phase==='connecting'?'本批次只需连接一次 Wi-Fi':'全部下载完成后自动上传，云端校验通过后清理手机缓存').fontSize(12).fontColor(muted(this.dark)).width('100%')
        Button('暂停传输').height(48).width('100%').fontColor(accent(this.dark)).backgroundColor(Color.Transparent).onClick(()=>{this.onPause();})
      }else{
        Row(){Column({space:4}){Text('自动上传').fontSize(16).fontWeight(FontWeight.Medium).fontColor(ink(this.dark));Text('连接设备后同步新录音').fontSize(12).fontColor(muted(this.dark))}.alignItems(HorizontalAlign.Start).layoutWeight(1);Toggle({type:ToggleType.Switch,isOn:this.autoUpload}).selectedColor(accent(this.dark)).enabled(!this.locked).onChange((v:boolean)=>{this.onAutoUpload(v);})}.width('100%')
        Row({space:12}){
          Column({space:4}){
            Text(this.view.message||'同步设备录音').fontSize(14).fontColor(this.view.phase==='failed'?attention(this.dark):ink(this.dark)).width('100%')
            Text(this.resumable?'优先上传手机已有缓存':'一次连接，批量同步').fontSize(12).fontColor(muted(this.dark)).width('100%')
          }.layoutWeight(1).alignItems(HorizontalAlign.Start)
          Button(this.resumable?'继续传输':'高速传输',{type:ButtonType.Normal}).borderRadius(12).height(48).fontSize(14).padding({left:16,right:16}).backgroundColor(accent(this.dark)).fontColor(this.dark?'#102A27':'#FFFFFF').enabled(!this.locked).onClick(()=>{this.onStart();})
        }.width('100%').padding({top:12}).border({width:{top:1},color:inset(this.dark)})
      }
    }.padding(18).width('100%').backgroundColor(surface(this.dark)).borderRadius(16)
  }
}
