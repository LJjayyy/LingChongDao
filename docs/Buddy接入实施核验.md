# Buddy 接入实施核验

核验时间：2026-10-24。本文是《CodeBuddy-CN与WorkBuddy接入调研》的实施补充。仅查官方文档与本机安装资源；没有读取用户会话数据库、转录、凭据，也没有运行真实 AI 任务或触发审批。

## 配置契约

| 产品 | 本机身份 | 默认配置文件 | 核验结论 |
| --- | --- | --- | --- |
| CodeBuddy CN IDE 4.12.2 | `com.tencent.codebuddycn` | `~/.codebuddy/settings.json` | 官方 IDE 文档及本机扩展均加载用户级外部命令 Hooks |
| WorkBuddy 5.8.3 | `com.tencent.workbuddy.mac` | `~/.workbuddy/settings.json` | GUI 把产品配置目录传入 lite 引擎；引擎实际读取顶层 `hooks` 并执行 command |
| WorkBuddy AI 5.8.4 | `com.workbuddy.workbuddy-ai` | `~/.workbuddy-ai/settings.json` | 随包产品配置 `dataFolderName` 与 `config.customUserDataDir` 都是 `.workbuddy-ai`；不能误写普通 WorkBuddy home |

默认目录可能被环境变量或产品定制覆盖。不要据共享 CodeBuddy 协议家族猜测来源应用。当前实施只为 CodeBuddy CN 与普通 WorkBuddy 安装用户级配置；WorkBuddy AI 可识别来源与图标，不自动修改其配置。

两种目标配置的共同形状如下（说明示例，不是已安装的可执行脚本）：

```json
{
  "hooks": {
    "UserPromptSubmit": [
      {
        "matcher": "*",
        "hooks": [
          { "type": "command", "command": "/absolute/path/to/adapter", "timeout": 3 }
        ]
      }
    ]
  }
}
```

`timeout` 单位为秒；命令应快速完成，岛未运行时退出成功，不注入 `allow` 或 `deny`。安装和卸载只合并/移除灵宠岛自己的 command，保留其他设置、其他事件与同事件中其他 Hooks。

### CodeBuddy CN 的证据

[官方 IDE Hooks](https://www.codebuddy.cn/docs/ide/Features/Hooks) 列出的 7 事件是 `SessionStart`、`SessionEnd`、`PreToolUse`、`PostToolUse`、`UserPromptSubmit`、`Stop`、`PreCompact`；其 JSON 示例明确是 `hooks.Event[].hooks[]`，内层 `type=command`、`command`、`timeout`。本次通过 Context7 `library CodeBuddy` → `/websites/codebuddy_cn` → `docs` 再次取得该官方页面内容。不要把 CLI 文档的更多事件当作 IDE 已验证合同。

本机 `/Applications/CodeBuddy CN.app/Contents/Resources/app/extensions/genie/out/extension/index.js`：

- `loadUserConfig()` 拼接 `homedir() + USER_DATA_DIR_NAME + settings.json` 后解析 JSON；`getUserSettingsPath()` 返回同路径。
- `UserPromptSubmit` 构造 `session_id:this.sessionId`、`generation_id:agent.requestId`、`prompt`、`cwd`、`hook_event_name`；`generation_id` 是轮次，不能当审批唯一请求 ID。
- shell Hook 执行器默认 60,000 ms；内层配置 timeout 转换为毫秒。stdin 接收事件 JSON。
- 项目级配置存在，用户级安装不保证每个项目的最终有效配置；卡片必须等待实际事件才能显示接入成功。

### WorkBuddy GUI → lite 引擎加载链

本机公开资源 `/Applications/WorkBuddy.app/Contents/Resources/app.asar`：

1. `main/workbuddy-product-config.js` 的 `resolveWorkbuddyConfigDir()` 按 `WORKBUDDY_CONFIG_DIR` → `CODEBUDDY_CONFIG_DIR` → `homedir()+产品 dataFolderName` 解析。普通产品的 `cli/product.json` 为 `.workbuddy`。
2. `main/app-instance.js` 的 `configureElectronApp()` 获取 `workbuddy-paths` 的配置目录后，同时赋值 `process.env.CODEBUDDY_CONFIG_DIR` 与 `process.env.WORKBUDDY_CONFIG_DIR`。
3. `main/node.js` 的 CLI launch-spec 组装环境并传给子进程；`settingSources` 仅在任务要求指定时拼成 `--setting-sources` 参数，空数组为 `none`。不应由灵宠岛改写信任策略。
4. 随包 `app.asar.unpacked/cli/dist/codebuddy-lite-wb.mjs`：`PathUtils.getSettingsFilePath(USER)` 使用 `getHomeDir()` 下 settings 文件；`HookManager.getHooks(event)` 先 `await settingsManager.get("hooks")`，追加该事件的配置，再追加插件/scoped Hooks。
5. 同一 HookManager 的 `findMatchingHooks` 读取组级 `matcher` 与 `hooks`，`executeLocalHook` 的 command 分支调用 `executeCommandHook`，再 `hookExecutor.execute(command,input,{timeout:timeout*1000,...})`。因此外部 settings.json command Hooks 的加载与执行链有静态证据，并非只看见内置插件。
6. 同一引擎的 `CliSettingSourcesProvider` 默认 `[USER, PROJECT, PROJECT_LOCAL]`。工作区信任或会话模式可收紧 settings sources；不能承诺所有模式都触发。应显示“已安装，待验证”，并提示新会话验证，必要时重启来源应用。

WorkBuddy AI 对应的产品 JSON 明确 `.workbuddy-ai`，其 `main/node.js` 与普通版 hash 相同，但不要因此把两个配置入口合并。

## 已有 WorkBuddy 任务跳转

**本机普通版存在专用已有任务路由：`workbuddy://chat/<任务 ID>`。** 它没有预填提示词、执行命令或新建任务的副作用。必须把 URL 投递给准确的 `com.tencent.workbuddy.mac` 应用，不能依赖默认 scheme handler。

静态路由链：

- `renderer/assets/main-D5X_fMjo.js` 的 `tryHandleScheduledTaskArtifactDeepLink()` 先构造 `workbuddy://chat/${encodeURIComponent(id)}` 并调用已有会话入口；artifact 参数可以不存在，不需要人为附加。
- `renderer/assets/msg-center-popup-utils-BKrQ7-kV.js` 的 `resolveDeepLinkFromUrl()` 对 `host=chat` 且非空 pathname，直接令 `resolvedPath=/task/<ID>`、`pendingTaskId=<ID>`。
- OS `open-url` 经过主进程缓冲/renderer ready 管道发送给 renderer；`handleDesktopOpenUrl()` 将已知业务 host 交给 pending store，后续解析以上已有任务路由。

任务 ID 与 Hook `session_id` 的本地根会话对应链：

- `main/node.js` 的 `LocalConversationsImpl` 用 GUI 会话记录创建 runtime options：`{id:e.id, sessionId:e.id, ...}`，这里 `e.id` 是 GUI 会话/任务 ID。
- `main/server.js` 的 `acquireLocalHttpRuntimeByColdStart()` 以 `n.conversationId` 构造 `buildColdStartArgs`；生成参数包含 `--serve --session-id <conversationId>`。预热 `activate` 也使用 `sessionId:n.conversationId`。
- lite 的 `SessionHookManager` 在 `SessionStart`、`UserPromptSubmit`、`Stop` 等载荷中使用 `resolveHookSessionId(session)`；该函数返回 `session.meta?.parentSessionId ?? session.id`。根会话对应上述 GUI ID；子代理归属父会话。

因此可对 **localhost 且可信来源识别为 WorkBuddy 桌面端** 的事件，使用 `session_id` 构建已有任务 URL。建议仅接受非空且长度受限的 ASCII 安全 token（字母、数字、下划线、连字符），不接受 slash/query/fragment 或输入的任意完整 URL。未知 CLI、远程会话、WorkBuddy AI 不可静默套普通 WorkBuddy scheme。

不要使用 `workbuddy://task?action=start&prompt=...`：该路由进入新任务/输入预填管道，不是已有任务定位。不要使用通用 execute-command。

以上是随包静态调用链证明；仍应把 OS URL 投递成功与来源实际选中任务区分，不能说已验证跳到具体消息锚点。CodeBuddy CN IDE 的已有会话专用路由本次未确认，首版回到正确来源应用或已验证项目窗口。

## 无副作用验证建议

1. 用 synthetic JSON 直接调用灵宠岛 adapter/helper，测试 start → tool → Stop → SessionEnd 与 socket 断线，不运行来源应用的真实任务，不读取 transcript_path。
2. 用临时 settings fixture 测安装、重复安装、卸载、保留未知设置、保留其他 Hooks；不依赖真实用户设置作为测试样本。
3. 用注入的 application resolver / destination delivery closures 测 bundle 精确选择、ID 校验、远程与未知来源回退；不真的发任意 deeplink。
4. 如果验证真实 GUI：可只点来源已经存在的任务，并从灵宠岛点“打开会话”观察选中任务；不要发送新提示词、执行工具或点击权限批准。真实 Hook 生效需之后由用户新会话活动确认。

官方补充：[WorkBuddy 插件系统](https://www.workbuddy.cn/docs/workbuddy/Plugins)、[WorkBuddy 设置](https://www.codebuddy.cn/docs/workbuddy/From-Beginner-to-Expert-Guide/Function-Description/Setting)、[CLI Hooks 参考](https://www.codebuddy.cn/docs/cli/hooks)。本次 Context7 WorkBuddy 索引 `/websites/codebuddy_cn_workbuddy` 返回的官方设置段落未明确列 Hooks；外部 command 支持结论来自上述本机实际引擎链，边界如实保留。
