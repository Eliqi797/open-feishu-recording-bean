import { deviceConnection, deviceActivity, deviceBattery } from '../services/DevicePresentation';
import { surface, ink, muted, accent, line, attention } from '../services/AppTheme';
@Component
export struct DeviceStatusBar {
  @Prop dark:boolean=false;
  @Prop link:string='disconnected';
  @Prop battery:number|null=null;
  @Prop charging:boolean|null=null;
  @Prop caseBattery:number|null=null;
  @Prop caseCharging:boolean|null=null;
  @Prop recording:number=-1;
  @Prop transferActive:boolean=false;
  @Prop transferPhase:string='idle';
  @Prop live:boolean=false;
  onManage:()=>void=()=>{};
  build(){
    Column({space:2}){
      Row({space:8}){
        Image($r('app.media.tab_device')).width(22).height(22).fillColor(accent(this.dark))
        Text('录音豆').fontSize(15).fontWeight(FontWeight.Medium).fontColor(ink(this.dark)).layoutWeight(1).maxLines(1).textOverflow({overflow:TextOverflow.Ellipsis})
        Text(this.link==='ready'||this.link==='transferring'?deviceActivity(this.link,this.recording,this.transferActive,this.transferPhase,this.live):deviceConnection(this.link)).fontSize(12).fontColor(this.link==='disconnected'?muted(this.dark):accent(this.dark)).maxLines(1)
        Button(this.link==='disconnected'?'连接':'管理').height(48).width(60).fontSize(14).fontColor(accent(this.dark)).backgroundColor(Color.Transparent).onClick(()=>{this.onManage();})
      }.width('100%')
      Row({space:12}){
        Text('设备 '+deviceBattery(this.link,this.battery,this.charging)).fontSize(12).fontColor(this.link==='ready'&&this.battery!==null&&this.battery<=20?attention(this.dark):muted(this.dark)).layoutWeight(1)
        Text('充电盒 '+deviceBattery(this.link,this.caseBattery,this.caseCharging)).fontSize(12).fontColor(muted(this.dark)).layoutWeight(1)
      }.width('100%').padding({bottom:10})
    }.padding({left:20,right:14}).width('100%').backgroundColor(surface(this.dark)).border({width:{bottom:1},color:line(this.dark)})
  }
}
