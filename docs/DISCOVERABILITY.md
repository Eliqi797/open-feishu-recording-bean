# GitHub 可发现性与公开检查

Open 飞书录音豆的公开源码仓库为 `Eliqi797/open-feishu-recording-bean`，从已检查的源码快照建立，没有导入旧私有仓库的历史。旧仓库保留为 Private，不作为公开入口。中文 [`README.md`](../README.md) 与英文 [`README.en.md`](../README.en.md) 是人类首页；[`AGENT_START.md`](../AGENT_START.md) 给 Agent 快速建立系统模型，再按任务进入 `AGENTS.md`、[Agent 指南](AGENT_GUIDE.md)和 API。[集成说明](INTEGRATIONS.md)、[使用场景](USE_CASES.md)、[方案比较](ALTERNATIVES.md)、Topics、仓库简介与 `llms.txt` 提供具体问题和能力入口。这些内容帮助人和 Agent 理解项目，不保证 GitHub、搜索引擎或 AI 搜索的收录与排名。

源码按 [MIT 许可证](../LICENSE)开放；第三方组件与商标边界见[声明](../THIRD_PARTY_NOTICES.md)。GitHub 公开后，在未登录浏览器核对首页、文档和许可证，再用设备名和功能词检查搜索可见性。公开可见不保证搜索引擎或 AI 搜索收录。

公开源码应只包含干净的源码、测试、文档与图标。旧个人运维记录、录音、密钥、签名、服务器地址和本机路径应保存在仓库外。每次发布前检查**所有远端分支、标签和可达提交**，运行 `python3 scripts/check_public_readiness.py` 与 `python3 scripts/check_repository.py`，并核对 GitHub 上的 PR、Release、Actions 日志和缓存。历史重写后的旧提交可能仍存在于缓存或他人的克隆中；敏感数据若曾是有效密钥，应在供应商处轮换，而不能只依赖重写历史。
