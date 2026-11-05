# lingchongdao-dsh-hooks

灵宠岛的 DeepSeek Harness 活动上报与会话导航插件，以 **dsh 组合包（bundle）** 形式发布：`package.json` 声明 `dsh.bundle.patch`，`cordis.patch.yml` 作为一层插入观测行。它把 Harness 的生命周期与工具事件写成灵宠岛 helper 认识的 JSON，交给 `lingchongdao-hook` 上报；不参与模型或权限决策，也不依赖 Harness 的实验性 hook 桥接包。

## 挂载方式

灵宠岛把本目录复制到 `~/Library/Application Support/LingChongDao/dsh-plugin`，用应用自带的 `dsh plugin --profile desktop add <目录>` 登记为 profile 依赖（`link:`，离线），组合包会被选中到 `dsh.profile.bundles`。之后它出现在 DeepSeek Harness 的「插件 → 已安装插件」里，可自行开关或移除。

本插件不需要每份配置：`helperPath`、`socketPath` 与 `navigationSocketPath` 默认取自 `$HOME`（`Library/Application Support/LingChongDao/...`）。如需覆盖，在 profile patch 里用相同 `id` 写 `config` 即可。

## 上报内容

| Harness 扩展点 | 上报事件 | 主要字段 |
| --- | --- | --- |
| `agent/session-start` | `SessionStart` | `session_id`、`cwd`、`source` |
| `agent/pre-step`（仅真实用户消息） | `UserPromptSubmit` | `prompt` |
| `tools/pre-execute` | `PreToolUse` | `tool_name`、`tool_input`、`tool_use_id` |
| `tools/post-execute` | `PostToolUse` | 同上 + `tool_response` |
| `agent/turn-stopping` | `Stop` | `stop_hook_active` |
| `subagent/start` / `subagent/end` | `SubagentStart` / `SubagentStop` | `agent_id`、`agent_type` |
| 客户端前台查看已加载的主会话约 1 秒 | `SessionViewed` | `session_id`、`viewed_since`、`timestamp` |

helper 以 `--provider dsh` 启动，单次最长 1.5 秒；失败只写日志，不阻断会话。插件不需要额外 npm 依赖，因此安装离线可用。

`agent/session-start` 在启动阶段可能早于插件激活，插件会在同一会话的首个 prompt 补发一次 `SessionStart`，避免丢失会话开头。

## 精确返回会话

`client.js` 通过官方 `dsh.client` 机制加载；`navigation.js` 在 Host 注册本地导航桥。点击灵宠岛的 DSH 消息后，应用先唤起 DSH，再将原始 `session_id` 发送到 `~/Library/Application Support/LingChongDao/run/dsh-navigation.sock`。插件通过官方 `ctx.connection.fetch.register` 提供的同源、已鉴权且只允许 owner 的 `/api/lingchongdao/navigation` 路由，将请求交给客户端插件。

客户端使用官方 `ctx.uiWorkspace.openSession(sessionId)` 选择对话。仅在目标会话拥有独占的 `mainView` 引用、`openState === 'open'`，且主面板为 Conversation，并在 60 ms 后仍满足这些条件时回传 `opened`。这确认的是目标已选中并加载，不声称页面像素已经绘制。冷启动时会等待会话列表基线，不把暂未到达的合法会话立即判为不存在。

- Socket 协议：一条 JSONL 请求 `{ "version": 1, "requestId": "UUID", "sessionId": "原始 ID" }`，回执保留这三个字段，增加 `status: "opened" | "failed"`；失败可含 `reason`。
- 每次请求最长 4 秒；新请求取代旧请求，过期或身份不匹配的回执不会完成当前请求。Host 实例标识防止插件重载后被旧长轮询游标阻挡。
- Socket 目录为 `0700`，socket 为 `0600`；已有活跃 socket、非 socket 文件或其他用户的路径不会被覆盖。输入按字节设限，支持跨分包的 UTF-8 会话 ID。
- 客户端使用最长 20 秒的长轮询，空闲时不高频请求；失联退避，插件卸载会取消请求、关闭 listener 并结束待处理导航。
- 会话不存在、加载失败、桥未启动或插件版本不兼容时返回失败或超时；灵宠岛保留提醒并回退到打开应用。DSH 前台停留不会批量清除其他会话提醒。

## 手动查看同步

从 `0.4.0` 起，直接在 DSH 打开会话也能收起岛内对应的结束提醒。客户端每 100 ms 核对唯一 `mainView`、`openState === 'open'`、Conversation 面板、页面可见性和窗口焦点；持续满足约 1 秒后，通过同样受鉴权保护的 `/api/lingchongdao/attention` POST `{ "version": 1, "sessionId": "原始 ID", "viewedSince": 停留起点的Unix秒数 }`。Host 校验身份、大小和时间后交给 helper。

切换会话、失焦、隐藏、进入其他面板或加载失败会取消本次等待；持续查看会续报，投递失败会重新等待后重试。查看不发起导航，不读取聊天历史。岛仅将已存在的对应结束提醒标为本地已读，并保留其他会话、运行状态和交互请求；最新事件的来源时间或本机接收时间晚于停留起点时，须等待下一次确认。此同步受灵宠岛「返回来源应用后收起结束提示」开关控制。更新插件后须完全退出并重启 DSH。

已在 DeepSeek Harness `0.2.1-rc.5` 的隔离官方 Web runtime 验证客户端加载、官方路由鉴权和真实 A/B 会话切换。A/B 由官方 create/rename API 创建，是未调用模型的空白会话；页面标题证明会话身份切换，尚未实机验收已完成模型任务的对话历史显示。桌面壳使用同一客户端；真实用户 Desktop 配置不参与此验证。依赖上述官方扩展接口，其他版本需重新验证兼容性；导航桥不可用时灵宠岛保留提醒，不伪造 `dsh://` 会话深链。

本地回归：在仓库根目录运行 `node scripts/verify-dsh-plugin.mjs`。覆盖双任务、错误回执、请求取代、UTF-8 分包、加载失败、冷启动基线、Host 重载、手动查看、焦点与可见性、续报、投递失败及旧响应竞态；Unix socket 测试需要允许本地 socket。

## 注意

- 活动上报不注入上下文、不拦截工具、不回答权限；导航只切换客户端对话，不发送新提示或驱动模型。
- 每个事件都会新起一个 helper 进程；它只在本机与灵宠岛的 Unix socket 通信。
- 想停用：在灵宠岛「连接的应用 → DeepSeek Harness → 断开」，或到 DeepSeek Harness 的「插件 → 已安装插件」里关闭它；两种方式都只取消启用，保留依赖与插件副本，便于重连。彻底移除请在 dsh 插件页卸载。
