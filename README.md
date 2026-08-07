<div align="center">

# Zemote

**手机/平板上的 ZCode 远程控制客户端** — 独立复刻官方 Web 远程控制协议（protocol reimplementation）

[![Flutter](https://img.shields.io/badge/Flutter-3.5%2B-blue.svg?logo=flutter)](https://flutter.dev)
[![Dart](https://img.shields.io/badge/Dart-3.5%2B-0175C2.svg?logo=dart)](https://dart.dev)
[![CI](https://github.com/HumanAILoop/zemote/actions/workflows/build-apk.yml/badge.svg)](https://github.com/HumanAILoop/zemote/actions/workflows/build-apk.yml)
[![Release](https://img.shields.io/github/v/release/HumanAILoop/zemote)](https://github.com/HumanAILoop/zemote/releases)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/Platform-Android%20%7C%20Web%20%7C%20Windows-lightgrey.svg)](#平台)

在手机/平板上**同时管理多台桌面设备**：扫码或粘贴链接添加设备 → 连接桌面 ZCode → 浏览任务列表、收发对话、查看文件变更、管理模型供应商与用量配额。

> ⚠️ 本项目为**协议复刻**，与官方客户端无任何代码关联。请遵守 ZCode 服务条款与当地法律法规，仅用于连接你自己的设备。

</div>

---

## 目录

- [功能特性](#功能特性)
- [平台](#平台)
- [快速开始](#快速开始)
- [更新与签名](#更新与签名)
- [架构](#架构)
- [测试](#测试)
- [项目结构](#项目结构)
- [安全提示](#安全提示)
- [技术栈](#技术栈)
- [贡献](#贡献)
- [Changelog](#changelog)
- [License](#license)

---

## 功能特性

### 多设备并发
- 多台设备可同时在线，一键切换无需重连
- 设备列表独立显示每台的连接状态（连接中 / 已连接 / 错误）
- 顶部设备切换栏随时跳转，未连接设备可直接连接或添加新设备

### 添加设备
- 扫码（`mobile_scanner`）或粘贴远程控制 URL（`https://zcode.z.ai/remote/v4?sid=...&hash=...&t=...`）

### 任务管理
- 任务 / 置顶 / 已归档三栏，搜索过滤、下拉刷新、滑动置顶/归档、重命名、删除
- 实时订阅 `sessions-index`，与 workspace-list 推送合并去重
- 未读标记、最近预览文本、运行状态点

### 对话（Conversation V4）
- 流式回复、推理过程展示、斜杠命令（`/`）、Skills（`$`）、模型/模式/思考级别切换
- **辅助对话**：为当前会话开启独立侧对话（`createSelectionSideSession`），互不干扰并行提问
- 排队消息管理、目标（goal）指令、暂停/恢复
- 附件上传/预览、文件变更 diff、文件回滚、编辑用户消息、点赞/点踩

### 协议层
完整复刻官方 relay 握手、配对证明（HMAC-SHA256）、rpc-frame 分片传输（CRC32 校验 + ack）、IPC 值编解码、V4 快照/增量协议。

### 调试工具
- 协议日志页（relay / IPC / V4 帧）
- RPC（relay payload）调试器
- Channel RPC 调试器

### 其他
- 模型供应商管理（添加/启停/删除）、用量/配额/订阅查看
- 浅色/深色/跟随系统主题、字体缩放、中英双语
- **更新检测**：启动自动检查 GitHub 最新发布，Android 端一键下载 APK 并调用系统安装器升级
- **后台任务通知（Android）**：任务运行中时通知栏静默常驻并实时更新最新进展；任务完成静默提醒（不弹窗打扰）；点击通知直达对应对话

## 平台

| 平台 | 状态 |
|------|------|
| Android | ✅ 主要目标平台 |
| Web | ✅ 可用（调试 / 快速预览） |
| Windows | ⚙️ 桌面端可用（未重点优化） |
| iOS / macOS / Linux | 未验证（理论上可构建） |

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

## 更新与签名

- 应用内置**更新检测**：启动时与 GitHub 最新 Release 比对版本号，发现新版本弹窗提示；Android 端可直接下载 APK 并调用系统安装器升级。
- 发布流程：在 `main` 上打好代码 → 提交 → `git tag vX.Y.Z` → 推送。GitHub Actions 自动执行 `flutter analyze` + `flutter test` + 构建并上传 **统一签名** 的 release APK 到 GitHub Release。
- 签名说明：release APK 使用正式 keystore 签名（本地 `android/key.properties` + CI Secrets），保证覆盖安装与持续更新可用。详见 `.github/workflows/build-apk.yml`。

## 架构

```
┌────────────────────────────────────────────────────────────┐
│ UI (lib/ui)     设备列表 / 任务 / 对话 / 设置 / 调试器        │
├────────────────────────────────────────────────────────────┤
│ State (lib/state)  AccountStore · AppSession · LogStore    │
├────────────────────────────────────────────────────────────┤
│ Facade (lib/protocol/zemote_client.dart)                    │
│   relay → 配对 → bootstrap → workspace-bridge → channel RPC │
├────────────────────────────────────────────────────────────┤
│ Protocol (纯 Dart，可单测)                                  │
│   RelayClient · RpcFrameTransport · ChannelClient           │
│   IpcCodec · Conversation(V4) · Proof(HMAC-SHA256)          │
└────────────────────────────────────────────────────────────┘
```

协议分层示意：

| 层 | 职责 |
|---|---|
| `connection_params.dart` | 远程控制 URL 解析 + relay WS 地址 |
| `proof.dart` | 配对证明（HMAC-SHA256 / base64url） |
| `relay_client.dart` | relay WebSocket 连接 + 心跳 + 重连 |
| `rpc_transport.dart` | rpc-frame 分片/重组/CRC32 校验/ack |
| `ipc_codec.dart` | 值编解码 + 13 字节 IPC 帧解析 |
| `channel_client.dart` | IPC channel RPC 调用/事件订阅 |
| `conversation.dart` | Conversation V4 / sessions-index 快照+增量 |
| `zemote_client.dart` | 高层门面：bootstrap / bridge / 断线恢复 |

## 测试

```bash
# 单元测试（协议编解码 / 状态机 / delta 应用 / 更新检测等）
flutter test

# 集成测试：需要真实桌面 + 自己的远程控制 URL，通过环境变量注入
$env:ZEMOTE_PROBE_URL="https://zcode.z.ai/remote/v4?sid=..."
flutter test integration_test
```

## 项目结构

```
lib/
├── main.dart                 # 应用入口 + 主题/字号注入 + 启动更新检测
├── protocol/                 # ZCode 协议复刻（纯 Dart，可单测）
├── state/                    # 应用状态（多设备账号 / 连接管理 / 日志）
├── ui/                       # 界面（设备 / 任务 / 对话 / 设置 / 调试器）
└── update/                   # 更新检测 + Android 下载安装
test/                         # 单元测试
integration_test/             # 对真实桌面的集成测试（需 ZEMOTE_PROBE_URL）
```

## 安全提示

- 远程控制 URL 包含设备凭据（`sid` / `hash`），相当于设备的访问凭证，**切勿提交到版本库或分享给他人**。
- 集成测试通过环境变量 `ZEMOTE_PROBE_URL` 注入 URL，不写死在测试代码里；`.gitignore` 已忽略 `.env`、`*.remote.*`、签名文件（`*.jks` / `key.properties`）等。
- 如凭据意外泄露，请在桌面端 ZCode 中重新生成远程控制二维码（旧凭据立即失效）。

## 技术栈

- [Flutter](https://flutter.dev) / Dart
- [web_socket_channel](https://pub.dev/packages/web_socket_channel) — relay 长连接
- [crypto](https://pub.dev/packages/crypto) — HMAC-SHA256 配对证明
- [mobile_scanner](https://pub.dev/packages/mobile_scanner) — 扫码
- [zxing2](https://pub.dev/packages/zxing2) — 纯 Dart 二维码解码（图片识别）
- [shared_preferences](https://pub.dev/packages/shared_preferences) — 账号持久化
- [image_picker](https://pub.dev/packages/image_picker) / [file_picker](https://pub.dev/packages/file_picker) — 附件
- [flutter_markdown](https://pub.dev/packages/flutter_markdown) — Markdown 渲染
- [http](https://pub.dev/packages/http) — 更新检测（GitHub Releases API）

## 贡献

欢迎提交 Issue 与 Pull Request。贡献前请确保：

1. `flutter analyze` 无告警
2. `flutter test` 全部通过
3. 集成测试改动需注明需要真实桌面环境

## Changelog

版本变更记录见 [CHANGELOG.md](CHANGELOG.md)。

## License

[MIT](LICENSE)

## 免责声明

本项目为个人学习与互操作目的，对 ZCode 远程控制协议的独立复刻，非官方出品。使用者须自行承担风险与合规责任。
