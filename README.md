# 录音豆 · RecordingBean

[英文文档](README.en.md)

RecordingBean（录音豆）是 D3200 / soundcore Work 录音设备的自托管同步与 AI 会议纪要项目。HarmonyOS、Android 和 iOS 客户端通过蓝牙连接设备、使用临时 Wi-Fi 高速导出录音，上传到自己的服务器；服务器再调用 NVIDIA NIM 或兼容 ASR、LLM 和飞书 / Lark Docs 接口完成转写、总结与文档归档。

**适用范围：单人、单服务、自行部署；不是公共 SaaS。** 当前源码仓库为 Private；未来是否公开另行决定，公开前的检查见[可发现性与公开准备](docs/DISCOVERABILITY.md)。仓库可见性变化不影响服务运行；密钥、签名和录音数据始终另行保管。

第一次使用请看[普通用户指南](docs/USER_GUIDE.md)；需要 Agent 协助部署、查询或开发时看[Agent 使用指南](docs/AGENT_GUIDE.md)和根目录 [`AGENTS.md`](AGENTS.md)。

## 当前能做什么

- HarmonyOS 普通 App，以及 Android / iOS 客户端：**录音、实时、设置**三个标签；全局设备连接状态、电量；深浅色与跟随系统。跨平台实测范围与未验收场景见[跨平台客户端](docs/CROSS_PLATFORM.md)。
- 连接后自动同步；高速传输一次连接 Wi-Fi，批量下载后恢复互联网并上传。显示文件进度、传输大小及速度。
- 云端分片续传、完整性核验、受保护回听；确认云端保存后清理手机完整文件缓存，**不删除录音豆原文件**。
- 使用设备序列号摘要作为归档身份，避免蓝牙地址变化产生新的重复归档。
- 实时页面按 **5 秒默认窗口**上传，设置可选 2 / 5 / 10 / 20 秒；窗口时长不是端到端出字延迟。
- ASR、LLM、飞书凭据及传输设置可配置。飞书文档含录制信息、摘要、原文和原生待办勾选项。
- 黑白透明设备图标均保留吊绳；白色是默认桌面图标。iOS 已真机验证黑白切换；鸿蒙的动态切换受华为图标服务开通与审核限制。

源码与部分真机路径已经验证，但公开仓库不包含个人服务日志或录音。**长时间锁屏、长录音、多人和重叠发言准确率、独立备份恢复仍需在使用者环境验收，独立 Sortformer 未接入**。请保留原录音并核对纪要，具体边界见[状态清单](docs/STATUS_AUDIT.md)。

## 获取源码

当前需要 GitHub 仓库访问权限；若以后公开，克隆地址保持不变：

```bash
git clone https://github.com/Eliqi797/d3200-recording-bean.git
cd d3200-recording-bean
git config core.hooksPath .githooks
```

`main` 是已检查的源码入口：`bean/` 和 `web/` 是服务端与网页，`harmony/`、`android/`、`ios/` 是三个手机客户端，`deploy/` 和 `scripts/` 放部署及维护工具。克隆后仍需在本机配置自己的 SDK、签名和私有服务凭据；这些内容不在 GitHub。

## 文档入口

| 要做的事 | 文档 |
| --- | --- |
| 从零安装、配置、同步第一条录音 | [普通用户指南](docs/USER_GUIDE.md) |
| 让 AI Agent 查询、部署或修改本项目 | [Agent 使用指南](docs/AGENT_GUIDE.md) / [仓库 Agent 规则](AGENTS.md) |
| GitHub 搜索可见性、公开源码准备 | [可发现性与公开准备](docs/DISCOVERABILITY.md) |
| 仓库范围、提交检查、更新与备份边界 | [仓库维护](docs/REPOSITORY.md) |
| 新服务器部署、HTTPS、备份恢复 | [部署指南](docs/DEPLOYMENT.md) |
| ASR / LLM / 飞书参数与密钥存储 | [配置指南](docs/CONFIGURATION.md) |
| 编译普通鸿蒙 App | [鸿蒙工程说明](harmony/README.md) |
| iOS / Android 移植与待验收项 | [跨平台客户端](docs/CROSS_PLATFORM.md) |
| 数据流与代码位置 | [架构说明](docs/ARCHITECTURE.md) |
| HTTP 接口 | [API](docs/API.md) |
| 当前实现与待验收范围 | [状态清单](docs/STATUS_AUDIT.md) |
| 图标与平台切换限制 | [应用图标](docs/APP_ICONS.md) |
| 上游协议参考与许可证边界 | [引用说明](docs/REFERENCES.md) |

## 本地服务

需要 Python 3.11+。基础上传、回听和测试使用标准库；真实音频处理还需要 FFmpeg，NVIDIA 客户端依赖见 `requirements-nim.txt`。NIM 调用远程 API，不需要 GPU、模型文件或本地 NVIDIA 推理服务。

```bash
python3 -m venv .venv
cp .env.example .env
# 按需填写 .env；不要提交真实值。
.venv/bin/python -m bean.server --data data --port 8765
```

打开 `http://127.0.0.1:8765`，使用服务首次启动创建的 `data/access-token` 登录。服务监听回环地址；手机使用需要独立 HTTPS 入口，不能把手机上的 localhost 当作服务器。需要 NIM 时由操作者执行：

```bash
.venv/bin/python -m pip install -r requirements-nim.txt
```

`.env` 在服务启动时读取；App 保存的服务设置优先于环境变量，在下一处理阶段生效。新克隆不携带个人服务地址或密钥；现有手机/服务器的配置保持在各自私有存储中。

iOS／Android 私人安装包可用 `scripts/prepare_mobile_personal.py` 从本地私有口令文件生成 Git 忽略的编译默认值，避免首次手填。**此类安装包内含可提取的访问口令，只能本人安装，不得分享。**开源源码构建默认无服务连接；见[跨平台客户端](docs/CROSS_PLATFORM.md)。

## 验证代码

Node.js **24+** 用于直接运行 TypeScript/ArkTS 控制器测试；Python 3.11+ 用于服务端测试。

```bash
python3 -m unittest discover -s tests
node --experimental-strip-types --test tests/*.test.mjs
python3 scripts/check_repository.py
```

2026-09-27 本地检查通过：83 项 Python、76 项 Node、6 项 Swift 核心测试，以及 Android Debug 构建、单元测试和 Lint。协议测试使用公开设备证书夹具，不含签名私钥。单元测试不能替代真机、供应商和恢复验收。

## 仓库不是什么

GitHub 只保管源码、测试、图标和文档，不保存录音、数据库、API Key、飞书授权、手机访问口令、HarmonyOS 签名、安装包或私人诊断截图。服务升级不由 GitHub 自动触发；部署需要备份、检查版本及手动发布。未来公开当前源码仓库前必须检查**所有可达提交和分支**中的个人信息、协议引用授权与图标来源；检查记录见[公开准备](docs/DISCOVERABILITY.md)。

## 常见问题

**能把 D3200 录音自动转成飞书文档吗？** 可以。先配置自己的服务器、ASR、LLM 和飞书写入身份；录音完整上传并核验后，处理队列才会推进转写、总结和文档发布。每个阶段都能单独查看状态与重试。

**一定要安装 NVIDIA 模型或 GPU 吗？** 不需要。NVIDIA NIM 方案调用远程 API；本地只需相应的调用依赖和 FFmpeg。也可以配置兼容的其他 ASR 服务。

**可以只用网页版直接连接录音豆吗？** 当前设备扫描、蓝牙握手与高速热点切换由原生手机客户端实现；服务器网页用于访问已保存的数据，不能替代完整的设备传输客户端。

**公开后能从 GitHub 搜到并直接安装吗？** 项目简介、主题标签和中英文 README 已按实际功能准备；仓库公开后才对其他账号可见，搜索收录时间与排名不能保证。手机仍需要自己的 SDK、签名和服务配置，目前没有通用的已签名安装包。公开可见也不等于已授予开源使用许可。
