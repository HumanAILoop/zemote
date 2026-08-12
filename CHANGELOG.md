# Changelog

本项目遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，版本号遵循 [Semantic Versioning](https://semver.org/lang/zh-CN/)。

## [0.3.2] - 2026-08-07

### Fixed
- **断线后发消息超时**：relay 断开时立即标记 bridge 降级，命令在恢复前排队等待（`waitHealthy`）；发送超时后等待重连并自动重试一次；聊天页新增「正在自动重连」提示条。
- **聊天配色异常（尤其浅色主题代码块）**：markdown 代码块/行内代码/推理与工具卡片背景改为主题感知色，浅色下不再白底白字。
- **同一条回复被拆成多条消息**：会话分组不再因服务端 `turnId` 中途变化而拆散，一条回复合并为单条气泡（一个点赞区）。
- **AI 询问用户（交互）弹窗显示不正确**：按官方 schema 修正权限请求选项、自由输入；新增 `questions` 表单渲染（单选/多选）。

## [0.3.1] - 2026-08-07

### Fixed
- **新建会话首条消息可能发不出去**：普通文本首条消息改为随 `createSession(firstInput)` 一起发送（对齐官方 composer），避免订阅未就绪时命令被丢弃；附件/目标指令路径在发送前等待订阅建立。
- **发送失败不再静默**：`sendText` / `sendGoalCommand` 的 ack 现在会被检查，被拒时提示具体原因。

## [0.3.0] - 2026-08-07

### Added
- **后台任务通知（Android）**：任务运行中时，通知栏静默常驻并实时更新最新进展（前台服务保活）；任务完成静默提醒（低优先级、不弹窗）；点击通知直达对应对话。

## [0.2.1] - 2026-08-06

### Added
- **Skills 支持**：通过 `skills.list` channel 拉取桌面端 Skills，合并进斜杠命令列表（`$` 前缀触发）；新增「选择 Skills」底部弹层，一键填入 `$skillname`。
- **统一 Release 签名**：引入正式 keystore，本地与 CI（GitHub Secrets）使用同一签名，APK 可覆盖安装、支持持续升级。

### Changed
- 输入框：Enter 改为换行，仅通过发送按钮发送；缩短提示文案避免变形。
- 设置页：主题/语言切换按钮改为紧凑小字号，避免变形；新增「检查更新」入口与当前版本展示。
- 状态点颜色改为主题感知，浅色主题下不再不可见。

### Fixed
- 浅色主题下部分文本/图标配色不可读的问题（全面改用主题感知的 `ZInk` 配色）。

## [0.2.0] - 2026-08-05

### Added
- **辅助对话（Side Chat）**：`createSelectionSideSession` 协议支持 + 对话页入口，可开启独立侧对话并行提问。
- **更新检测**：启动自动检查 GitHub 最新发布；Android 端可下载 APK 并调用系统安装器升级（设置页含手动入口）。
- 协议字段扩展：`sendText` / `sendGoalCommand` / `createSession` 新增 `automationId`、`offPeakTaskId`、`botDeliveryTarget`、`runtimeModel`、`mcpServers` 等；sessions-index 新增 `parentSessionId`。
- 对话页展示 `prepareWorkspace` 中的其他配置项（如最大输出长度、搜索增强）。

### Changed
- 设备身份改为真实值（`platform` / `name`），不再伪装为浏览器。
- 版本号升至 `0.2.0+1`。

## [0.1.0] - 2026-08-04

### Added
- 首个发布版本：ZCode 桌面端移动远程控制客户端（协议复刻）。
- 多设备并发连接、扫码/粘贴添加设备。
- 任务列表（任务/置顶/已归档 + 搜索 + 未读标记）。
- Conversation V4 对话：流式回复、推理过程、斜杠命令、模型/模式/思考切换、排队消息、目标指令、附件、diff、回滚、反馈。
- 模型供应商管理、用量/配额/订阅查看。
- 协议调试工具（日志 / RPC / Channel）。
- 浅色/深色主题、字体缩放、中英双语。
