# 录音豆 API v1

每个部署使用自己的 HTTPS 地址，例如 `https://recorder.example.com`。服务进程默认仅监听 `127.0.0.1:8765`，由 Nginx 或 Caddy 终结 HTTPS；不要把示例域名当作可用的公共 API。

除首页、静态资源、`GET /healthz` 和 `POST /api/login` 外均需认证：原生／CLI 使用 `Authorization: Bearer <data/access-token>`，浏览器登录后使用 HttpOnly Cookie。POST／PUT 的 Cookie 请求必须来自匹配 Origin；无跨域开放。

| 方法与路径 | 请求／行为 | 响应 |
|---|---|---|
| POST `/api/login` | `{token}` | 会话 Cookie，12 小时有效；服务重启后重新登录 |
| POST `/api/logout` | 空 JSON | 注销当前浏览器会话 |
| GET `/api/capabilities` | 查询配置／依赖存在性 | 不代表 live 验收状态 |
| POST `/api/uploads` | `{device_id, source_id, title, size, sha256, mime}` | 上传会话，包含已收分片 |
| GET `/api/uploads/{id}` | 恢复上传 | `{upload_id, recording_id, size, sha256, chunk_size, stored, chunks}` |
| PUT `/api/uploads/{id}/chunks/{index}` | 二进制块；`X-Chunk-SHA256` 必填 | 更新后的会话 |
| POST `/api/uploads/{id}/complete` | 完成合并并核验 | 会话 + `verified:true`；与源文件大小／哈希匹配后才允许清理缓存 |
| GET `/api/recordings` | 最近 500 条记录 | `{recordings:[...]}` |
| GET `/api/recordings/{id}` | 单条详情 | 元数据、任务及飞书发布记录 |
| GET `/api/recordings/{id}/audio` | 支持单段 HTTP Range／suffix range | 认证后的音频流 |
| GET `/api/recordings/{id}/audio?format=mp3` | 首次按需转换，后续读取 1 GiB 上限的可清理缓存；支持 HTTP Range | 认证后的兼容 MP3，原始归档不变；需服务器 FFmpeg |
| POST `/api/recordings/{id}/jobs/{stage}` | 开始／重试阶段 | 更新后的记录；前置阶段未完成返回 409 |
| GET `/api/recordings/{id}/result/{stage}` | 读取保存结果 | JSON 或 null |

stage：`asr → diarization → summary → feishu`。

上传单文件上限当前 4 GiB，分片 4 MiB；这是本工程的限制，不是 NVIDIA 服务限制。相同 `device_id + source_id + sha256` 返回原会话；相同文件 ID 内容改变产生新记录。上传前预留分片及合并空间，每块和整文件分别校验。客户端不能信任 HTTP 成功状态代替回执核对。

任务状态：`pending / queued / running / interrupted / blocked / failed / completed`。`queued` 可以包含 `retry_at`，表示限流退避中；`completed` 仅代表对应阶段输出通过其结构／回读检查，不代表人工识别准确率验收。设备缺失、依赖缺失或权限未配置为 blocked，不能以空文本假装成功。

统一转写结构：`schema_version, source, text, segments[]`；每段含 `id,text,start_ms,end_ms,words[]`。词级时间戳用毫秒；`speaker_id` 带本次会话前缀，缺失字段为 null。原始 NVIDIA 响应保存在私有结果文件，整理文本不覆盖它。

飞书创建前先持久化 creating 状态；拿到 document_id 后立即保存。响应丢失又没有已知 ID 时停在待核对状态。内容写入后必须回读匹配，未知写入结果先回读再决定，不能直接重复追加。

## 连续处理和恢复入口

| 方法与路径 | 请求／行为 |
|---|---|
| POST `/api/recordings/{id}/pipeline` | `{}`；从第一个未完成阶段继续，后续自动排队 |
| POST `/api/recordings/{id}/pause` | `{}`；停止后续排队，当前运行阶段允许结束 |
| POST `/api/recordings/{id}/reference` | `{source:"manual-reference-not-asr",text:"…"}`；仅未处理录音可导入；显式记为参考文字，不计 ASR 验收 |
| POST `/api/recordings/{id}/reconcile` | `{part:0,document_id:"…"}`；创建响应不确定时关联同标题的空文档，先暂停任务；不会覆盖非空文档 |
| GET `/api/diagnostics` | 任务计数、worker 状态、磁盘和最近备份校验报告；需认证 |

`autoprocess=1` 的 interrupted 任务在重启时续排。分片识别和分段总结以输入哈希和配置为检查点键，配置或输入变更会重新计算。NIM 缺失说话人仍保持 blocked，导入参考文字不会伪造此能力。

飞书正文写入超时后，重试会回读。已完整写入则不再追加；只存在精确前缀则仅补齐后缀；内容遭外部编辑时停止并要求人工核对。创建响应不确定则需上述 reconcile 入口。

## 实时草稿

所有接口均需相同认证，窗口不能直接作为整条原件完成归档。

| 方法与路径 | 行为 |
|---|---|
| POST `/api/live` | `{device_id,source_id,original_source_id,title,start_ms}`；source_id 是本次采集标识，original_source_id 是设备录音 ID；同一标识元数据不可改变 |
| GET `/api/live/{id}` | 草稿文字、绝对时间偏移、逐窗口状态与 received_ms |
| PUT `/api/live/{id}/segments/{index}` | Ogg，最多 1 MiB；`X-Chunk-SHA256`、`X-Audio-Duration-Ms`；按序去重，窗口最多 20 秒 |
| POST `/api/live/{id}/segments/{index}/retry` | 只重试失败窗口 |
| POST `/api/live/{id}/finish` | `{device_end_observed:true,recording_id,segment_count}`；匹配已保存完整原件后启动最终流程 |

窗口状态为 queued/running/completed/no_speech/failed；静音不编造文字，说话人编号不跨窗口合并。收到音频窗口不等于整条录音已保存。
