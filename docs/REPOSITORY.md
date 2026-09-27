# 仓库维护

`Eliqi797/d3200-recording-bean` 是当前源码仓库，保存客户端、服务端、测试、图标和通用文档；旧仓库仅作为私人历史存档。源码仓库不保存录音、数据库、API Key、飞书授权、手机访问口令、调试签名、私人安装包或个人服务器配置。仓库公开与否不改变这些边界。

## 获取和检查

```bash
git clone https://github.com/Eliqi797/d3200-recording-bean.git
cd d3200-recording-bean
git config core.hooksPath .githooks
python3 scripts/check_repository.py
```

`main` 是源码入口。变更提交前运行受影响的 Python、Node、Swift 或 Android 检查；测试通过不代表真实设备、供应商和飞书均已验收。`scripts/check_repository.py` 检查 Git 暂存内容中的受禁路径与已知凭据，`scripts/check_public_readiness.py` 扫描本地可达历史中的典型敏感信息。两者都不是完整的泄密证明。

## 从旧仓库切换

新仓库只接收已检查的源码快照和后续提交，不导入旧私有仓库的历史。旧仓库继续保留为 Private 备查，后续源码更新以本仓库的 `main` 为准。已有部署不会因仓库迁移而自动更新；如部署机仍从旧仓库拉取，维护时应先核对运行版本和备份，再把该部署检出的 Git 来源切换到本仓库。不要直接覆盖运行目录或业务数据。

## 保管与恢复

源码可由 Git 恢复，录音与业务状态必须由独立备份恢复。服务升级前先核对当前提交、数据迁移、运行配置、认证与备份。不要在活跃写入时直接复制数据库，不要把生产目录整体加入 Git。

设备原录音始终保留；手机音频只在服务器返回匹配的大小和整文件 SHA-256 回执后清理。公网 HTTPS 正常校验证书，设备热点的固定证书兼容不能用于其他目标。飞书写入应核对身份、保存文档 ID、在不确定响应后回读，避免重复创建或覆盖人工编辑。
