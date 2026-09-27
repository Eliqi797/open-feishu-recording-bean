# HarmonyOS、Android 与 iOS 客户端

三个客户端共享“设备读取 → 本机暂存 → 完整性核验上传 → 服务端处理 → 飞书文档”的业务边界，但蓝牙权限、热点连接与签名必须分别按平台处理。源码与自动测试只能证明实现存在；使用者应在自己的手机和 D3200 固件上验证。

| 能力 | HarmonyOS | Android | iOS |
| --- | --- | --- | --- |
| 设备 BLE 扫描、握手与列表 | 普通 App | BluetoothGatt | CoreBluetooth |
| 高速热点传输 | 系统 Wi-Fi 授权 | WifiNetworkSpecifier 与系统确认 | 免费个人团队手动加入热点；支持相应能力的开发团队可使用自动入网构建 |
| 设备证书兼容 | 仅限设备地址和固定公开证书指纹 | 同左 | 同左 |
| 上传与恢复 | 分片、大小及 SHA-256 回执 | 同左 | 同左 |
| 云端处理结果 | 阶段状态、回听、飞书链接 | 同左 | 同左 |

设备热点证书的限定兼容不扩展到公网 HTTPS。设备蓝牙地址可能变化，归档身份必须来自有效握手后的序列号摘要。云端核验通过后才清理手机完整音频缓存；D3200 原文件不删除。

## 从源码构建

- **HarmonyOS**：按 [`harmony/README.md`](../harmony/README.md)用 DevEco Studio 准备普通 App，并使用自己的调试签名。
- **Android**：用 Android Studio 打开 `android/`，准备 Android SDK 36；在该目录运行 `./gradlew :app:assembleDebug :app:testDebugUnitTest :app:lintDebug`。
- **iOS**：用 Xcode 打开 `ios/RecordingBean.xcodeproj`，选择自己的 Team；免费 Personal Team 不勾选 Hotspot Configuration。运行 `swift test --package-path ios` 验证共享核心。

新安装的公开源码构建默认没有私人服务地址或口令；请在 App 设置中连接自己的 HTTPS 服务。签名、系统权限、锁屏限制和设备固件差异可能影响运行。首次使用先测一条已结束的短录音，然后分别测多文件批量传输、长录音、断网、后台恢复、实时窗口和受保护回听；不要从一次构建成功推断全部通过。当前验收范围见[状态清单](STATUS_AUDIT.md)。
