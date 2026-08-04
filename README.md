# Zemote

**Zemote** 是 ZCode（zcode.z.ai）桌面端的**移动远程控制客户端**，对官方 Web 远程控制协议进行完整复刻（protocol reimplementation）。

你可以在手机/平板上**同时管理多台桌面设备**：扫码或粘贴链接添加设备 → 连接桌面 ZCode → 浏览任务列表、收发对话、查看文件变更、管理模型供应商与用量配额。

> ⚠️ 本项目是**协议复刻**，与官方客户端无任何代码关联。请遵守 ZCode 服务条款与当地法律法规，仅用于连接你自己的设备。

---

## 功能特性

- **多设备并发**：多台设备可同时在线，一键切换无需重连
  - 设备列表独立显示每台的连接状态 / 连接中 / 错误
  - MainShell 顶部设备切换栏，随时跳转已连接设备
  - 未连接设备可直接在切换器中连接，也可添加新设备
- **添加设备**：扫码（`mobile_scanner`）或粘贴远程控制 URL（`https://zcode.z.ai/remote/v4?...`）
- **任务管理**：任务 / 置顶 / 已归档三栏，搜索过滤、下拉刷新、滑动置顶/归档、重命名、删除
  - 实时订阅 `sessions-index`，与 workspace-list 推送合并去重
  - 未读标记、最近预览文本、运行状态点
- **对话（Conversation V4）**：
  - 流式回复、推理过程展示、斜杠命令、模型/模式/思考级别切换
  - 排队消息管理、目标（goal）指令、暂停/恢复
  - 附件上传/预览、文件变更 diff、文件回滚、编辑用户消息、点赞/点踩
- **协议层**：完整复刻官方 relay 握手、配对证明（HMAC-SHA256）、rpc-frame 分片传输（CRC32 校验 + ack）、IPC 值编解码、V4 快照/增量协议
- **调试工具**：协议日志页、RPC（relay payload）调试器、Channel RPC 调试器
- **其他**：模型供应商管理（添加/启停/删除）、用量/配额/订阅查看、浅色/深色主题、字体缩放、中英双语

## 平台

| 平台 | 状态 |
|------|------|
| Android | ✅ 主要目标平台 |
| Web | ✅ 可用（调试/快速预览） |
| Windows | ⚙️ 桌面端可用（未重点优化） |
| iOS / macOS / Linux | 未验证（理论上可构建） |

## 项目结构

```
lib/
├── main.dart                 # 应用入口 + 主题/字号注入
├── protocol/                 # ZCode 协议复刻（纯 Dart，可单测）
│   ├── connection_params.dart# 远程控制 URL 解析 + relay WS 地址
│   ├── proof.dart             # 配对证明（HMAC-SHA256 / base64url）
│   ├── relay_client.dart      # relay WebSocket 连接 + 心跳 + 重连
│   ├── rpc_transport.dart     # rpc-frame 分片/重组/校验
│   ├── channel_client.dart    # IPC channel RPC 调用/事件
│   ├── ipc_codec.dart         # 值编解码 + IPC 帧解析
│   ├── conversation.dart      # Conversation V4 / sessions-index 订阅
│   └── zemote_client.dart     # 高层门面：bootstrap/bridge/恢复
├── state/                    # 应用状态
│   ├── account_store.dart     # 多设备账号持久化（SharedPreferences）
│   ├── app_session.dart       # 多设备连接管理
│   └── log_store.dart         # 协议日志
└── ui/                       # 界面
    ├── accounts_page.dart     # 设备列表
    ├── main_shell.dart        # 主壳（设备切换 + 任务/设置）
    ├── task_home_page.dart    # 任务列表
    ├── chat_page.dart         # 对话页
    └── ...                    # 其余页面/组件

test/                         # 单元测试（协议层 + 状态层 + diff）
integration_test/             # 对真实桌面的集成测试（需 ZEMOTE_PROBE_URL）
```

## 快速开始

### 前置条件

- Flutter SDK（本项目 `sdk: ^3.5.0`）
- 桌面端已安装并打开 **ZCode**（zcode.z.ai）

### 获取远程控制 URL

桌面 ZCode → 远程控制 → 生成二维码 / 复制链接，形如：

```
https://zcode.z.ai/remote/v4?sid=...&hash=...&t=...&mid=...&name=...
```

### 运行

```bash
# Android
flutter run

# Web（快速预览）
flutter run -d chrome

# Windows
flutter run -d windows
```

应用内：**添加设备** → 扫码或粘贴 URL → 连接桌面 → 完成配对 → 进入任务列表。

### 构建 APK

```bash
flutter build apk
# 产物：build/app/outputs/flutter-apk/app-release.apk
```

## 测试

```bash
# 单元测试（协议编解码 / 状态机 / delta 应用等）
flutter test

# 集成测试：需要真实桌面 + 自己的远程控制 URL
# 通过环境变量提供（切勿把 URL 提交到仓库！）
$env:ZEMOTE_PROBE_URL="https://zcode.z.ai/remote/v4?sid=..."
flutter test integration_test
```

## 安全提示

- **不要把远程控制 URL 提交到仓库**——它包含你的设备 `sid`/`hash` 凭据，拿到即可控制你的设备。
- 集成测试通过 `ZEMOTE_PROBE_URL` 环境变量注入 URL；`.gitignore` 已忽略 `.env`、`*.remote.*` 等文件。
- 若意外泄露，请在桌面端重新生成远程控制二维码（旧凭据会失效）。

## 技术栈

- [Flutter](https://flutter.dev) / Dart
- [web_socket_channel](https://pub.dev/packages/web_socket_channel) — relay 长连接
- [crypto](https://pub.dev/packages/crypto) — HMAC-SHA256 配对证明
- [mobile_scanner](https://pub.dev/packages/mobile_scanner) — 扫码
- [zxing2](https://pub.dev/packages/zxing2) — 纯 Dart 二维码解码（图片识别）
- [shared_preferences](https://pub.dev/packages/shared_preferences) — 账号持久化
- [image_picker](https://pub.dev/packages/image_picker) / [file_picker](https://pub.dev/packages/file_picker) — 附件
- [flutter_markdown](https://pub.dev/packages/flutter_markdown) — Markdown 渲染

## License

[MIT](LICENSE)

## 免责声明

本项目为个人学习与互操作目的，对 ZCode 远程控制协议的独立复刻，非官方出品。使用者须自行承担风险与合规责任。
