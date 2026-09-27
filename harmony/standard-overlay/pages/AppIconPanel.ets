import { appInfoManager } from '@kit.AppGalleryKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { surface, ink, muted, accent, line } from '../services/AppTheme';

// These IDs must match the reviewed icons configured in AppGallery Connect.
const BLACK_ICON_ID:string='recordingbean_black';
const WHITE_ICON_ID:string='recordingbean_white';

@Component
export struct AppIconPanel {
  @Prop dark:boolean=false;
  @State current:string='unknown';
  @State available:boolean=false;
  @State busy:boolean=false;
  @State message:string='';
  private async read():Promise<void>{
    const icons=await appInfoManager.queryDynamicIcons();
    this.available=icons.some((icon:appInfoManager.DynamicIconInfo)=>icon.iconId===BLACK_ICON_ID);
    const enabled=icons.find((icon:appInfoManager.DynamicIconInfo)=>icon.enabled);
    this.current=!enabled||enabled.iconId===WHITE_ICON_ID?'white':enabled.iconId===BLACK_ICON_ID?'black':'other';
  }
  private failure(error:BusinessError):void{
    if(error.code===1006800010){
      this.available=false;
      this.message='安装包默认图标为白色。应用正式上架并开通华为图标服务后，才能切换黑色桌面图标。';
    }else if(error.code===1006800013){
      this.message='当前系统主题接管了应用图标，请换回官方主题后重试。';
    }else{
      this.message='暂时无法确认桌面图标，请检查网络后重试（'+error.code+'）。';
    }
  }
  private async refresh():Promise<void>{
    if(this.busy)return;this.busy=true;this.message='正在读取桌面图标…';
    try{await this.read();this.message=this.available?'选择后更新桌面图标，与 App 深浅色设置独立。':'当前安装版使用白色图标。黑色图标需在华为图标服务审核通过后才能切换。';}
    catch(e){this.failure(e as BusinessError);}finally{this.busy=false;}
  }
  private async choose(color:string):Promise<void>{
    if(this.busy||color===this.current)return;
    this.busy=true;this.message='正在切换桌面图标…';
    try{
      if(color==='white'){
        await appInfoManager.disableDynamicIcon();
        this.current='white';this.message='系统已接受恢复白色图标，桌面可能需要片刻刷新。';
        return;
      }
      await appInfoManager.selectDynamicIcon(BLACK_ICON_ID);
      // Read back system state; a local preference is not evidence of a launcher change.
      await this.read();
      this.message=this.current===color?'已切换为'+(color==='black'?'黑色':'白色')+'图标。桌面可能需要片刻刷新。':'系统尚未确认切换，请稍后重新检查。';
    }catch(e){this.failure(e as BusinessError);}finally{this.busy=false;}
  }
  aboutToAppear():void{this.refresh();}
  @Builder option(color:string,title:string,icon:Resource){
    Column({space:12}){
      Image(icon).width(96).height(96).borderRadius(22).objectFit(ImageFit.Contain).accessibilityText(title+'录音豆图标，保留吊绳')
      Text(title).fontSize(16).fontWeight(FontWeight.Medium).fontColor(ink(this.dark))
      Button(this.current===color?'使用中':color==='black'&&!this.available?'暂不可用':'使用'+title,{type:ButtonType.Normal})
        .height(48).width('100%').borderRadius(12).fontSize(14)
        .backgroundColor(this.current===color?accent(this.dark):surface(this.dark))
        .fontColor(this.current===color?(this.dark?'#102A27':'#FFFFFF'):accent(this.dark))
        .enabled(!this.busy&&this.current!==color&&(color==='white'||this.available))
        .onClick(()=>{this.choose(color);})
    }.padding(16).layoutWeight(1).backgroundColor(surface(this.dark)).border({width:1,color:this.current===color?accent(this.dark):line(this.dark),radius:16})
  }
  build(){
    Column({space:18}){
      Text('保留录音豆和吊绳，选择你喜欢的颜色。').fontSize(14).fontColor(muted(this.dark)).width('100%')
      Row({space:12}){
        this.option('white','白色',$r('app.media.recordingbean_white'))
        this.option('black','黑色',$r('app.media.recordingbean_black'))
      }.width('100%')
      Text(this.message).fontSize(14).fontColor(muted(this.dark)).lineHeight(23).width('100%')
      Button(this.busy?'检查中…':'重新检查').height(48).fontColor(accent(this.dark)).backgroundColor(Color.Transparent).enabled(!this.busy).onClick(()=>{this.refresh();})
    }.width('100%').alignItems(HorizontalAlign.Start)
  }
}
