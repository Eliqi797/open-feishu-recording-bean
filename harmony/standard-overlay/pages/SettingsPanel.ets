import { AppIconPanel } from './AppIconPanel';
import { NativeCloud, ProviderSettings } from '../services/NativePorts';
import { surface, ink, muted, accent, line, inset } from '../services/AppTheme';
@Component
export struct SettingsPanel {
  @Prop dark:boolean=false;
  @Prop origin:string='';
  @Prop token:string='';
  @Prop theme:string='system';
  @Prop wifi:boolean=true;
  @Prop locked:boolean=false;
  @Prop autoUpload:boolean=true;
  onAutoUpload:(enabled:boolean)=>void=()=>{};
  @Prop liveWindowSeconds:number=5;
  onLiveWindow:(seconds:number)=>void=()=>{};
  @Prop keepAwake:boolean=false;
  onKeepAwake:(enabled:boolean)=>void=()=>{};
  onConnection:(origin:string,token:string)=>void=()=>{};
  onTheme:(theme:string)=>void=()=>{};
  onWifi:(wifi:boolean)=>void=()=>{};
  @State draftOrigin:string='';
  @State draftToken:string='';
  @State section:string='';
  @State message:string='';
  @State loading:boolean=false;
  @State loaded:boolean=false;
  @State values:Record<string,string>={};
  @State secrets:Record<string,boolean>={};
  @State clear:string[]=[];
  private revision:number=0;
  aboutToAppear():void{this.draftOrigin=this.origin;this.draftToken=this.token;}
  private apply(data:ProviderSettings):void{this.values=data.values;this.secrets=data.secrets_configured;this.revision=data.revision;this.clear=[];this.loaded=true;}
  private async load():Promise<void>{
    if(this.loading)return;this.loading=true;
    try{this.apply(await new NativeCloud(this.origin,this.token).settings());this.message='已读取服务设置，密钥不会显示。';}
    catch(_){this.message='无法读取设置。请先保存并验证服务连接；服务端需支持配置接口。';}
    finally{this.loading=false;}
  }
  private async save():Promise<void>{
    if(this.loading||this.locked||!this.loaded)return;this.loading=true;
    try{this.apply(await new NativeCloud(this.origin,this.token).saveSettings(this.revision,this.values,this.clear));this.message='设置已保存，下一个处理任务使用新配置。';}
    catch(e){this.message=(e as Error).message==='CLOUD_HTTP_409'?'设置已在别处更新，请重新读取后修改。':'保存失败，请检查地址、参数和服务连接；原设置仍保留。';}
    finally{this.loading=false;}
  }
  private set(key:string,value:string):void{const next:Record<string,string>={};Object.keys(this.values).forEach((k:string)=>{next[k]=this.values[k];});next[key]=value;this.values=next;}
  @Builder field(label:string,key:string,hint:string,secret:boolean=false){
    Column({space:6}){
      Text(label).fontSize(14).fontWeight(FontWeight.Medium).fontColor(ink(this.dark)).width('100%')
      TextInput({text:this.values[key]||'',placeholder:secret?(this.clear.includes(key)?'保存后清除':(this.secrets[key]?'已配置 · 留空保留':hint)):hint}).placeholderColor(muted(this.dark)).type(secret?InputType.Password:InputType.Normal).height(48).fontSize(15).fontColor(ink(this.dark)).backgroundColor(surface(this.dark)).border({width:1,color:line(this.dark)}).borderRadius(10).enabled(!this.loading&&!this.locked).onChange((v:string)=>{this.set(key,v);if(secret&&v)this.clear=this.clear.filter((k:string)=>k!==key);})
      if(secret&&this.secrets[key]){Button(this.clear.includes(key)?'撤销清除':'清除已保存密钥').height(48).fontSize(12).fontColor(accent(this.dark)).backgroundColor(Color.Transparent).onClick(()=>{this.clear=this.clear.includes(key)?this.clear.filter((k:string)=>k!==key):this.clear.concat([key]);this.set(key,'');})}
    }.width('100%').alignItems(HorizontalAlign.Start)
  }
  @Builder row(title:string,subtitle:string,key:string){
    Row(){Column({space:5}){Text(title).fontSize(17).fontWeight(FontWeight.Medium).fontColor(ink(this.dark));Text(subtitle).fontSize(13).fontColor(muted(this.dark))}.alignItems(HorizontalAlign.Start).layoutWeight(1);Image($r('app.media.chevron_right')).width(18).height(18).fillColor(muted(this.dark))}.padding({left:18,right:18,top:14,bottom:14}).width('100%').constraintSize({minHeight:76}).onClick(()=>{this.section=key;if(['asr','llm','feishu','advanced'].includes(key)&&!this.loaded)this.load();})
  }
  build(){
    Scroll(){Column({space:16}){
      if(this.section){Button('返回设置').height(48).fontSize(16).fontColor(accent(this.dark)).backgroundColor(Color.Transparent).onClick(()=>{this.section='';this.message='';})}
      Text(this.section==='icons'?'应用图标':this.section==='connection'?'服务连接':this.section==='asr'?'语音转写':this.section==='llm'?'智能总结':this.section==='feishu'?'飞书文档':this.section==='advanced'?'处理与传输':'设置').fontSize(30).fontWeight(FontWeight.Bold).fontColor(ink(this.dark)).width('100%')
      if(!this.section){
        Text('管理服务、外观和同步偏好').fontSize(14).fontColor(muted(this.dark)).width('100%')
        Column(){this.row('服务连接',this.origin?'已设置私有服务':'连接你部署的录音豆服务','connection')}.width('100%').backgroundColor(surface(this.dark)).borderRadius(16)
        Column({space:12}){Text('外观').fontSize(17).fontWeight(FontWeight.Medium).fontColor(ink(this.dark)).width('100%');Row({space:8}){ForEach(['system','light','dark'],(mode:string)=>{Button(mode==='system'?'跟随系统':mode==='light'?'浅色':'深色',{type:ButtonType.Normal}).borderRadius(10).layoutWeight(1).height(48).fontSize(14).fontColor(this.theme===mode?(this.dark?'#102A27':'#FFFFFF'):ink(this.dark)).backgroundColor(this.theme===mode?accent(this.dark):surface(this.dark)).border({width:1,color:line(this.dark),radius:10}).onClick(()=>{this.onTheme(mode);})})}}.padding(18).backgroundColor(surface(this.dark)).borderRadius(16)
        Column(){this.row('应用图标','白色与黑色录音豆','icons')}.width('100%').backgroundColor(surface(this.dark)).borderRadius(16)
        Text('服务与处理').fontSize(14).fontWeight(FontWeight.Medium).fontColor(muted(this.dark)).width('100%').margin({top:8})
        Column(){
          this.row('语音转写','ASR 服务、语言与模型','asr')
          Divider().color(line(this.dark)).margin({left:18,right:18})
          this.row('智能总结','LLM 接口与模型','llm')
          Divider().color(line(this.dark)).margin({left:18,right:18})
          this.row('飞书文档','应用凭据、身份与保存位置','feishu')
          Divider().color(line(this.dark)).margin({left:18,right:18})
          this.row('处理与传输','自动上传、屏幕常亮与高级参数','advanced')
        }.width('100%').backgroundColor(surface(this.dark)).borderRadius(16).clip(true)
        Text('每个部署拥有独立配置。服务密钥保存在你的服务器，手机访问口令保存在系统安全存储。').fontSize(13).fontColor(muted(this.dark)).lineHeight(21).width('100%')
      }else if(this.section==='icons'){
        AppIconPanel({dark:this.dark})
      }else if(this.section==='connection'){
        Text('填写自己的 HTTPS 服务地址与访问口令。').fontSize(15).fontColor(muted(this.dark)).width('100%')
        TextInput({text:this.draftOrigin,placeholder:'https://recorder.example.com'}).height(52).fontColor(ink(this.dark)).backgroundColor(surface(this.dark)).enabled(!this.locked).onChange((v:string)=>{this.draftOrigin=v;})
        TextInput({text:this.draftToken,placeholder:'服务访问口令'}).height(52).type(InputType.Password).fontColor(ink(this.dark)).backgroundColor(surface(this.dark)).enabled(!this.locked).onChange((v:string)=>{this.draftToken=v;})
        Button('验证并保存连接').type(ButtonType.Normal).borderRadius(12).height(50).width('100%').backgroundColor(accent(this.dark)).fontColor(this.dark?'#102A27':'#FFFFFF').enabled(!this.locked).onClick(()=>{this.loaded=false;this.onConnection(this.draftOrigin.trim(),this.draftToken.trim());})
      }else{
        if(!this.loaded){Button(this.loading?'读取中…':'读取服务配置').enabled(!this.loading).onClick(()=>{this.load();})}
        else{
          if(this.section==='asr'){
            Text('ASR 服务').fontColor(ink(this.dark)).width('100%')
            Select([{value:'NVIDIA · Parakeet 中文'},{value:'NVIDIA · Whisper'},{value:'OpenAI 兼容接口'}]).selected(['nvidia_parakeet','nvidia_whisper','openai_compatible'].indexOf(this.values['ASR_PROVIDER'])).value(this.values['ASR_PROVIDER']==='nvidia_whisper'?'NVIDIA · Whisper':this.values['ASR_PROVIDER']==='openai_compatible'?'OpenAI 兼容接口':'NVIDIA · Parakeet 中文').onSelect((i:number)=>{this.set('ASR_PROVIDER',['nvidia_parakeet','nvidia_whisper','openai_compatible'][i]);}).width('100%')
            if(this.values['ASR_PROVIDER']==='openai_compatible'){
              this.field('接口地址','ASR_BASE_URL','https://api.example.com/v1')
              this.field('模型','ASR_MODEL','whisper-1')
              Select([{value:'含时间戳 verbose_json'},{value:'纯文本 JSON'}]).selected(this.values['ASR_RESPONSE_FORMAT']==='json'?1:0).value(this.values['ASR_RESPONSE_FORMAT']==='json'?'纯文本 JSON':'含时间戳 verbose_json').onSelect((i:number)=>{this.set('ASR_RESPONSE_FORMAT',i===1?'json':'verbose_json');})
              this.field('API Key','ASR_API_KEY','填写服务密钥',true)
            }else{this.field('NVIDIA API Key','NVIDIA_API_KEY','nvapi-…',true);Text('使用托管 API，无需在手机安装 NVIDIA 客户端。说话人信息以接口实际返回为准。').fontSize(13).fontColor(muted(this.dark)).width('100%')}
            Text('实时切片时长（下次接收生效）').fontSize(14).fontColor(ink(this.dark)).width('100%')
            Select([{value:'2 秒 · 更快'},{value:'5 秒 · 推荐'},{value:'10 秒'},{value:'20 秒'}]).selected([2,5,10,20].indexOf(this.liveWindowSeconds)).value(this.liveWindowSeconds+' 秒').enabled(!this.locked).onSelect((i:number)=>{this.onLiveWindow([2,5,10,20][i]);})
            Text('选择后自动保存到本机。切片越短，句子越容易被拆开；实际出字还需网络与识别时间。').fontSize(13).fontColor(muted(this.dark)).width('100%')
            this.field('语言','ASR_LANGUAGE','zh-CN')
            this.field('热词（逗号分隔）','ASR_HOTWORDS','仅支持该参数的 NVIDIA 接口使用')
          }else if(this.section==='llm'){
            Select([{value:'自定义兼容服务'},{value:'OpenAI'},{value:'NVIDIA NIM'}]).selected(this.values['LLM_BASE_URL']==='https://api.openai.com/v1'?1:this.values['LLM_BASE_URL']==='https://integrate.api.nvidia.com/v1'?2:0).value(this.values['LLM_BASE_URL']==='https://api.openai.com/v1'?'OpenAI':this.values['LLM_BASE_URL']==='https://integrate.api.nvidia.com/v1'?'NVIDIA NIM':'自定义兼容服务').onSelect((i:number)=>{if(i>0)this.set('LLM_BASE_URL',i===1?'https://api.openai.com/v1':'https://integrate.api.nvidia.com/v1');})
            Text('兼容 OpenAI Chat Completions 的服务；更换接口地址需重新填写对应密钥。').fontSize(14).fontColor(muted(this.dark)).width('100%')
            this.field('接口地址','LLM_BASE_URL','https://api.example.com/v1')
            this.field('模型名称','LLM_MODEL','输入供应商的模型 ID')
            this.field('API Key','LLM_API_KEY','填写服务密钥',true)
          }else if(this.section==='feishu'){
            Select([{value:'应用凭据'},{value:'用户访问令牌'},{value:'服务器飞书 CLI'}]).selected(['app','user_token','lark_cli'].indexOf(this.values['FEISHU_AUTH_MODE'])).value(this.values['FEISHU_AUTH_MODE']==='app'?'应用凭据':this.values['FEISHU_AUTH_MODE']==='lark_cli'?'服务器飞书 CLI':'用户访问令牌').onSelect((i:number)=>{this.set('FEISHU_AUTH_MODE',['app','user_token','lark_cli'][i]);this.set('FEISHU_PERSONAL_CONFIRMED','0');}).width('100%')
            if(this.values['FEISHU_AUTH_MODE']==='app'){
              this.field('App ID','FEISHU_APP_ID','cli_…')
              this.field('App Secret','FEISHU_APP_SECRET','应用密钥',true)
              Text('以应用身份创建文档。请在飞书开放平台授予文档权限，并将目标文件夹共享给应用。').fontSize(13).fontColor(muted(this.dark)).width('100%')
            }else if(this.values['FEISHU_AUTH_MODE']==='user_token'){
              this.field('用户访问令牌','FEISHU_USER_ACCESS_TOKEN','user_access_token',true)
              this.field('预期用户 Open ID','FEISHU_EXPECTED_OPEN_ID','ou_…')
              Text('令牌过期后需更新；写入前校验用户身份。').fontSize(13).fontColor(muted(this.dark)).width('100%')
            }else{
              this.field('CLI 配置名称','FEISHU_CLI_PROFILE','留空使用服务器默认配置')
              this.field('预期用户 Open ID','FEISHU_EXPECTED_OPEN_ID','ou_…')
            }
            this.field('目标文件夹 Token','FEISHU_FOLDER_TOKEN','可选；需对所选身份授予权限')
            this.field('文档域名','FEISHU_DOCS_ORIGIN','https://你的组织.feishu.cn')
            Row({space:12}){Toggle({type:ToggleType.Switch,isOn:this.values['FEISHU_PERSONAL_CONFIRMED']==='1'}).selectedColor(accent(this.dark)).onChange((v:boolean)=>{this.set('FEISHU_PERSONAL_CONFIRMED',v?'1':'0');});Text('我已确认写入身份与保存空间').fontSize(14).fontColor(ink(this.dark)).layoutWeight(1)}
          }else if(this.section==='advanced'){
            Row({space:12}){Toggle({type:ToggleType.Switch,isOn:this.autoUpload}).selectedColor(accent(this.dark)).enabled(!this.locked).onChange((v:boolean)=>{this.onAutoUpload(v);});Text('连接录音豆后自动上传').fontSize(14).fontColor(ink(this.dark)).layoutWeight(1)}
            Row({space:12}){Toggle({type:ToggleType.Switch,isOn:this.keepAwake}).selectedColor(accent(this.dark)).onChange((v:boolean)=>{this.onKeepAwake(v);});Text('App 前台时保持屏幕常亮').fontSize(14).fontColor(ink(this.dark)).layoutWeight(1)}
            Row({space:12}){Toggle({type:ToggleType.Switch,isOn:this.wifi}).selectedColor(accent(this.dark)).enabled(!this.locked).onChange((v:boolean)=>{this.onWifi(v);});Text('优先高速 Wi-Fi 传输').fontColor(ink(this.dark)).layoutWeight(1)}
            Row({space:12}){Toggle({type:ToggleType.Switch,isOn:this.values['AUTO_PIPELINE']==='1'}).selectedColor(accent(this.dark)).onChange((v:boolean)=>{this.set('AUTO_PIPELINE',v?'1':'0');});Text('上传后自动转写、总结并写入飞书').fontSize(14).fontColor(ink(this.dark)).layoutWeight(1)}
            this.field('文档时区','DOCUMENT_TIMEZONE','Asia/Shanghai')
            this.field('转写分段时长（10–300 秒）','ASR_CHUNK_SECONDS','120')
            this.field('最大说话人数（1–8）','NVIDIA_MAX_SPEAKERS','8')
            this.field('NVIDIA 超时（10–3600 秒）','NVIDIA_TIMEOUT_SECONDS','1800')
            Select([{value:'说话人未知（保守）'},{value:'接受零起始编号'}]).selected(this.values['NVIDIA_SPEAKER_ZERO_POLICY']==='zero_based'?1:0).value(this.values['NVIDIA_SPEAKER_ZERO_POLICY']==='zero_based'?'接受零起始编号':'说话人未知（保守）').onSelect((i:number)=>{this.set('NVIDIA_SPEAKER_ZERO_POLICY',i===1?'zero_based':'unknown');})
            Text('Whisper 分段最长 60 秒。独立 Sortformer 尚未接入；不会生成虚构说话人。').fontSize(13).fontColor(muted(this.dark)).width('100%')
          }
          Button(this.loading?'保存中…':'保存服务设置').type(ButtonType.Normal).borderRadius(12).height(50).width('100%').backgroundColor(accent(this.dark)).fontColor(this.dark?'#102A27':'#FFFFFF').enabled(!this.loading&&!this.locked).onClick(()=>{this.save();})
          Button('重新读取').height(48).fontColor(accent(this.dark)).backgroundColor(Color.Transparent).enabled(!this.loading).onClick(()=>{this.load();})
        }
      }
      if(this.locked){Text('正在同步或接收录音，结束后可修改连接与服务设置。').fontSize(13).fontColor(muted(this.dark)).width('100%')}
      if(this.message){Text(this.message).fontSize(14).fontColor(muted(this.dark)).width('100%')}
    }.padding(20).width('100%').alignItems(HorizontalAlign.Start)}.align(Alignment.TopStart).width('100%').height('100%')
  }
}
