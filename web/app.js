import {SHA256} from './sha256.js';
let processing = false;
const $=id=>document.getElementById(id);
const labels={asr:'语音转写',diarization:'说话人处理',summary:'会议总结',feishu:'飞书文档'};
const states={pending:'待处理',queued:'排队中',running:'处理中',blocked:'需要处理',failed:'失败',interrupted:'已中断',completed:'完成'};
const errors={NVIDIA_RIVA_CLIENT_NOT_INSTALLED:'上次执行时缺少 API 调用依赖；安装后可重试此阶段。',DIARIZATION_CAPABILITY_TEST_REQUIRED:'需要进一步测试说话人能力，尚未判定服务不可用。',AUTH_REQUIRED:'请登录后继续。',PREVIOUS_STAGE_INCOMPLETE:'请先完成上一阶段。',FFMPEG_REQUIRED_FOR_CONVERSION:'此格式需要 FFmpeg 转换，请先人工安装。',INVALID_ACCESS_TOKEN:'访问口令不正确。',INSUFFICIENT_STORAGE:'磁盘空间不足，文件未确认保存。'};
function notice(e){$('notice').textContent=e?(errors[e.message]||e.message):''}
async function api(path,options={}){const r=await fetch(path,{...options,headers:{...(options.body&&typeof options.body==='string'?{'Content-Type':'application/json'}:{}),...options.headers}});const data=await r.json();if(!r.ok)throw Error(data.error||`HTTP ${r.status}`);return data}
function node(tag,text,cls){const el=document.createElement(tag);if(text!==undefined)el.textContent=text;if(cls)el.className=cls;return el}
async function refresh(){try{const [data,caps]=await Promise.all([api('/api/recordings'),api('/api/capabilities')]);$('login-panel').hidden=true;$('workspace').hidden=false;render(data.recordings);const checks=[['NVIDIA NIM API',caps.nvidia.client_installed?'调用依赖已安装；能力以实测报告为准':'等待安装 API 调用依赖'],['NVIDIA 凭证',caps.nvidia.key_configured?'已配置；查看验证记录':'待配置'],['总结模型',caps.llm.configured?'已配置；查看验证记录':'待配置'],['个人飞书',caps.feishu.cli_configured?'已接入指定 CLI 用户；验收见验证记录':caps.feishu.user_token_configured?'令牌已配置，待身份核验':'待登录授权'],['音频格式转换',caps.ffmpeg_installed?'FFmpeg 已安装':'目前可直接测试 16 kHz 单声道 PCM WAV'],['手机同步','请在录音豆应用中连接设备；本页仅显示云端记录']];$('capabilities').replaceChildren(...checks.map(([a,b])=>{const d=node('div',undefined,'capability');d.append(node('strong',a),node('div',b,'muted'));return d}));}catch(e){if(e.message==='AUTH_REQUIRED'){$('login-panel').hidden=false;$('workspace').hidden=true;}else notice(e)}}
async function action(rid, name, body = {}) {
  notice();
  await api(`/api/recordings/${rid}/${name}`, {method: 'POST', body: JSON.stringify(body)});
  await refresh();
}
function controls(recording) {
  const box = node('div', undefined, 'recording-controls');
  const row = node('div', undefined, 'inline');
  const complete = recording.jobs.length > 0 && recording.jobs.every(j => j.status === 'completed');
  const active = recording.jobs.some(j => ['queued', 'running'].includes(j.status));
  for (const [name, title] of [['pipeline', '开始 / 继续全部处理'], ['pause', '暂停后续处理']]) {
    const button = node('button', title, name === 'pause' ? 'quiet' : '');
    if (complete && name === 'pipeline') button.textContent = '全部处理已完成';
    button.disabled = complete || !recording.stored || (name === 'pipeline' && active);
    button.onclick = async () => {button.disabled = true; try {await action(recording.id, name)} catch(e) {notice(e); button.disabled = false}};
    row.append(button);
  }
  box.append(row, node('p', complete ? '处理结果已保存。完成表示流程执行成功，识别和总结准确性仍需核对。' : recording.autoprocess ? '连续处理已启用。手机或浏览器关闭后，服务仍会继续；暂停会等待当前阶段结束。' : '连续处理未启用，可按阶段操作。', 'muted'));
  if (recording.stored && !recording.jobs.some(j => ['completed', 'queued', 'running'].includes(j.status))) {
    const detail = node('details'); detail.append(node('summary', '导入参考文字，单独测试总结和飞书'));
    detail.append(node('p', '导入文字会明确标注为参考文本，不计为 ASR 或说话人验收。仅适用于尚未处理的录音。', 'muted'));
    const form = node('form'), label = node('label', '参考文字'), area = node('textarea');
    area.id = 'reference-' + recording.id; label.htmlFor = area.id; area.rows = 5; area.maxLength = 200000; area.required = true;
    const submit = node('button', '保存参考文字'); form.append(label, area, submit);
    form.onsubmit = async e => {e.preventDefault();submit.disabled = true;try {await action(recording.id, 'reference', {source:'manual-reference-not-asr', text:area.value})} catch(err) {notice(err);submit.disabled=false}};
    detail.append(form); box.append(detail);
  }
  for (const part of recording.publications || []) {
    if (part.document_id) {
      const link = node('a', `打开${part.part === 0 ? '主文档' : '续文 ' + part.part} · ${part.status === 'verified' ? '已回读核验' : '待核验'}`);
      link.href = 'https://feishu.cn/docx/' + encodeURIComponent(part.document_id); link.target = '_blank'; link.rel = 'noopener noreferrer'; box.append(link);
    } else if (part.status === 'creating') {
      const detail = node('details'); detail.append(node('summary', '核对创建结果，避免重复文档'));
      detail.append(node('p', `在飞书查找标题：${part.title} [${recording.id.slice(0,8)}-${part.part}]。先暂停处理，再填写对应空文档的 ID。`, 'muted'));
      const form = node('form'), label = node('label', '已创建的文档 ID'), input = node('input');
      input.id = `reconcile-${recording.id}-${part.part}`; label.htmlFor = input.id; input.required = true;
      const submit = node('button', '核验并关联'); form.append(label, input, submit);
      form.onsubmit = async e => {e.preventDefault();submit.disabled=true;try{await action(recording.id, 'reconcile', {part:part.part, document_id:input.value.trim()})}catch(err){notice(err);submit.disabled=false}};
      detail.append(form);box.append(detail);
    }
  }
  return box;
}
function render(recordings){processing = recordings.some(r => r.jobs.some(j => ['running','queued'].includes(j.status))); $('empty').hidden=recordings.length>0;$('recordings').replaceChildren(...recordings.map(r=>{const article=node('article',undefined,'recording');article.id='recording-'+r.id;article.append(node('h3',r.title),node('p',`${new Date(r.created*1000).toLocaleString()} · ${(r.size/1048576).toFixed(1)} MB · ${r.stored?'服务器已保存':'上传未完成'}`,'muted'));if(r.stored){const audio=document.createElement('audio');audio.controls=true;audio.preload='none';audio.src=`/api/recordings/${r.id}/audio`;article.append(audio)}const stages=node('div',undefined,'stages');r.jobs.forEach(j=>{const div=node('div',undefined,'stage '+(j.status==='completed'?'done':j.error?'failed':''));div.append(node('span',`${labels[j.stage]} · ${states[j.status]||j.status}`));if(!['completed','running','queued'].includes(j.status)){const b=node('button',j.status==='pending'?'开始':'重试','quiet');b.setAttribute('aria-label',`${labels[j.stage]}：${b.textContent}`);const order=Object.keys(labels);const previous=order[order.indexOf(j.stage)-1];if(previous&&!r.jobs.some(x=>x.stage===previous&&x.status==='completed')){b.disabled=true;b.textContent='等待上一步'}b.onclick=async()=>{b.disabled=true;notice();try{await api(`/api/recordings/${r.id}/jobs/${j.stage}`,{method:'POST',body:'{}'});await refresh()}catch(e){notice(e);b.disabled=false}};div.append(b)}stages.append(div);if(j.error){const e=node('p',errors[j.error]||j.error,'muted');e.title=j.error;article.append(e)}});article.append(stages, controls(r));['asr','summary','feishu'].forEach(stage=>{if(r.jobs.some(j=>j.stage===stage&&j.status==='completed')){const d=node('details');d.append(node('summary',`查看${labels[stage]}结果`));d.addEventListener('toggle',async()=>{if(d.open&&d.children.length===1){try{const value=await api(`/api/recordings/${r.id}/result/${stage}`);d.append(node('pre',JSON.stringify(value,null,2)))}catch(e){notice(e)}}});article.append(d)}});return article}));const id=new URLSearchParams(location.search).get('recording');if(id&&document.getElementById('recording-'+id))document.getElementById('recording-'+id).scrollIntoView({block:'nearest'})}
$('login').onsubmit=async e=>{e.preventDefault();notice();try{await api('/api/login',{method:'POST',body:JSON.stringify({token:$('token').value})});$('token').value='';await refresh()}catch(err){notice(err)}};
$('logout').onclick=async()=>{try{await api('/api/logout',{method:'POST',body:'{}'});await refresh()}catch(e){notice(e)}};
$('refresh').onclick=()=>refresh();
$('upload').onsubmit=async e=>{e.preventDefault();notice();const file=$('audio-file').files[0];if(!file)return;const button=$('upload-button');button.disabled=true;$('audio-file').disabled=true;try{const hash=new SHA256();const step=4*1024*1024;for(let offset=0;offset<file.size;offset+=step){hash.update(new Uint8Array(await file.slice(offset,offset+step).arrayBuffer()));$('upload-status').textContent=`正在校验源文件 ${Math.min(100,Math.round((offset+step)/file.size*100))}%`;await new Promise(requestAnimationFrame)}const sha=hash.hex();const ext=file.name.split('.').pop().toLowerCase();const mime=({wav:'audio/wav',ogg:'audio/ogg',opus:'audio/ogg',mp3:'audio/mpeg',m4a:'audio/mp4',flac:'audio/flac'})[ext]||file.type;let session=await api('/api/uploads',{method:'POST',body:JSON.stringify({device_id:'manual-web',source_id:file.name+':'+file.lastModified,title:file.name,mime,size:file.size,sha256:sha})});const received=new Map(session.chunks.map(c=>[c.idx,c.sha256]));if(!session.stored){for(let offset=0,idx=0;offset<file.size;offset+=session.chunk_size,idx++){const bytes=new Uint8Array(await file.slice(offset,offset+session.chunk_size).arrayBuffer());const chunkHash=new SHA256().update(bytes).hex();if(received.get(idx)!==chunkHash)await api(`/api/uploads/${session.upload_id}/chunks/${idx}`,{method:'PUT',body:bytes,headers:{'X-Chunk-SHA256':chunkHash}});const pct=Math.round(Math.min(file.size,offset+session.chunk_size)/file.size*100);$('progress').value=pct;$('upload-status').textContent=`上传 ${pct}% · ${Math.min(file.size,offset+session.chunk_size).toLocaleString()} / ${file.size.toLocaleString()} 字节`}}$('upload-status').textContent='正在核验云端完整文件…';const receipt=await api(`/api/uploads/${session.upload_id}/complete`,{method:'POST',body:'{}'});if(!receipt.verified||receipt.sha256!==sha||receipt.size!==file.size)throw Error('云端校验回执不匹配，请保留原文件。');$('progress').value=100;$('upload-status').textContent='已保存并完成完整性校验。音频处理状态见下方。';await refresh()}catch(err){notice(err);$('upload-status').textContent='尚未确认上传完成。请保留文件，重新选择同一文件可续传。'}finally{button.disabled=false;$('audio-file').disabled=false}};
await refresh();

setInterval(() => {
  if (!processing || document.hidden || document.querySelector('details[open]') ||
      ['INPUT', 'TEXTAREA'].includes(document.activeElement?.tagName) ||
      [...document.querySelectorAll('audio')].some(a => !a.paused || a.currentTime > 0)) return;
  refresh();
}, 5000);
