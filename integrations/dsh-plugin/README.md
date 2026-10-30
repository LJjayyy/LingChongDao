# lingchongdao-dsh-hooks

灵宠岛的 DeepSeek Harness 活动上报插件，以 **dsh 组合包（bundle）** 形式发布：`package.json` 声明 `dsh.bundle.patch`，`cordis.patch.yml` 作为一层插入观测行。它把 Harness 的生命周期与工具事件写成灵宠岛 helper 认识的 JSON，交给 `lingchongdao-hook` 上报；不参与任何决策，也不依赖 Harness 的实验性 hook 桥接包。

## 挂载方式

灵宠岛把本目录复制到 `~/Library/Application Support/LingChongDao/dsh-plugin`，用应用自带的 `dsh plugin --profile desktop add <目录>` 登记为 profile 依赖（`link:`，离线），组合包会被选中到 `dsh.profile.bundles`。之后它出现在 DeepSeek Harness 的「插件 → 已安装插件」里，可自行开关或移除。

本插件不需要每份配置：`helperPath` 与 `socketPath` 默认取自 `$HOME`（`Library/Application Support/LingChongDao/...`）。如需覆盖，在 profile patch 里用相同 `id` 写 `config` 即可。

## 上报内容

| Harness 扩展点 | 上报事件 | 主要字段 |
| --- | --- | --- |
| `agent/session-start` | `SessionStart` | `session_id`、`cwd`、`source` |
| `agent/pre-step`（仅真实用户消息） | `UserPromptSubmit` | `prompt` |
| `tools/pre-execute` | `PreToolUse` | `tool_name`、`tool_input`、`tool_use_id` |
| `tools/post-execute` | `PostToolUse` | 同上 + `tool_response` |
| `agent/turn-stopping` | `Stop` | `stop_hook_active` |
| `subagent/start` / `subagent/end` | `SubagentStart` / `SubagentStop` | `agent_id`、`agent_type` |

helper 以 `--provider dsh` 启动，单次最长 1.5 秒；失败只写日志，不阻断会话。插件不需要额外 npm 依赖，因此安装离线可用。

`agent/session-start` 在启动阶段可能早于插件激活，插件会在同一会话的首个 prompt 补发一次 `SessionStart`，避免丢失会话开头。

## 注意

- 仅观测：不注入上下文、不拦截工具、不回答权限。
- 每个事件都会新起一个 helper 进程；它只在本机与灵宠岛的 Unix socket 通信。
- 想停用：在灵宠岛「连接的应用 → DeepSeek Harness → 断开」，或到 DeepSeek Harness 的「插件 → 已安装插件」里关闭它；两种方式都只取消启用，保留依赖与插件副本，便于重连。彻底移除请在 dsh 插件页卸载。
