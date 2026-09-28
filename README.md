# Open 飞书录音豆

**飞书录音豆的自托管录音同步、语音转写与 AI 会议纪要项目。** HarmonyOS、Android 和 iOS 原生 App 通过蓝牙控制设备、通过设备临时 Wi-Fi 传输录音；自己的 Python 服务保存音频，并按配置调用 ASR、LLM 和飞书 / Lark Docs。支持的具体设备型号与真机验证范围见[跨平台状态](docs/CROSS_PLATFORM.md)。

~~~text
飞书录音豆 → 手机 App → 自己的服务器 → ASR 转写 → LLM 总结 → 飞书文档
~~~

[English](README.en.md) · [5 分钟本机启动](#快速开始) · [普通用户指南](docs/USER_GUIDE.md) · [Agent 入口](AGENT_START.md) · [当前验收状态](docs/STATUS_AUDIT.md)

本项目面向**单人自托管**，不是公共 SaaS，也不是 soundcore、飞书或 NVIDIA 的官方产品。仓库目前是 Private；获得访问权限才能克隆。手机连接设备、供应商调用和飞书写入仍需分别在自己的环境验证。

## 我为什么做这个项目

我买飞书录音豆，是想随时把重要的谈话和想法录下来。但[官方 AI 转写与纪要有免费、赠送额度及付费会员](https://www.feishu.cn/content/article/7597268954498763996)；用量增加后，我不想为了继续处理自己录下的内容而长期购买官方 AI 会员。**这就是我开发 Open 飞书录音豆的直接原因：用自己的处理链路，不依赖官方付费 AI 套餐。**

我的方案把录音同步到自己的服务器，确认文件完整后，用自己选的 ASR 和 LLM 转写、总结，再写入自己的飞书文档。项目本身不收订阅费；如果已有服务器，并在所选接口的免费额度内使用，就可以不再为这条流程额外付费。第三方 API、云服务器和域名仍可能产生费用，**是否零额外费用取决于个人配置与用量**。这样即使官方额度或服务方案变化，我也能继续使用手里的录音设备。

## 能做什么

| 环节 | 当前实现 |
| --- | --- |
| 设备与手机 | 显示连接、电量和录音列表；连接后自动同步，支持一次加入设备热点批量高速传输、进度和速度显示。 |
| 自有云端 | 分片续传，按大小与 SHA-256 核验完整文件，受保护回听；核验成功后清理手机完整音频缓存，**保留录音豆原文件**。 |
| 转写与纪要 | 可配置 NVIDIA NIM 或兼容 ASR、兼容 Chat Completions 的 LLM；阶段状态和失败重试独立记录。 |
| 飞书 / Lark | 按指定身份创建、回读会议文档，包含录制信息、摘要、转写和待办；支持用户令牌、应用凭据或服务器 [lark-cli](https://github.com/larksuite/cli)。 |
| 实时与多端 | HarmonyOS、Android、iOS 的“录音 / 实时 / 设置”页面；实时切片可选 2 / 5 / 10 / 20 秒，默认 5 秒。 |

说话人信息取决于实际 ASR 响应；独立 Sortformer 尚未接入。实时窗口长度不等于端到端出字延迟。各平台已实现的路径与尚待真机验收的场景见[跨平台状态](docs/CROSS_PLATFORM.md)和[状态清单](docs/STATUS_AUDIT.md)。

## 快速开始

本机服务需要 Python 3.11+；实际音频处理和兼容回听需要 FFmpeg。基础上传、回听和测试使用 Python 标准库。

~~~bash
git clone https://github.com/Eliqi797/open-feishu-recording-bean.git
cd open-feishu-recording-bean
git config core.hooksPath .githooks
python3 -m venv .venv
cp .env.example .env
.venv/bin/python -m bean.server --data data --port 8765
~~~

打开 http://127.0.0.1:8765，使用首次启动时创建在 data/access-token 的访问口令登录。服务默认只监听本机；要让手机连接，需按[部署指南](docs/DEPLOYMENT.md)配置自己的 HTTPS 入口。手机上的 localhost 不是这台电脑。

需要调用托管 NVIDIA NIM 时，再在虚拟环境安装对应客户端依赖：

~~~bash
.venv/bin/python -m pip install -r requirements-nim.txt
~~~

NIM 通过远程 API 调用，不要求本机 GPU 或模型下载；仍需自己的 API 权限。ASR、LLM 和飞书的配置见[配置指南](docs/CONFIGURATION.md)。不配置这些供应商时，也可以先检查音频上传、完整性回执与受保护回听。

## 安装手机 App 与第一次同步

| 平台 | 从源码安装 | 设备热点 |
| --- | --- | --- |
| HarmonyOS | 按[鸿蒙工程说明](harmony/README.md)用 DevEco Studio 和自己的签名构建普通 App。 | 按系统提示授权蓝牙和 Wi-Fi。 |
| Android | 用 Android Studio、Android SDK 36 打开 android/ 并构建 Debug App。 | 同意系统 Wi-Fi 连接提示。 |
| iOS | 用 Xcode 打开 ios/RecordingBean.xcodeproj，选择自己的 Team；最低 iOS 17。 | 免费 Personal Team 需手动加入设备热点，再返回 App。 |

当前没有可直接分发的通用签名安装包。详细步骤见[普通用户指南](docs/USER_GUIDE.md)。

第一次请用一条**已结束的约 30 秒录音**：连接录音豆 → 确认列表与电量 → 自动同步或点“高速传输” → 核对云端文件大小和 SHA-256 回执 → 回听。若启用了 ASR、LLM 和飞书，再分别核对转写、总结和本人可见的文档。构建通过、健康检查通过或显示“已上传”，都不等于整条链路验收通过。

## 给 AI Agent

用 ChatGPT、Codex、Claude Code、Gemini、Cursor 等 Agent 理解、部署或修改项目时，先读 [AGENT_START.md](AGENT_START.md)。代码约束见 [AGENTS.md](AGENTS.md)，安全操作与 API 入口见 [Agent 指南](docs/AGENT_GUIDE.md)和 [llms.txt](llms.txt)。Agent 不应把测试、服务存活或单一处理阶段成功当作真实设备与飞书文档的完整验收。

## 继续阅读

| 目的 | 文档 |
| --- | --- |
| 安装、首次同步与排错 | [普通用户指南](docs/USER_GUIDE.md) |
| 数据流、代码位置与 HTTP 接口 | [架构](docs/ARCHITECTURE.md) · [API](docs/API.md) |
| 供应商和飞书接入方式 | [集成说明](docs/INTEGRATIONS.md) · [配置指南](docs/CONFIGURATION.md) |
| 典型问题与方案选择 | [使用场景](docs/USE_CASES.md) · [官方 App 与自托管方案](docs/ALTERNATIVES.md) |
| 平台差异、已验证与未验证范围 | [跨平台状态](docs/CROSS_PLATFORM.md) · [状态清单](docs/STATUS_AUDIT.md) |
| 部署、备份与仓库维护 | [部署指南](docs/DEPLOYMENT.md) · [仓库维护](docs/REPOSITORY.md) |
| 未来公开前的检查 | [可发现性与公开准备](docs/DISCOVERABILITY.md) |

录音、数据库、API Key、飞书授权、签名和私人服务器配置均不在 Git 中。重要会议请保留录音豆原件并人工核对转写与纪要；长时间锁屏、超长录音、重叠发言和独立备份恢复仍须在实际环境单独验收。仓库目前未选择开源许可证，也不会因名称调整自动公开。
