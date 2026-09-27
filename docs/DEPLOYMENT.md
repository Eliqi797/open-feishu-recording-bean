# 自托管部署与恢复

RecordingBean 是单人服务。请为它准备独立系统用户、代码目录、数据目录、HTTPS 域名与备份目标，不与其他业务共用数据库或访问口令。以下是部署模板，**不是**任何作者服务器的现行配置。

## 服务布局

- Python 3.11+、FFmpeg；NVIDIA NIM 调用依赖见 `requirements-nim.txt`。使用托管 NIM API 不需下载模型或部署 GPU 推理服务。
- 代码可放在 `/opt/recordingbean`，数据放在仅服务用户可读写的 `/var/lib/recordingbean`，环境文件放在权限 0600 的私有位置。不要提交 `.env`、`data/`、访问口令或飞书 CLI 授权目录。
- 服务默认绑定 `127.0.0.1:8765`。手机通过 Caddy 或 Nginx 提供的 HTTPS 域名访问；不要把 8765 直接开放到公网。反向代理示例在 `deploy/`。
- 首次启动会在数据目录创建 `access-token`。该口令可管理整个单人部署，不能放进 URL、日志、Issue 或安装包。应用设置和环境变量的关系见[配置指南](CONFIGURATION.md)。

## 上线核对

1. 在隔离目录运行自动测试，确认 SDK、FFmpeg、磁盘和 HTTPS 配置。让 `AUTO_PIPELINE=0`，先验证上传、完整性回执和受保护回听。
2. 再用自己的短样本逐阶段验证 ASR、说话人、总结与飞书写入；确认目标飞书身份和文档回读后才启用自动处理。
3. 验证未认证音频请求被拒绝、跨域写入被拒绝、Range 回听可用，且没有凭据进入代理日志。
4. 配置独立的备份目标和定时任务。备份源代码之外，还要保护录音、数据库、环境配置、访问口令及飞书授权；按各自敏感级别分别保管。
5. 在新目录实际做一次恢复演练并回听音频；仅有备份文件或脚本成功退出不等于恢复能力已通过。

## 本地备份与恢复演练

对生产服务先安排停写窗口；不要在 SQLite 活跃写入时直接复制数据库文件。示例命令中的路径必须由操作者替换为自己的隔离目录：

```bash
.venv/bin/python scripts/backup.py backup data /path/to/new-snapshot
.venv/bin/python scripts/recovery_drill.py /path/to/new-snapshot /path/to/new-restore --report /path/to/report.json
```

恢复脚本不会调用外部供应商、写飞书或覆盖原数据。上线、升级与回滚时核对数据库版本、服务进程、认证和一条完整业务记录；GitHub 推送不会自动部署或备份运行中的服务。
