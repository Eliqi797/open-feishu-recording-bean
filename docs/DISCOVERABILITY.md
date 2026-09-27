# GitHub 可发现性与公开检查

当前源码仓库为 `Eliqi797/d3200-recording-bean`，从已检查的源码快照建立，没有导入旧私有仓库的历史。旧仓库保留为 Private，不作为公开入口。中文 [`README.md`](../README.md) 和英文 [`README.en.md`](../README.en.md) 分别介绍 D3200 / soundcore Work 录音同步、自托管转写、AI 会议纪要、HarmonyOS / Android / iOS 和飞书 / Lark Docs；Topics、仓库简介、`AGENTS.md` 与 `llms.txt` 提供额外入口。这些内容帮助人和 Agent 理解项目，不保证 GitHub、搜索引擎或 AI 搜索的收录与排名。

当前仓库为 Private，外部用户无法搜索或读取它。以后若决定公开，应先选择许可证、复核源码与图标权利，再切换可见性；公开后在未登录浏览器核对首页与文档，再用设备名和功能词搜索。公开可见不等于获得开源使用许可。

本仓库的公开源码应只包含干净的源码、测试、文档与图标。旧个人运维记录、录音、密钥、签名、服务器地址和本机路径应保存在仓库外。切换可见性前，检查**所有远端分支、标签和可达提交**，运行 `python3 scripts/check_public_readiness.py` 与 `python3 scripts/check_repository.py`，并核对 GitHub 上的 PR、Release、Actions 日志和缓存。历史重写后的旧提交可能仍存在于缓存或他人的克隆中；敏感数据若曾是有效密钥，应在供应商处轮换，而不能只依赖重写历史。
