// Presentation only: never infer a live battery or recording state after disconnect.
export function deviceConnection(link:string):string {
  if(link==='ready')return '已连接';
  if(link==='connecting')return '连接中';
  if(link==='transferring')return 'Wi-Fi 已连接';
  return '未连接';
}
export function deviceActivity(link:string,recording:number,active:boolean,phase:string,live:boolean):string {
  if(live)return '实时转写中';
  if(active){
    const labels:Record<string,string>={checking:'检查录音',connecting:'连接热点',downloading:'高速下载中',cached:'文件已缓存',restoring_network:'恢复网络',uploading:'上传云端中',resuming:'恢复上传',verifying:'云端校验中',retrying:'网络重试中',completed:'传输完成'};
    return labels[phase]||'传输中';
  }
  if(link==='connecting')return '正在连接';
  if(link!=='ready'&&link!=='transferring')return '等待连接';
  return recording===1?'正在录音':recording===0?'待机':'录音状态未知';
}
export function deviceBattery(link:string,value:number|null,charging:boolean|null):string {
  if(link!=='ready'&&link!=='transferring')return '—';
  const valid=value!==null&&Number.isFinite(value)&&value>=0&&value<=100;
  return (valid?'约 '+value+'%':'未知')+(charging===true?' · 充电中':'');
}
