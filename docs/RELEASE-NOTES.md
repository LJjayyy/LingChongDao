- 老板鼠坐镇的 macOS 工作台与屏幕顶部灵宠岛，包含角色动画和应用标识。
- 同步 Codex、Qoder CN / IDE、Claude Code、ZCode、DeepSeek Harness、CodeBuddy CN、WorkBuddy 的任务活动。
- 提供来源连接、状态提醒，以及受支持的会话跳转和单次权限处理。
- 修复未安装 Codex 时误报配置损坏的提示，保留真实配置错误；没有可用 CLI 时引导先完成来源安装。
- 补齐隐私、卸载、贡献和安全报告说明；统一隔离验证入口并修复动效验证编译依赖。

### 下载与安装

需要 macOS 14 或更新版本，以及 Apple Silicon（M 系列）Mac。

下载附件中的 `LingChongDao-版本-macOS-arm64.dmg`，打开后将“灵宠岛”拖入 Applications，再从“应用程序”启动。普通用户无需安装 Swift、Python 或 Node。

打开“连接的应用”安装所需来源插件，按来源要求审查、启用并重启，再开启新会话验证任务同步。老板鼠动画和 helper 已随安装包提供。

### 首次打开

应用采用 ad hoc 签名，未使用 Developer ID 证书，尚未通过 Apple 公证。首次打开若被 macOS 拦截，请确认安装包来源后，按 [Apple 官方说明](https://support.apple.com/zh-cn/102445)处理。

附件 `SHA256SUMS.txt` 可用于核对下载完整性。GitHub 自动附带的 Source code 文件用于开发者获取源码。

当前需要手动启动与更新；更新前请先退出灵宠岛。问题通常回来源回答，岛内权限处理能力以具体卡片为准。
