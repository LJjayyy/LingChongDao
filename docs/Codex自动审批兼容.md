# Codex「帮我审批」误报修复

2026-10-28，灵宠岛 0.1.39（build 40）。

## 复现与根因

旧实现为所有带 helper 关联 ID 的 PermissionRequest 建立人工审批卡片，等待最长 45 秒。隔离回放使用真实 helper、Unix socket、AppModel 和包含 `approvals_reviewer: auto_review` 的当前回合记录。

修复前运行 `bash scripts/verify-codex-approvals.sh`，稳定失败于 `Auto-review must not create a human approval card`。

通过 Context7 `/openai/codex` 核对官方 `core/src/tools/approvals.rs` 与 `hooks/src/events/permission_request.rs`：PermissionRequest Hooks 先执行，返回无决定后才到自动审查或用户审批。因此岛内等待会阻塞自动审查，而 Hook 的存在并不能证明用户正在等待。

排查时依次考虑：Hook 抢先阻塞自动审查；未知审查者被默认当成人工；请求交回来源后残留。隔离回放确认前两项；本次通过不创建错误等待来避免它产生残留，不将其称为对所有来源残留问题的修复。

## 行为

- 当前会话、当前回合明确为 `user`：继续原有岛内审批，包括预览校验、批准一次、拒绝、排队和返回来源。
- `auto_review`：立即回传空决定 `{}`，不创建卡片、不增加橙色数量、不改变运行或未读状态，交由 Codex 自动审查。
- 元数据缺失、旧版本缺少字段、未知值、会话不符、回合过时、记录不完整、不可读或非普通文件：同样立即交回 Codex。需要人工介入的请求仍由 Codex 原界面处理。
- 无 ID 的权限观察维持原有行为，不清除已有真实问题或审批。其他来源不受此分流影响。

修复发生在应用接收端，Codex 插件及 helper 不变，无须重新安装插件或修改信任。未更改任何 Codex 权限策略、自动审查策略或持久允许规则，也没有自动允许或拒绝操作。

## 官方能力与兼容边界

[Auto-review](https://learn.chatgpt.com/docs/sandboxing/auto-review) 说明自动审查是审查者的替换，不扩大权限；电脑操作的部分审批仍直接交给用户。

[Hooks](https://learn.chatgpt.com/docs/hooks) 的当前输入有 `permission_mode`，但没有专门的审查者字段，且明确说明 transcript 格式不是稳定接口。因此本次只把 Hook 提供路径中的当前回合元数据作为保守的显示兼容提示，不把它当成允许或拒绝的依据。只读首部最多 64 KiB 与末尾最多 1 MiB，核对会话 ID、最新回合 ID 和明确的审查者值；不使用全局配置猜测当前聊天模式。任何不确定性都留给 Codex。

[App Server](https://learn.chatgpt.com/docs/app-server) 提供原生 `item/*/requestApproval` 和 `serverRequest/resolved` 生命周期，适合应用作为该服务器的客户端时维护真实待办。本次没有接管用户正在运行的桌面聊天，也没有将启动另一个 App Server 误当成能监听已有聊天。

## 验证

- 审批回放：连续三次各 32 项通过，覆盖自动、未知、人工、并发、过期、取消、重复点击和无持久权限变更。元数据检查覆盖当前/过时回合、同回合切换、不同会话、缺少字段、非交互策略和部分写入。
- 权限观察：Core 34 项、AppModel 19 项通过。
- Codex 同步与异步问答生命周期验证通过。
- 版本 0.1.39 已签名验证、安装并重启。使用原有插件 helper、当前真实 `auto_review` 会话元数据和已安装应用回放 PermissionRequest，0.048 秒返回 `{}`，确认命中新分流；没有执行载荷里的命令。证据：[codex-auto-review-native.json](evidence/codex-auto-review-native.json)。这验证了原有 helper 与新应用的兼容，不冒充一次真实自动审查模型调用。
