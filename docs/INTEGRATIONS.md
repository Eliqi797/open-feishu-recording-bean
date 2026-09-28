# 集成说明：ASR、LLM 与飞书 / Lark

RecordingBean 的服务器在完整录音通过大小与 SHA-256 核验后，按独立阶段处理转写、说话人信息、总结和文档写入。每一层都需要使用者自己的访问权限；是否成功应看实际供应商响应和飞书回读，不能仅凭配置已填写判断。

| 环节 | 现有接入 | 需要自己提供 |
| --- | --- | --- |
| ASR | NVIDIA NIM Parakeet 中文、NVIDIA NIM Whisper、兼容 /audio/transcriptions 的接口 | 相应 API Key；兼容接口还需 HTTPS 地址和模型 ID |
| LLM | 兼容 /chat/completions 且能返回约定 JSON 的接口 | HTTPS 地址、模型 ID 和 API Key；没有预置付费模型 |
| 飞书 / Lark Docs | 用户令牌、应用凭据调用 OpenAPI，或服务器上的 [lark-cli](https://github.com/larksuite/cli) 模式 | 目标身份、相应授权与文档权限；CLI 模式还需在服务器安装并登录 CLI |

完整参数、配置优先级与密钥保存方式见[配置指南](CONFIGURATION.md)。NVIDIA NIM 是远程 API 选项，不要求服务器有 NVIDIA GPU 或下载模型。Whisper 可以用作质量对照，不代表每条录音都要调用两次 ASR。DeepSeek 等服务只有在其接口与本项目要求兼容、并由使用者配置后才能作为 LLM 使用；项目不预装或保证任何特定付费模型。

服务器已有 lark-cli 文档操作适配：选择 CLI 身份方式时调用服务器上的 CLI 创建、读取和更新文档，并核对用户身份。它与飞书 OpenAPI 的用户令牌、应用凭据是不同接入方式；不要在身份不符时自动切换。本文不声称 CLI 已在每个使用者环境完成真实授权或发布验收。

说话人字段取决于实际 ASR 响应，缺失时保留未知；独立 Sortformer 尚未接入。飞书文档写入后还需回读并在目标账号确认可见。处理阶段和重试语义见[Agent 指南](AGENT_GUIDE.md)及[API](API.md)。
