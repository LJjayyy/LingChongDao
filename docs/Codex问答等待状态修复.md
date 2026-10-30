# Codex 问答等待状态修复

2026-10-27，Mac 应用 0.1.33（build 34）。沿用已安装的 Codex 插件 0.1.5，不新增 Hook、不更改信任或权限配置。

## 原因与行为

原适配只识别 Buddy / Claude 的 AskQuestion 类工具，Codex 的 `request_user_input` 和 `request_user_input_async` 被当作普通工具活动，因此需要用户回答时仍显示运行中。

现适配解析 `tool_input.questions`（同步工具使用 `question`，异步工具使用 `title`），把实际问题同步到「待回答」卡片，问题仍回 Codex 回答。同步请求由同一调用 ID 的 PostToolUse 结束。异步请求的工具返回 `accepted:true` 只代表问题已展示，不能结束等待；即使助手回合已停止，也继续保留未回答状态。提问工具报错、新的普通用户任务、会话结束或中断会清理对应等待。

异步答案从 UserPromptSubmit 中的 `<send_user_message_question_reply>` 结构读取，并按 `questionItemId` 中的工具名、调用 ID 和问题索引匹配。批量问题只答了一部分时继续等待；旧答案不会清除新的问题。答案包不再被当作任务标题。队列支持多个未回答调用，并在独立审批请求结束后恢复问题提示。

仅接入状态观察，`canAnswer` 保持 false。Hooks 不提供通用问答回传通道；官方 App Server 的 `item/tool/requestUserInput` 支持同步提问回复，但这不等于能通过当前插件回复任意已存在的桌面会话。

## 验证

- `bash scripts/verify-codex-questions.sh`：先在旧适配上复现失败（“Codex asking a question must show waiting, not running”），修复后通过。覆盖同步回答、异步 accepted 的对象/字符串形式、部分回答、跨回合回答、旧答案、其他工具活动、审批恢复、失败清理、来源隔离和标题处理。
- `bash scripts/verify.sh`：43 项通过。
- `bash scripts/verify-claude-approvals.sh`：13 项通过，含真实 helper/socket、并行审批、允许、拒绝、回来源处理、超时和取消。
- 构建时 Codex 插件 17 项离线验证通过。

本机 Codex CLI 为 ChatGPT.app 内置 `0.164.0-alpha.11.1`。验收启动独立的 ephemeral App Server，通过仅监听 `127.0.0.1` 的确定性 Responses 测试服务产生工具调用，不访问外部模型。使用本机现有插件与真实提问处理器，未读取已有聊天，也未替用户回答业务问题。

原生同步提问产生 `item/tool/requestUserInput`，旧版工作台显示「正在执行」，0.1.33 显示「等待回答」；通过测试客户端向该原生请求提交答案后，本轮正常结束。

原生异步提问产生真实 PreToolUse / PostToolUse，后者的 `tool_response` 为字符串 `"{\"accepted\":true}"`。助手回合结束后工作台仍显示「等待回答」；随后通过 App Server 的 turn/start 提交与桌面相同格式的答案包，工作台变为「本轮结束」，标题仍为「灵宠岛 Codex 本机待回答状态验收」。此项是原生 CLI、现有插件和真实 Mac 应用的联调；没有把模拟 Hook 输入冒充完整 Codex 桌面 UI 验收。

## 参考

- [官方 Hooks 协议](https://learn.chatgpt.com/docs/hooks)
- [官方 App Server 协议](https://learn.chatgpt.com/docs/app-server)
- [Codex 工具注册与 Hook 实现](https://github.com/openai/codex/blob/main/codex-rs/core/src/tools/registry.rs)
- [Codex 异步提问实现](https://github.com/openai/codex/blob/main/codex-rs/core/src/tools/handlers/request_user_input_async.rs)

通过 Context7 的 `/openai/codex` 核对工具/Hook 实现，并从本机 ChatGPT.app 静态资源确认异步答案包格式。
