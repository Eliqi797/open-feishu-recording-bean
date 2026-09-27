# 鸿蒙普通 App

主产品为普通 App，使用「录音、实时、设置」三个底部标签页。设备控制融合在录音页，全局状态栏跨标签可见。元服务保留为历史协议实验模板，后续 UI 只维护普通 App。

先在 DevEco Studio 安装 SDK 并创建一个空白 ArkTS 工程，然后准备新的 App 工程（复用本地依赖，不下载，不复制签名）：

```bash
python3 scripts/prepare_harmony_variant.py /path/to/blank-project /path/to/new/RecordingBeanApp
```

在 DevEco 中打开新目录，确认包名、SDK 版本并配置自己的开发者签名。当前模板基于 API 22。普通 App 需要蓝牙、网络状态和 Wi-Fi 相关权限；首次连接及热点传输由系统请求授权。

源码层次：

- `entry/src/main/ets/services/` 共用原生服务。
- `shared/` 纯 TypeScript 协议和同步逻辑。
- `standard-overlay/` 普通 App 页面、主题、设置、安全存储、高速传输实现及 EntryAbility。
- `resources/` 普通 App 图标。
- `project/` 可导入模板。用户签名和本机 SDK 配置不纳入源码发行。

每次同步先复制共用服务，再覆盖 standard-overlay，最后复制 resources；不要覆盖已经配置的签名。prepare 脚本只允许创建全新目录，避免误覆盖工作工程。

App 默认不包含任何人的云端地址或密钥。访问口令通过 Asset Store 保存并绑定服务地址，主题与传输偏好保存在应用私有目录；服务端供应商配置见 [配置指南](../docs/CONFIGURATION.md)。

高速传输先下载再上传，恢复公网后继续；只有收到完整结束帧且云端字节校验成功才清理手机缓存，设备原件始终保留。Wi-Fi 内的录音豆证书兼容只适用于已固定的设备证书指纹，云端 HTTPS 使用系统校验。其他设备或固件需要重新验证证书与协议兼容性。
