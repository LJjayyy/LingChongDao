# Codex 岛内审批

2026-10-28 更新：0.1.39 增加[自动审批兼容](Codex自动审批兼容.md)。下文的岛内审批仅适用于明确确认当前回合由用户审查的请求；自动模式或无法确认审查者时立即返回无决定，让 Codex 自身继续处理。

2026-10-28：应用 0.1.34（build 35），Codex 伴随插件 0.1.6。

## 接入方式

沿用官方 PermissionRequest Hook 的 `hookSpecificOutput.decision.behavior` 回传 `allow` / `deny`。不修改审批策略、不写入持久允许规则、不把普通 PreToolUse 当成审批请求。回来源处理、超时、断线、程序异常均返回空决定，让 Codex 使用自身审批流程。

Codex 原生 PermissionRequest 载荷没有 `tool_use_id`。旧实现要求该 ID，导致真实请求被降级为 permissionObserved，用户无法在岛上处理。本版由包内 helper 为每次 PermissionRequest 注入独立 UUID，并与当前 Unix socket 的传输请求 ID 绑定。应用核对两者后才建立等待；相同命令的并发请求使用不同连接，队列逐项展示和回复。未经过绑定的无 ID 事件仍只作观察，不能伪造可操作卡片。

简单 Bash 命令通过现有完整预览校验后支持「批准一次」。拒绝可用于原生权限请求；未知输入字段、复杂命令、文件变更和 MCP 调用不提供批准按钮，用户可回 Codex 核对。审批时显示待批准，不显示运行中；主动回来源后继续显示只读等待提示，来源继续执行或结束时清理。

## 验证

- `bash scripts/verify-codex-approvals.sh`：旧实现先复现“first request arrived”失败，修复后 14 项通过。使用真实 helper 和 Unix socket，覆盖官方无工具 ID 载荷、相同命令并发允许/拒绝、过期卡片重放、无持久权限修改、回来源、复杂输入拒绝、绑定 ID 不匹配、超时、来源取消和应用未运行。
- `bash scripts/verify-claude-approvals.sh`：13 项通过。
- `bash scripts/verify-codex-questions.sh`：通过。
- `bash scripts/verify-approval-observation.sh`：核心权限观察与 19 项 AppModel 检查通过。
- `bash scripts/verify.sh`：43 项通过。
- 构建时插件离线校验 17 项通过；新版已从本机一键更新入口安装，CLI 确认 0.1.6、installed=true、enabled=true。

原生联调使用 ChatGPT.app 内置 Codex CLI 0.164.0-alpha.11.1，以 ephemeral App Server 和仅监听回环地址的 Responses 测试服务产生真实 exec_command 审批。测试命令只写入临时目录标记，点击在真实灵宠岛完成；不调用外部模型、不读写业务聊天。

首次原生联调发现 Codex 报 `plugin contents changed; hook approval required`。用户已在 Codex 重新审查并允许新版插件，随后 Hook 正常运行。此确认由用户完成，没有修改信任文件或绕过审查。Codex App 本身在当前 Computer Use 工具的禁止操作列表内，因此原生 Codex 端使用内置 CLI/App Server 验收，岛内点击使用真实 Mac 应用。

原生端到端结果（均由岛上实际点击）：

| 操作 | Codex 原生结果 | 临时标记 | 是否出现来源审批 |
| --- | --- | --- | --- |
| 批准一次 | Hook completed，命令执行 | 已创建 | 否 |
| 拒绝 | Hook blocked，反馈为用户在灵宠岛拒绝 | 未创建 | 否 |
| 回 Codex 处理 | Hook completed，无决定；收到 commandExecution/requestApproval | 未创建 | 是 |

回来源时岛上保持“请在来源确认”的只读提示，没有误报运行中。验收客户端在收到来源审批后拒绝该测试操作，随后正常结束。早期界面定位耗时触发了 45 秒超时回退，未执行命令；后续使用就绪门控，在界面准备好后才启动原生回合，完成上述三条路径。

安装应用与构建产物的主程序 SHA-256 相同，Codex 实际缓存 helper 与应用捆绑插件中的 helper SHA-256 相同。应用签名会单独签署其主 helper，故不将该文件与插件副本的完整字节哈希作错误的等同要求。

## 官方依据

[官方 Hooks 文档](https://learn.chatgpt.com/docs/hooks) 定义 PermissionRequest 的输入字段与允许、拒绝、正常回退协议。通过 Context7 的 `/openai/codex` 核对 PermissionRequestCommandInput 和 Hook 输出解析；输入仅含会话、回合、工具、参数等字段，没有工具调用 ID。
