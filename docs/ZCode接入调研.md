# ZCode 接入调研

结论：ZCode 支持 Hook 接入，现已改成 **ZCode 原生插件**（本地插件市场 + `.zcode-plugin` 包）接入，会出现在 ZCode 的「插件管理 → 已安装」里，可开关/卸载。同步会话开始、用户提问、工具开始/结果、工具失败、本轮结束，并可在岛内处理简单的 Bash 权限请求；不支持从岛内定位具体会话。

## 证据来源

- 本机 `ZCode.app` 3.16.3，Bundle ID `dev.zcode.app`，单一下载包内含 CLI（`Contents/Resources/glm/zcode.cjs`，`zcode --version` 为 0.17.0）。
- 官方文档：https://zcode.z.ai/cn/docs/hooks （事件与输入输出契约）。
- 应用内置说明：`skills/diagnosing-hooks/SKILL.md`、`diagnosing-plugins/SKILL.md`、`zcode-configuration-guide/SKILL.md`（配置/插件合并规则、故障定位）。
- 插件机制：清单 `.zcode-plugin/plugin.json`（`name`、可选 `version`/`description`/`hooks`），插件 Hook 会**自动开启 Hook 运行器**，不需要 `hooks.enabled`；`${ZCODE_PLUGIN_ROOT}` / `${CLAUDE_PLUGIN_ROOT}` 会在运行前替换。
- 插件 CLI：`plugins list|install|uninstall|enable|disable|marketplace add|update|remove`；本地目录 marketplace 会被复制到 `~/.zcode/cli/plugins/marketplaces/<name>`，插件缓存到 `plugins/cache/<marketplace>/<plugin>/<version>`，启用态写在 `cli/config.json` 的 `plugins.enabledPlugins`。
- CLI 内 Zod schema：`hooks` 对象为 `{ enabled?, timeoutMs?, maxOutputBytes?, events? }`，`events.<Event>` 为 `[{ matcher?, hooks: [...] }]`。

## 接入契约

- 事件仅七个：`SessionStart`、`UserPromptSubmit`、`PreToolUse`、`PermissionRequest`、`PostToolUse`、`PostToolUseFailure`、`Stop`。`SessionEnd`、子任务与 `Notification` 不在契约内，灵宠岛不会写入。
- 插件与配置 Hook 共用同一套事件：`matcher` 为大小写敏感正则，省略即匹配全部；`type: "command"` 支持 `command`、`timeout`（秒）、`statusMessage`。
- 输入为一行 JSON，Claude Code 兼容字段与 camelCase 同时提供：`hook_event_name`、`session_id`、`cwd`、`tool_name`、`tool_input`、`tool_use_id`、`transcript_path`。`PermissionRequest` 额外带 `permission_suggestions`。
- 输出：`{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"|"deny","message":"…"}}}`。显式 deny 规则、Plan 模式写入禁令和工具硬限制不会被 `allow` 绕过。
- 项目级 `<repo>/.zcode/config.json` / `zcode.json` 中的 `hooks` 当前会被整体忽略（日志记为 `config_project_hooks_ignored`），因此插件与 Hook 都只用用户级。
- 每个 session 启动时会取配置与插件快照，改完插件后需要新建会话（刚安装建议重启 ZCode）。

## 已实现的接入方式

插件包在 [`integrations/zcode-plugin`](../integrations/zcode-plugin)：一个本地插件市场（`marketplace.json`）＋ `plugins/lingchongdao-zcode`（`.zcode-plugin/plugin.json` + `hooks/hooks.json` + `scripts/forward-hook.sh` + `icon.png`）。Hook 命令是静态的，脚本从 `$HOME` 解析 helper 与 socket，灵宠岛没运行时直接返回 `{}`，不阻断 ZCode。

图标与名称：ZCode 列表读市场条目的 `icon` / `displayName`；本地市场默认不带图标，安装时会 把包内 `icon.png` 编码成 data URL 写入复制后的 `marketplace.json`（幂等），展示名为「灵宠岛」。

安装（[ZcodeConnectionService.swift](../Sources/LingChongDao/Connections/ZcodeConnectionService.swift)）：

1. helper 复制到 `~/Library/Application Support/LingChongDao/bin/lingchongdao-hook`；
2. 插件市场复制到 `~/Library/Application Support/LingChongDao/zcode-plugin/`；
3. 用 ZCode 自带 CLI（Electron 以 Node 模式运行 `zcode.cjs`）删除旧记录 → `plugins marketplace add <目录> --scope user` → `plugins install lingchongdao-zcode@lingchongdao-local -s user`；
4. 清理旧版写进 `cli/config.json` 的灵宠岛命令与 `hooks.enabled` 覆盖，避免重复上报。

连接状态同时校验：插件缓存、`plugins.enabledPlugins`、helper 指纹、以及是否还残留旧配置 Hook。卸载会 `plugins uninstall` + `marketplace remove` 并删除本地副本。灵宠岛卡片与 Codex 一致：一键安装/修复、卸载插件、打开 ZCode、手动导出插件包。

## 真机验证

- 临时插件市场里用探针 Hook 实测：`SessionStart`、`UserPromptSubmit`、`PreToolUse`、`PostToolUse`、`Stop` 均触发，含 `session_id`、`cwd`、`tool_name`、`tool_input`；`${ZCODE_PLUGIN_ROOT}` 替换在插件 Hook 中生效。
- 正式插件包 `plugins validate` 通过；安装后 `plugins list --json` 显示 7 个事件、全部 `runnable`、7 条状态文案；`forward-hook.sh` 手动投递返回 `{}` 且退出 0，缺 helper 时仍 `{}`（fail-open）。
- 无界面模式下权限请求被 CLI 直接放行，`PermissionRequest` 未触发；该事件与配置 Hook 同一个 schema/输出契约，需桌面端人工点一次审批再确认。
- 回归：`./scripts/verify.sh` 39 项、`./scripts/verify-origins.sh` 78 项、应用路由与导航/状态/来源同步验证全部通过（新增插件缓存/启用态检测用例）。

## 边界

- 桌面端审批 UI 尚未由开发过程实测：安装后请在 ZCode 里新建会话，触发一次需要确认的 Bash 命令，确认岛内批准/拒绝能回传。
- 未读取 ZCode 的宠物素材，卡片显示官方应用图标。
- 无会话深链；即使 hook 带了 `sess_…` 会话 ID，也只打开应用。
- ZCode 会**复制**插件市场快照，所以更新插件必须先 `marketplace remove` 再 `add`（安装流程已处理）；插件在会话启动时取快照，安装/更新后请重启 ZCode。
- ZCode 升级可能调整插件或 Hook 契约，升级后先「检查连接」再验证。

## 2026-10-25 补充：点击定位的可达精度

对 ZCode 3.16.3（`dev.zcode.app`）程序包的只读静态分析确认，外部 `zcode://` scheme 的全部路由只有四条，主进程 `open-url` → 深链分发器的完整判断：

- `zcode://workspace/open?path=<本地目录>` — 打开文件夹为工作区；每次都先弹 ZCode 自家确认框（「打开外部 ZCode 链接？」），确认后才校验路径并投递给主窗口，renderer 在支持的模式下打开该目录（远程路径、不存在目录被拒）。
- `zcode://payment/callback`、`zcode://share/import?code=…`、`zcode://oauth/callback?state=…` — 支付、分享导入与登录回调。

**没有会话/任务级路由。** renderer 内确有按 taskId 聚焦工作区与任务的通道（`TaskNotificationClick`、`FocusTab`、`ActivateOrSetWorkspace`），但均为主进程与 renderer 之间的内部 IPC，触发源是系统通知点击等内部事件，外部 URL 无法到达。

基于以上结论，灵宠岛曾把 ZCode 点击做到「项目工作区」级：会话 `cwd` 为真实本地目录时构造 `zcode://workspace/open?path=<cwd>`（明确指定 `dev.zcode.app`），点击先弹 ZCode 确认框再打开该目录。

**2026-10-25 回退：** 实装后用户反馈体验差——每次点击都弹「打开外部 ZCode 链接？」确认框，为工作区级精度付一次额外点击不划算。已移除该路由：ZCode 会话点击一律「打开应用」（激活 `dev.zcode.app`），验证用例改为断言任何 cwd/来源都不得产生 ZCode 深链，防止回归。若 ZCode 日后提供免确认的会话级深链，再重新接入。

## 2026-10-25 补充二：守护模式危险命令审批不触发 Hook（实测根因）

用户实测：ZCode 桌面端弹出「需要权限 Dangerous command requires your approval」等待确认时，岛上该会话仍显示「运行中」，没有任何待批准提示。排查结论：这是 ZCode 的**有意设计**，不是灵宠岛的接收故障。

证据链（只读诊断 + 一次合成探针，未修改 ZCode 配置）：

1. 接收端正常：用已装插件的原始命令手动注入合成 `PermissionRequest`（带 `tool_use_id`），helper 阻塞等待岛上决定直至超时——岛把该事件识别为活审批卡，管道完好。
2. 插件 7 个 Hook 在桌面启动时全部解析成功（bootstrap 日志 `hookCount: 7`），但当日桌面日志**没有任何 Hook 执行事件**。
3. `glm/zcode.cjs`（Hook 执行器，Claude Code 系架构）中的权限流程：
   - 守护模式命中安全规则的危险命令走 `ask(...)` 且固定附加 `approvalMode: "user-once"`，其提示文案与用户截图完全一致（"Dangerous command requires your approval for this execution"）。
   - 权限请求时 Hook 派发闸门为 `runHooks: x && R.approvalMode !== "user-once"` —— **user-once 审批不派发 `PermissionRequest` Hook**。设计意图明确：一次性危险批准必须由真人决定，防止 Hook 自动放行。
   - 其余 ask 路径（如 always-ask 规则）不带 user-once，Hook 正常派发，岛可收到。
   - `PreToolUse` 在权限通过之后才触发，因此等待审批期间岛上连对应工具行都不会出现（与截图一致：岛停在上一条工具活动）。
4. 内部的 `permission_requested` 事件与任务聚焦通道均为主进程/renderer 或 app-server 内部 IPC，插件与外部进程不可达；会话存储轮询涉及读取聊天内容，本应用不采用。

结论与边界：ZCode 危险命令的「仅允许这一次」确认**无法**经 Hook 通道到达灵宠岛，只能在 ZCode 内完成；这类任务在岛上表现为持续「运行中」直到审批结束、工具真正开始。连接卡片与 README 的能力描述已限定此边界。若 ZCode 日后为 user-once 审批提供 Hook 或插件事件，应第一时间接入。

## 2026-10-25 补充三：点开历史任务重复弹岛的根因与修复

用户实测：在 ZCode 里点开**已经结束且查看过**的任务，岛上又弹出新的「运行中」卡片（标题回落为工作区目录名、详情回落为事件名，即「灵宠岛 / SessionStart」）。

根因（对 ZCode 3.16.3 `zcode.cjs` 只读静态分析确认）：ZCode 派发 SessionStart 有两个调用点——新会话首轮上下文初始化走 `runSessionStartHooks("startup",…)`，**恢复历史会话（重建 transcript 上下文）走 `runSessionStartHooks("resume",…)`**。桌面端点开任何历史任务（哪怕只是查看）都会实例化恢复会话并立即派发 `SessionStart`，载荷含 `source: "startup"|"resume"`（另有 `cwd`、`session_id`、`turnId`、`timestamp`）。灵宠岛此前把 SessionStart 无差别归一为 `.started`，`source` 字段被忽略，Reducer 对 `.started` 无条件置 running——已结束的任务被「复活」上岛；且 hook 通道不存在「用户已看过」状态，无法区分新任务与回看。

修复（island 核心，非 ZCode 定制分支）：

- `HookNormalizer`：SessionStart 读取 `source` 字段，`source == "resume"` 归一为新事件种类 `.sessionResumed`；缺失或 `startup`（以及其余全部来源）维持 `.started`，老载荷行为不变。
- `SessionReducer`：`.sessionResumed` 只刷新身份元数据（cwd/标题/turn），**不改相位、不置未读、不用裸事件名覆盖最后一条真实 detail**——结束的会话保持下岛状态；真实工作经 `UserPromptSubmit`（`.started`）与工具事件照常上岛，无遗漏。

验证：`./scripts/verify.sh` 40 项通过（新增「resume 不复活、真实工作仍上岛」用例）；17 个专项验证脚本全部通过；`swift build` 全目标编译通过。XCTest 套件同步补了 `testResumedSessionStartDoesNotResurrectEndedTask`（本机仅有 Command Line Tools 无 XCTest 模块，该套件需完整 Xcode 环境执行）。

## 2026-10-25 补充四：prompt 标题取数按来源拆分（PromptTitlePolicy）

用户反馈卡片标题显示 `<in-app-browser-context source="am…`，而 Codex 同类会话是干净的提问，怀疑取数不一致。核实结论：岛的提取链路从未按来源分支，差异来自**输入**——ZCode 桌面端在内置浏览器面板打开时会自动把 ambient UI 状态块注入 prompt 头部（`zcode.cjs` 原文：`<in-app-browser-context source="ambient-ui-state">` + "This block is automatically supplied ambient UI state, not part of the user's request."），hook 载荷的 `prompt` 带着这块原样到达，标题取 prompt 开头即被 XML 标签抢占；ChatGPT.app（Codex 桌面端）全量资源扫描无此类注入，其 prompt 只可能带 `# Files mentioned by the user:` 附件包装（已有剥离规则）。

应「各来源逻辑互不影响」的要求，标题取数重构为按来源的独立策略 [PromptTitlePolicy](../Sources/IslandCore/PromptTitlePolicy.swift)：

- `.zcodeDesktop`：剥离 prompt 头部成对的 `<in-app-browser-context …>…</in-app-browser-context>` 块（仅锚定开头、可重复）；未闭合的块**不**剥离，宁可保留标签也不吞掉真实提问。ZCode 载荷确认不含附件包装（`zcode.cjs` 零命中），故此分支不引入该规则。
- `.codexDesktop`：原 `SessionTitle.promptText` 的附件包装规则（`## My request:` 提取、尾部 `<image>` 标记截断），行为不变。
- `.plain`：Qoder / DeepSeek Harness / Buddy / 未知来源，原样规整。新增来源默认落此档。

用例断言「规则互不渗透」：同一段 ambient prompt 在 ZCode 下取到真实提问、在 Qoder 下保持原样；Codex 包装规则只作用于 Codex。`./scripts/verify.sh` 41 项通过，17 个专项脚本与全目标编译通过。XCTest 镜像 `testPerSourcePromptTitlePoliciesStayIsolated`。
