# CodeBuddy 原生审批状态同步结论

记录日期：2026-10-30（Asia/Shanghai）。状态：**暂不实施，等待官方能力更新后重新核验。**

## 决策与范围

审批保留在 CodeBuddy 原生界面，灵宠岛只同步真实状态；不做岛内审批。当前保持已有生命周期接入，不新增猜测式待批判断，不修改权限策略。

本结论针对 macOS CodeBuddy CN **4.12.2 / Craft**，测试时模型选择器为 Auto。实际工具载荷包含 `client=CodeBuddyIDE`、`agent_type=craft`、`version=4.12.2`，终端工具名为 `Bash`。不是另起 CLI 会话的测试结果，也不代表所有未来版本。

## 实机基线

在独立临时项目中注册官方 IDE 文档的七种 Hook：`SessionStart`、`SessionEnd`、`PreToolUse`、`PostToolUse`、`UserPromptSubmit`、`Stop`、`PreCompact`。普通观察组返回 `{}`；ask 组只对无害测试命令返回官方 `permissionDecision: ask`，所有审批均在 CodeBuddy 完成。

共完成五组试验、记录 23 条真实 Hook 输入。原生危险命令测试仅操作本次创建的空目录，没有修改用户项目。

| 场景 | 2026-10-30 实测结果 | 对状态同步的影响 |
|---|---|---|
| 普通命令，仅观察 | 输入 `requires_approval=true`，本次未点击批准即直接执行 | 该字段不能唯一确定是否正在等用户 |
| 原生危险命令确认，仅观察 | 确认框已出现时，目标终端命令没有 PreToolUse；点运行后约 0.28 秒才收到它 | 不能用该事件识别原生等待的开始 |
| 官方 ask 后批准 | 确认能正常出现；点运行后没有第二次 PreToolUse；命令执行约 20.01 秒，批准约 21.69 秒后才收到 PostToolUse | 返回 ask 可以发起确认，但缺少及时解除待批、恢复执行的信号 |
| 官方 ask 后拒绝 | 命令未执行；序列为 UserPromptSubmit → PreToolUse → Stop，约 7.17 秒后 Stop | 没有独立拒绝结果事件，Stop 只说明本轮停止 |
| 官方 ask 后跳过 | 命令未执行；序列同拒绝，约 6.12 秒后 Stop | 无法从这组事件精确区分用户选择 |

上述秒数是当次观测值，不是协议延迟保证。测试命令的 start/end 标记和原生界面只用于核对真值，不是产品接入方案。

**结论：这套已公开的官方 IDE Hook，不能保证原生“待确认 ↔ 运行中”状态完整、及时地一致。** 不用命令耗时、危险命令关键词或界面抓取补足缺失信号。`ask` 是 Hook 发给 CodeBuddy 的决策输出，不能当成 CodeBuddy 发来的原生等待通知。

## 官方更新后如何复查

先确认新增能力明确覆盖 **CodeBuddy CN IDE / Craft** 及目标版本；不能仅因为 CLI 支持 `PermissionRequest` 或 `Notification` 就套用于 IDE。事件名称不必固定，重点是官方契约和实际覆盖范围。

| 需要补齐的能力 | 复查通过标准 |
|---|---|
| 原生等待开始 | 原生确认出现时，官方入口能明确通知外部，且不把普通工具准备或模型思考误标为待批 |
| 批准后恢复 | 用户点运行后能及时更新；长命令执行期间不再保留待批准，不必等 PostToolUse |
| 拒绝、跳过和取消 | 对应等待能够明确收口，不把这些操作误判为工具执行成功 |
| 稳定关联 | 能对应正确会话及请求；并发、重复调用、乱序和迟到事件不串状态 |
| 原生流程保持 | 审批继续在 CodeBuddy，不强制新增确认，不替代或绕过原生权限判断 |

复测至少对比本次五组基线，再补取消、并发和重启等边界。只有官方支持与实机结果均通过，才重新考虑实现；仅有版本升级或 ask 相关修复不足以自动推翻本结论。

## 官方资料与记录保留

- [IDE Hooks](https://www.codebuddy.cn/docs/ide/Features/Hooks)：七项事件、stdin/stdout、工具前决策及超时契约。
- [IDE 发布记录](https://www.codebuddy.cn/docs/ide/release-notes/release-notes)：复查新版本是否明确补齐 IDE 的等待或恢复事件。
- [CLI Hooks](https://www.codebuddy.cn/docs/cli/hooks)、[CLI 插件事件表](https://www.codebuddy.cn/docs/cli/plugins-reference)：仅用于识别产品能力差异，不能代替 IDE 支持声明。

依据为当日官方资料和实际试验。本次不实施，生产逻辑、全局 Hook 及既有项目配置没有改动。按用户要求仅保留本结论与复查基线；过程方案、原始日志、回放脚本、配置副本和临时测试目录已清理。CodeBuddy 中的测试会话、最近打开项及该临时目录的信任记录也已移除。后续更新需重新采样验证。
