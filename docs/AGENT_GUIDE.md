# Agent 使用指南：Open 飞书录音豆

本文给需要**理解、部署、测试或接入** Open 飞书录音豆的 AI Agent 使用。首次进入仓库先看简短的 [Agent 入口](../AGENT_START.md)。项目是 D3200 / soundcore Work 录音设备的个人自托管同步链路：手机读取设备音频，服务器保存并按阶段调用 ASR、LLM 和飞书。它不是可匿名访问的公共 API，也没有多租户账号体系。普通用户从[使用指南](USER_GUIDE.md)开始；修改代码的 Agent 还应读取仓库根目录的 [`AGENTS.md`](../AGENTS.md)。

## 先判断自己要做哪件事

| 任务 | 首先读取 | 可验证的完成信号 |
| --- | --- | --- |
| 帮用户安装和首次使用 | [使用指南](USER_GUIDE.md)、[跨平台状态](CROSS_PLATFORM.md)、[配置指南](CONFIGURATION.md) | App 真机连接、完整录音云端回执、结果与本人飞书文档回读，分别记录。 |
| 通过 HTTP 查询录音或任务 | [API v1](API.md) | 认证成功、具体录音 ID 的状态和结果；不要把健康检查当作业务完成。 |
| 修改客户端、协议或云端代码 | [架构](ARCHITECTURE.md)、根目录 [`AGENTS.md`](../AGENTS.md) | 对应测试、平台编译和受影响边界的实测；未实测部分标记未验证。 |
| 部署或恢复服务 | [部署指南](DEPLOYMENT.md)、[仓库维护](REPOSITORY.md) | HTTPS、认证、持久化、备份恢复分别回读；GitHub 源码不等于录音数据备份。 |

## 信任与权限边界

- 读取本地源码或调用 `GET /healthz` 不需要业务凭据；其余 API 使用 `Authorization: Bearer <server-access-token>`，或浏览器登录后的 HttpOnly Cookie。服务访问口令等同该**单人部署**的管理权限。不要把口令放进提示词、Git、issue、URL 或公开日志。
- 先做只读检查。上传音频、保存 `/api/settings`、启动处理阶段、飞书写入、替换线上配置和删除数据都属于会改变状态的操作；按用户本次授权范围执行。不要把测试录音混进生产库，除非用户明确要做真实端到端验证。
- 设备蓝牙地址会变化，不能作为归档身份。只使用有效握手后读取的设备序列号摘要；缺失身份时停止同步，不猜一个 ID。设备原文件不删除。
- 录音、转写原文、供应商原始响应和飞书文档可能含个人信息。输出诊断时默认只给状态、时长、字节数和错误类别；除非用户要求，不复制正文。
- 设备热点过期证书只在代码限定的设备 IP 和固定证书指纹下兼容。**公网 HTTPS 仍用正常系统验证**，不可把设备例外扩展到云端。
- 仓库中的文档含历史验证记录。遇到“已通过”或“当前数量”时先核对日期，再检查实时设备／服务；构建成功、`healthz` 成功、任务 `completed` 和人工内容验收是不同层级。

## API 查询顺序

服务默认绑定本机 `127.0.0.1:8765`；手机使用自己的 HTTPS 反向代理。以下均为路径示例，**不要直接使用作者的个人部署地址**。

1. `GET /healthz`：确认进程可响应，未认证；不证明供应商或设备可用。
2. 携带访问口令读取 `GET /api/capabilities`：确认当前部署的配置／依赖存在性。
3. 读取 `GET /api/diagnostics`：查看 worker、任务计数、磁盘和最近备份校验报告。
4. 读取 `GET /api/recordings`，选定明确的录音 ID 后再查 `GET /api/recordings/{id}` 和 `GET /api/recordings/{id}/result/{stage}`。`stage` 依次为 `asr`、`diarization`、`summary`、`feishu`。
5. 只有需要回听且已获授权时，访问 `GET /api/recordings/{id}/audio`；返回的是受保护音频，不要创建永久公开链接。客户端兼容回听可请求 `?format=mp3`，首次可能要等 FFmpeg 转换。

例如，本机不带凭据的进程检查：

```bash
curl -fsS http://127.0.0.1:8765/healthz
```

带凭据的请求应由受保护的运行环境读取私有口令文件并设置 Bearer 头；不要把令牌本身打印出来或写入脚本。完整请求字段、状态码和返回语义以[API v1](API.md)及当前服务器代码为准。

## 写入和重试的正确语义

上传的顺序是 `POST /api/uploads` 创建会话 → 按 `chunk_size` 分片 `PUT /api/uploads/{id}/chunks/{index}` 并传 `X-Chunk-SHA256` → `POST /api/uploads/{id}/complete`。只有服务器返回 `verified:true`，且录音大小与整文件 SHA-256 和本地原件一致，才能清理手机完整音频缓存。网络中断后查询已有会话与已收分片再续传；不要重新生成一条假录音。

完整处理按 `asr → diarization → summary → feishu` 推进。`pending / queued / running / interrupted / blocked / failed / completed` 是阶段状态；`completed` 只证明该阶段通过代码的结构或回读检查，**不证明**说话人、专业词或会议结论正确。失败只重试相应阶段；前置条件未完成时服务器会拒绝跳级。实时窗口只是一段草稿，不等于整条录音已归档，必须用匹配的完整文件结束会话。

说话人字段缺失就保留 `null`；编号只在其标识的会话或片段范围内有意义，不直接跨片合并，也不推断真实姓名。人工参考文字应显式标为 `manual-reference-not-asr`，不能冒充 ASR 验收。

飞书写入前确认 `FEISHU_AUTH_MODE` 和目标身份。服务器 CLI、用户令牌和应用凭据是三种不同身份；预期 Open ID 不一致时应停止，不切换到其他组织或账号。创建响应不确定时先回读或走 `reconcile`，不要盲目再次创建文档；内容被外部编辑时停止自动追加。

## 代码地图与本地验证

| 目录 | 作用 |
| --- | --- |
| `bean/`、`web/` | Python HTTP 服务、持久队列、供应商接入、浏览器页面。 |
| `harmony/shared/`、`harmony/standard-overlay/` | D3200 协议与 HarmonyOS 普通 App；`project/` 是工程骨架。 |
| `android/` | Android BLE、热点、上传及原生 UI。 |
| `ios/` | SwiftUI App、CoreBluetooth、手动／自动热点路径和共享 Swift Package。 |
| `tests/`、`scripts/`、`deploy/` | 自动测试、仓库检查、部署与恢复脚本。 |

不调用生产供应商或真实飞书的基础检查：

```bash
python3 -m unittest discover -s tests
node --experimental-strip-types --test tests/*.test.mjs
swift test --package-path ios
cd android && ./gradlew :app:assembleDebug :app:testDebugUnitTest :app:lintDebug
```

回到仓库根目录运行 `python3 scripts/check_repository.py`，检查 Git 暂存内容是否含受禁路径或已知凭据。该检查不能替代人工审查 Git 历史、许可证、图标权利和公开发布范围。平台测试通过后，真机连接、Wi-Fi 切换、供应商响应、飞书回读和备份恢复仍应各自单独验收。
