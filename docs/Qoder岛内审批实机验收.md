# Qoder 权限状态实机验收与审批方案撤回

日期：2026-10-28。Qoder CN App 0.4.11，内置 qoderclicn 1.1.76，模型 Qwen3.8-Flash。修复后灵宠岛 0.1.37（build 38），Qoder 插件 0.1.1。

最终结论：撤回 Qoder 岛内审批，正式插件保留状态同步与回来源处理。0.1.38 已本机安装，插件经一键更新到 0.1.2。下文保留旧审批实验的故障证据。

## 最终范围：正式插件保留状态同步

用户确认：如果正式版插件无法稳定实现，就不做 Qoder 岛内审批集成。因此撤回 Qoder 的岛内允许/拒绝，停止开发插件实验方案。以下审批测试是撤回前的历史证据，不代表现版仍支持审批。

应用 0.1.38（build 39）、Qoder 插件 0.1.2：

- PermissionRequest 只显示「请在来源确认」，不提供允许或拒绝。helper 即时返回 `{}`，不等待岛内决定，不添加持久权限。
- HookOutput 明确禁止生成任何 Qoder allow/deny，即使遇到旧卡片也不会回传决定。
- 保留 UUID 仅用于状态关联；用内存中唯一匹配的 PreToolUse 关联后续工具结果，来源处理后撤销等待。相同命令并发时不猜测关联。
- 主会话 Stop / StopFailure / SessionEnd 清除等待；其他并行工具事件不会假装权限已处理。没有逐交互结束事件时，仍依赖后续结果或回合结束，不能称为完整双向审批同步。
- Codex、Claude 等其他来源的审批不受影响。

只读检查本机 Qoder CN 0.4.11 安装包，发现 `.qoder-app-plugin` 与 `chat.respondToInteraction` / `chat.getState`。但正式安装包的额外本地 App 插件加载需要显式启用 unverified development sources；普通 `.qoder-plugin` ZIP 安装不能直接提供这组 App 接口。没有启用开发入口、重启 Qoder、修改其安装包或冒用内置插件身份。

新增回归先复现来源处理后卡片残留，再修复；最终测试改为正式的只读状态行为，覆盖真实 helper/socket、来源优先完成、旧按钮失效、所有 Qoder 宿主、终态和禁止决策输出。

## 0.1.38 本机正式路径复测

在现有 Qoder App 的专用临时工作区中新建「Qoder 正式插件状态验收」任务，没有重启 Qoder，也未中断其正在运行的业务任务。要求只执行一次 Bash，把 `state-only` 写入 `/private/tmp/lcd-qoder-approval-20261028/state-only-1038.marker`，拒绝即停止。

- Qoder 正常出现原生「Shell 想要执行一个操作」确认框。
- 灵宠岛工作台同一测试会话显示「等待批准」，没有岛内批准/拒绝按钮。
- 在 Qoder 点击「拒绝」后，Qoder 回复未执行、未重试，显示「状态：成功」，没有此前的回合收尾错误。
- 岛端同步为「本轮结束」，原等待提示已撤销。临时 marker 不存在。
- 已安装应用与共享 helper 的 SHA-256 一致。

最终自动验证：Qoder 状态 22 项、Codex 审批 14 项、Claude 审批 13 项、核心 43 项全部通过；发布构建和插件包契约检查通过。

## 真实漏接与修复

先在 Qoder App 创建独立临时工作区和测试任务，选择「每次询问」。只要求 Bash 向临时目录写一个标记，拒绝即停止，不重试、不更换工具。

原版出现 Qoder 自身的 Shell 允许/拒绝框，岛上没有可操作请求。通过仅位于测试工作区的诊断 Hook 捕获该任务的实际输入，确认：

- PreToolUse 有 `tool_use_id`，PermissionRequest 没有。
- PermissionRequest 包含 `session_id`、`cwd`、`tool_name: Bash`、`tool_input.command/description`、`permission_suggestions`。
- Qoder 的「每次询问」在本机载荷中映射为 `permission_mode: acceptEdits`，仍会对该 Bash 命令要求确认。
- 旧实现要求稳定工具 ID 才提供审批回传；无 ID 时退化为只读提示，并被短观察连接期限很快清掉。

修复为由 helper 对每次 Qoder PermissionRequest 注入独立 UUID，与其活跃 Unix socket 的传输请求 ID 绑定；应用验证绑定后排队展示。相同命令、子任务和主任务的请求独立回复。只返回一次性的 `allow/deny`，不采纳权限建议中的持久规则。复杂请求仍只提供拒绝和回来源处理。

补充识别 Qoder 的 `Notification: permission_prompt`，主动回来源后继续显示只读等待。诊断 Hook 已在最终复测前移除，后续三轮仅使用用户实际安装的灵宠岛插件。插件和 helper 通过灵宠岛的一键更新入口更新。

## Qoder App 实际结果

测试根目录：`/private/tmp/lcd-qoder-approval-20261028`。所有点击均在真实 Mac 应用完成，没有以模拟事件替代这三项验收。

| 路径 | 岛内操作 | 命令结果 | Qoder App 收尾 |
| --- | --- | --- | --- |
| 允许 | 点击「批准一次」 | `allow-fixed.marker` 创建，内容为 `approved`；Qoder 回复已执行 | 报「这轮回复失败 / 发生了意外错误」 |
| 拒绝 | 点击「拒绝」 | `deny-fixed.marker` 不存在；Qoder 回复被拒绝、未重试 | 同样报收尾错误 |
| 回来源 | 点击消息图标/标题，交回当前请求 | 出现 Qoder 自身 Shell 确认框；在来源点击拒绝；`fallback-fixed.marker` 不存在 | 显示「状态：成功」，正常结束 |

等待时岛上显示单条「待批准」卡片、完整命令和倒计时，无其他任务或保持唤醒工具栏；回来源后显示只读「请在来源确认」，没有误报运行中。

## 收尾异常证据与边界

仅检查本次专用测试会话的 Qoder 应用诊断日志，没有读取业务会话记录。`main.log` 的拒绝测试记录：

```text
ChatSession execution event handling failed
eventType: turn-completed
Error: 非法的 Turn 状态转换：waiting-user -> completed
```

栈位于 Qoder 自身 `app.asar/out/main/electronMain.js` 的回合状态转换；随后本次会话从 `waiting-user` 进入 `error/failed`。岛内请求已经按用户决定结束，源命令结果也与决定一致。回来源后由 Qoder UI 回答则正常结束，说明当前 App 对 Hook 直接决定后的等待状态处理有兼容性问题。没有改动 Qoder 安装包、内部状态或信任配置来绕过它。

在 Qoder App 修复该问题之前，建议点击岛上消息图标回 Qoder 处理。不能把命令执行正确等同于桌面端完整验收通过；也不据此推断其他版本、IDE 或直接 CLI 的结果。

## 回归

- `bash scripts/verify-qoder-approvals.sh`：旧实现先复现 `first request arrived` 失败；修复后 15 项通过。覆盖真实载荷形状、权限建议不持久化、并发主/子任务、允许/拒绝、旧卡片、回来源通知、超时、取消、无客户端和传输 ID 不匹配。
- Codex 审批 14 项、Claude 审批 13 项、Codex 问答、核心 43 项均通过。
- 发布构建与插件 17 项离线契约检查通过。
- 本机已安装应用 0.1.37，并通过一键更新将 Qoder 插件升级到 0.1.1；共享 helper 与应用捆绑 helper 的 SHA-256 一致。

## 协议依据

通过 find-docs / Context7 `/websites/qoder` 查询并核对：

- [官方 Hooks 文档](https://docs.qoder.com/cli/hooks)：PermissionRequest 输入及 `hookSpecificOutput.decision` 的 allow/deny 协议。
- [官方权限文档](https://docs.qoder.com/cli/permissions)：权限检查与 PermissionRequest 的触发顺序。
- [官方脚本运行文档](https://docs.qoder.com/cli/run-in-scripts)：headless 模式的确认请求会自动拒绝，因此本次使用真实 Qoder App 验收。

诊断中“清空当前工作目录”按钮被自动审批审查拦截，未执行；改为新建仅指向临时目录的独立工作区。没有清空或修改业务工作区内容。
