# 上游参考与许可证边界

本项目为非官方互操作实现，不属于 soundcore、飞书或 NVIDIA。设备协议研究参考了以下公开项目；仓库未合并其源码、模型、依赖包或私人录音。

| 参考项目 | 核对版本 | 使用边界 |
| --- | --- | --- |
| [tacshi/Soundcore](https://github.com/tacshi/Soundcore) | `2f48b2cf811049398e6a4919869b445850ebe179` | 仅核对设备帧、BLE/Wi-Fi 命令、加密与音频封装。检查时未发现明确许可证；不复制其源码。 |
| [andrewseago/d3200-ble-note-downloader](https://github.com/andrewseago/d3200-ble-note-downloader) | `77356096b303bd8b68364ae21db2acd8194ac1ee` | 交叉核对读取与解密行为。上游为 GPLv3；本仓库不合并其实现文件。 |

设备固件和手机系统可能改变行为；参考项目也不能替代自己的真机验证。录音原文件始终保留，传输长度、分片序号、设备身份、证书指纹和云端回执均须按实际协议校验。

供应商接口以官方文档和实际响应为准：[NVIDIA Parakeet API](https://build.nvidia.com/nvidia/parakeet-ctc-0_6b-zh-cn/api)、[Riva ASR protobuf](https://docs.nvidia.com/deeplearning/riva/user-guide/docs/reference/protos/riva_asr.proto.html)、[飞书文档创建](https://open.feishu.cn/document/server-docs/docs/docs/docx-v1/document/create)及[正文回读](https://open.feishu.cn/document/server-docs/docs/docs/docx-v1/document/raw_content)。网页演示、字段声明和免费开发额度均不构成生产时长或准确率保证。
