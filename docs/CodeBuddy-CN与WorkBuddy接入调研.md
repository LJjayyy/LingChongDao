# CodeBuddy CN 与 WorkBuddy 接入调研

查询日期：2026-10-24（Asia/Shanghai）。对象为 macOS「灵宠岛」、CodeBuddy CN IDE、CodeBuddy Code CLI，以及腾讯桌面 AI 办公产品 WorkBuddy。本文仅调研；未安装接入、修改源应用配置、触发真实 Hook 或审批，也未读取用户聊天、数据库或凭据。

证据标记：**[官方]** 为产品官方文档声明；**[本机]** 为当前安装包或类型声明的只读静态证据；**[建议]** 为工程推断；**[未实测]** 表示尚无端到端验证。文档未列出的能力记为“未证实”，不据此断言不支持。

## 结论

**可以接入，优先做生命周期状态与打开来源应用；审批按钮、精确会话跳转和官方宠物同步暂不进入首版承诺。** CodeBuddy CN IDE 有独立官方 Hook 文档，WorkBuddy 也明确支持 Hook 插件，本机 WorkBuddy 包内还有 Hook 资源和执行引擎，因此没有必要从聊天数据库或界面抓取状态。但三条产品线的事件数量、配置行为与运行入口不同，不能把 CLI 的完整能力直接套给桌面端。[官方：IDE Hooks](https://www.codebuddy.cn/docs/ide/Features/Hooks)、[WorkBuddy 插件系统](https://www.workbuddy.cn/docs/workbuddy/Plugins)

| 能力 | CodeBuddy CN IDE | CodeBuddy Code CLI | WorkBuddy 桌面办公版 |
|---|---|---|---|
| 生命周期 Hook | **[官方]** 列 7 事件 | **[官方]** 在线文档列 27+；**[本机]** 安装版类型列 15，存在版本差异 | **[官方]** 声明 Hook 插件；**[本机]** 内置插件与 lite 引擎有处理链 |
| 会话标识 | **[官方]** `session_id`，以 `conversationId` 跟踪新会话 | **[官方]** `session_id`；可选 `generation_id` 代表轮次而非审批请求 | **[本机]** 继承 CodeBuddy 风格引擎；与桌面任务 ID 的实际对应未实测 |
| 配置 | **[官方]** 用户及项目 `.codebuddy/settings.json`，项目覆盖用户 | **[官方]** 用户/项目/项目本地配置；Hooks 跨作用域合并 | **[官方]** 兼容用户级 `.codebuddy`，明列规则/技能/命令/MCP；**[本机]** WorkBuddy.app GUI 默认配置 home 为 `~/.workbuddy`，另见下文 |
| `PermissionRequest` | 独立 IDE 文档未列；未证实 | **[官方/本机]** 事件存在；外部 Hook 的完整回传与请求关联仍需验证 | Hook 插件已证实，桌面端该事件及其回传契约未实测 |
| 一键分发 | IDE Skills 已声明；CLI 插件格式能否原样直装 IDE 未证实 | **[官方]** 插件可携带整个会话作用域的 Hooks | **[官方]** 插件安装及第三方市场；CLI 插件跨产品原样直装未实测 |
| 来源打开 | **[本机]** bundle 与 URL scheme 已登记 | CLI 应返回实际终端/宿主，不能强认 IDE | **[本机]** 两个不同 bundle/scheme，须分别识别 |
| 官方宠物读取 | 在本次查阅资料中未找到公开契约 | 同左 | 同左；Buddy 应用、用户头像与宠物资源不是同一概念 |

## 官方接入契约与边界

### CodeBuddy CN：IDE 与 CLI 分开适配

**[官方]** IDE 的 7 事件是 `SessionStart`、`SessionEnd`、`PreToolUse`、`PostToolUse`、`UserPromptSubmit`、`Stop`、`PreCompact`。Hook 通过 stdin 接收 JSON、stdout 返回 JSON；公共字段包括 `session_id`、`transcript_path`、`cwd`、`hook_event_name`。工具事件带 `tool_name`、`tool_input`，执行后带 `tool_response`。IDE 的真实工具名可能为 `execute_command` / `write_to_file`，即使 matcher 支持与 CLI 的 `Bash` / `Write` 双向别名，脚本仍须归一化输入。[IDE Hooks](https://www.codebuddy.cn/docs/ide/Features/Hooks)

**[官方]** CLI 在线参考针对 CodeBuddy Code v1.16.0+，标注 Beta。配置入口为 `~/.codebuddy/settings.json`、项目 `.codebuddy/settings.json` 和 `.codebuddy/settings.local.json`；跨作用域 Hooks 合并并行执行。外部文件修改需要在 `/hooks` 面板审核后生效。默认执行超时为 60 秒，可逐命令设置。IDE 文档则写项目配置覆盖用户配置，不能复用一个未区分产品的合并策略。[CLI Hooks 参考](https://www.codebuddy.cn/docs/cli/hooks)、[Hooks 入门](https://www.codebuddy.cn/docs/cli/hooks-guide)

**[官方]** `PreToolUse` 的 `hookSpecificOutput.permissionDecision` 支持 `allow` / `deny` / `ask`；其中 `allow` 会绕过权限系统直接执行，`ask` 回到源端 UI 确认。它是工具执行前的决策接口，不能等同“已经出现的 `PermissionRequest` 对话框可由灵宠岛安全代答”。本次所读 CLI 事件表列出 `PermissionRequest`，但参考正文没有足够的该事件输入、输出和并发请求对应示例。[CLI Hooks 决策控制](https://www.codebuddy.cn/docs/cli/hooks#pretooluse-%E5%86%B3%E7%AD%96%E6%8E%A7%E5%88%B6)、[插件事件表](https://www.codebuddy.cn/docs/cli/plugins-reference#_3-hooks-%E9%92%A9%E5%AD%90)

**[官方]** CLI 插件可用 `.codebuddy-plugin/plugin.json` 和 `hooks/hooks.json` 打包，脚本路径可引用 `${CODEBUDDY_PLUGIN_ROOT}`；插件 Hooks 在启用时作用于整个会话。相较之下，Skill frontmatter Hooks 仅对 `context: fork` 的子代理生命周期生效，且非内置来源默认受 `allowUntrustedFrontmatterHooks` 闸门限制。因此“安装一个普通 Skill”不足以保证全局生命周期常驻接入；CLI 首选专用 Hook 插件。IDE Skills 文档只证明可打包指令/脚本，不证明其可直接安装 CLI 插件。[创建插件](https://www.codebuddy.cn/docs/cli/plugins)、[插件 API 参考](https://www.codebuddy.cn/docs/cli/plugins-reference)、[IDE Skills](https://www.codebuddy.cn/docs/ide/Features/Skills)

### WorkBuddy：Hook 插件已声明，具体桌面协议仍要验证

**[官方]** WorkBuddy《插件系统》明确列出 Skill、MCP、Hook、Agent、Rule，支持安装插件与添加第三方插件市场；更新日志 5.3.5（2026-07-25）也写“WorkBuddy 扩展插件 Hook”。这些足以证明产品声明有 Hook 扩展，尚不足以证明它与 CN IDE 或最新版 CLI 的全部事件和 JSON 行为一致。[插件系统](https://www.workbuddy.cn/docs/workbuddy/Plugins)、[更新日志](https://www.codebuddy.cn/docs/workbuddy/Changelog)

**[官方]** 当前设置文档说明代码开发会识别用户级 `.codebuddy` 配置，列举规则、Skills、Commands、MCP 等；没有在这段兼容说明中明确列出 Hooks。技能市场支持一键安装和上传技能包，开放平台也有技能包规范，但这不自动成为常驻 Hook 安装契约。首次打开含 `.codebuddy` 的不可信工作区时，WorkBuddy 还会询问信任；受限模式不运行其中的配置、脚本及插件能力。[系统设置](https://www.codebuddy.cn/docs/workbuddy/From-Beginner-to-Expert-Guide/Function-Description/Setting)、[技能](https://www.codebuddy.cn/docs/workbuddy/From-Beginner-to-Expert-Guide/Function-Description/Skills-Market)、[权限与工作区信任](https://www.codebuddy.cn/docs/workbuddy/From-Beginner-to-Expert-Guide/Function-Description/Permission-Modes)

**[官方]** 开放平台另有 OAuth 授权的本地助理/云端任务 Open API，以及云端 ACP `session/request_permission`。本地助理发送消息还列 `permission_response` 和需对应下行请求的 `requestId`，但当前字段示例主要是 AskQuestion；这不是本地 Hook 的同一条回传链。它需要开发者应用与用户授权，不能代替无账号服务的本机接入，也未证明能枚举所有桌面聊天。该方案可另立后续研究，不纳入本次 MVP。[WorkBuddy Open API](https://open.workbuddy.cn/docs/openapi)

## 本机静态证据（2026-10-24）

| 安装对象 | 已读到的证据 | 可以与不可以据此判断 |
|---|---|---|
| CodeBuddy CN.app **4.12.2** | `Info.plist`：`com.tencent.codebuddycn`、scheme `codebuddycn`；`Contents/Resources/app/extensions/genie/package.json`：独立扩展入口 `out/extension/index.js` | 确认 IDE 来源身份及独立架构；不能用 npm CLI 类型替代该 IDE 的运行验证 |
| npm `@tencent-ai/codebuddy-code` **2.151.0** | `dist-server/types/node/control-signal/control-signal-protocol.d.ts`、`session/session-hook-manager.d.ts` 等声明 Hook 类型，含 `PermissionRequest` | 外部 Hook 基础类型有 `session_id` 等；本次未在 Hook 输入类型证实 `tool_use_id` / `request_id`。内部 control signal 有 `tool_use_id`，不能当外部 Hook 字段使用 |
| WorkBuddy.app **5.8.3** | `Info.plist`：`com.tencent.workbuddy.mac`、scheme `workbuddy`；`app.asar.unpacked/cli/dist/codebuddy-lite-wb.mjs` 含 `readCommandHooksFromConfig`；原生 `main/workbuddy-product-config.js`、`main/index.js`、`main/node.js` 有配置解析和子进程环境传递 | GUI 配置 home 显式默认 `~/.workbuddy`，会写入两种配置目录环境变量并传给 CLI；不能把引擎自身通用的 `~/.codebuddy` fallback 当成 GUI 的实际目录 |
| WorkBuddy AI.app **5.8.4** | `Info.plist`：`com.workbuddy.workbuddy-ai`、scheme `workbuddy-ai`；同样有内置插件 Hooks 资源 | 是另一个可区分的来源；CN/海外市场归属未在本次证据中确认，不按应用名字强行归类 |

两份 WorkBuddy 包内的 `app.asar.unpacked/resources/plugins/workbuddy-builtin/builtin-plugins/` 可见 `workbuddy-sheetagent`、`wecom-a2a-auth`、`workbuddy-docx`、`subscription-gate` 的 `hooks/hooks.json`。其中已有 `SessionStart`、`UserPromptSubmit`、`SubagentStop`、`PreToolUse` 与 `${CODEBUDDY_PLUGIN_ROOT}` 等资源。**[本机]** 这证明随包存在插件接入路径；**[未实测]** 不证明第三方插件安装后在每种任务模式都会触发。

**[本机]** WorkBuddy.app 5.8.3 的配置解析顺序为 `WORKBUDDY_CONFIG_DIR` → `CODEBUDDY_CONFIG_DIR` → 用户主目录加产品 `dataFolderName`（默认 `.workbuddy`，可由打包配置定制）；GUI 写入 `WORKBUDDY_CONFIG_DIR` 和 `CODEBUDDY_CONFIG_DIR`，子进程继承环境。官方“兼容用户级 `.codebuddy`”与 GUI 运行时配置 home 是两个概念。设置来源参数仅在任务配置指定时显式传入，普通桌面任务究竟加载哪些用户 Hooks 仍需运行验证。此环境规则未对 WorkBuddy AI.app 单独确认，不能外推。

WorkBuddy 独立 `cli/bin` 的 `--help` 曾因 full dist 缺失报错；GUI 另有 lite 引擎，因此不能据此判定应用损坏或不支持 Hook。

静态证据位置：`/Applications/{CodeBuddy CN,WorkBuddy,WorkBuddy AI}.app/Contents/Info.plist`；CLI 类型根为 `~/.nvm/versions/node/v24.16.0/lib/node_modules/@tencent-ai/codebuddy-code/dist-server/types/node/`。此处仅记录公开安装资源，不把用户数据目录当接入 API。

## MVP 与后续验证

**[建议]** 采用 `provider = codebuddy` 表示协议家族，另外保存 `sourceApplication = codebuddyCNIDE / workbuddyDesktop / workbuddyAI / unknown`。用可信父进程 bundle、安装入口或显式安装元数据识别来源；不要仅凭共享的 `~/.codebuddy` 推断。会话键至少组合协议家族、来源、源 `session_id`，防止 IDE、CLI 与两份 WorkBuddy 同时运行时互相覆盖。

首版流程：专用 Hook/适配脚本 → 现有 `IslandHook` 与 Unix socket → 归一化状态 → 岛上显示 → 按准确 bundle 激活源应用。先覆盖“开始/运行/本轮结束”；仅有明确等待事件时显示“等待源端处理”，不凭 `PreToolUse` 或工具耗时猜测等待。停止只表示本轮结束，不等于任务成功；不显示无依据的完成百分比。非审批 Hook 应短时间完成，源端不可用或岛未运行时不得阻塞正常任务。

审批首版保留“回到来源处理”。上线岛内批准/拒绝前，必须在每个目标产品独立验证：请求唯一标识与 `session_id` 的关系、同会话并发请求、`PermissionRequest` 的准确返回 JSON、批准/拒绝效果、超时/断线/取消/迟到回复及源端恢复。不能复制其他产品的 `decision.behavior`，也不能将超时、解析失败或点击过期按钮映射成 `allow`。本次没有实测，暂不提供可执行审批配置。

来源跳转首版用 bundle 激活。**[官方]** WorkBuddy 5.1.0 日志声明可用外部 deeplink 打开任务/项目/待办；**[本机]** URL scheme 已登记；但精确会话路由参数、冷启动、两份应用并存时的路由尚未验证，不能把 scheme 的存在当作稳定会话 URL。宠物首版统一显示对应官方应用图标，有可核验的用户宠物选择后再复用；在本次官方 Hooks、插件、技能、设置、开放接口及更新日志中未找到当前宠物/图集/动画读取契约，暂不扫描私有缓存替代。[WorkBuddy 更新日志](https://www.codebuddy.cn/docs/workbuddy/Changelog)

最小验证顺序：①各来源无副作用 Hook 记录事件名和脱敏 ID，确认真实触发与配置生效；②同开 IDE、CLI、两份 WorkBuddy，验证会话隔离与跳转；③验证更新/卸载只移除自有配置、不覆盖其他 Hooks；④待生命周期稳定后，再用隔离测试目录验证上述审批矩阵。正式安装须保留备份与可撤销入口，CLI `/hooks` 审核、WorkBuddy 工作区信任等仍由源应用处理。

## 灵宠岛现项目改动地图（建议，尚未实现）

项目根：`<PROJECT_ROOT>`。本表基于本次对现项目的只读检查；底层 socket 和宠物渲染可复用。

| 位置 | 需要处理的边界 |
|---|---|
| `Sources/IslandCore/Models.swift` | `ProviderID` 当前仅 qoder/codex/generic；扩展协议家族及来源枚举。`SessionIdentity.key` 的 origin 隔离当前偏向 Qoder，需覆盖 CodeBuddy 家族 |
| `Sources/IslandCore/{HookNormalizer,HookOutput,SourceApplicationDetector}.swift` | 加工具别名/`tool_response` 等适配；来源检测识别准确 bundle。现审批仅 qoder/codex 白名单，保持关闭直到返回协议验证 |
| `Sources/IslandHook/main.swift` | 补 provider 与 source origin 传递，显式区分桌面宿主与 CLI |
| `Sources/LingChongDao/Connections/{ConnectionModels,ProviderDetector,HookConfiguration,ConnectionManager}.swift` | 当前两来源和配置 URL 二元分支需扩展；区分 IDE/CLI/WorkBuddy 安装、探测、生效确认与卸载，不覆盖共享配置 |
| `Sources/LingChongDao/Models/{AppModel,AppSettings}.swift` | 来源开关、来源显示与导航按新身份处理 |
| `Sources/IslandPets/LocalPetSourceReader.swift`、`Sources/LingChongDao/Pets/PetAppearanceStore.swift`、`PetView.swift` | 新来源默认对应官方应用图标，有可核验的用户宠物选择后再复用；官方宠物读取未证实，避免无依据轮询私有目录 |
| `Sources/LingChongDao/Views/{WorkbenchView,IslandView}.swift` | 连接卡、设置、收起态来源映射；仅展示当前已验证能力 |

## 官方证据索引

以下均于 2026-10-24 经 ego lite 直接查阅一手页面；引文只保留支持结论的短语。检索结果页与第三方博客未作为事实依据。在线文档版本不能自动代表本机安装版。

| 官方页面 | 原文短段 / 支持范围 |
|---|---|
| [CodeBuddy 产品说明](https://www.codebuddy.cn/docs/ide/Introduction) | “IDE、插件和 CLI 三种形态”：确认产品边界 |
| [IDE Hooks](https://www.codebuddy.cn/docs/ide/Features/Hooks) | “支持 7 种关键事件”；“通过对比 conversationId 判断”：事件与会话契约 |
| [CLI Hooks](https://www.codebuddy.cn/docs/cli/hooks) | “完整支持 Hook 事件家族（27+ 种）”；“Beta”：能力与版本风险 |
| [CLI Hooks 入门](https://www.codebuddy.cn/docs/cli/hooks-guide) | “任何外部文件修改都需要在面板确认后生效”：安装不能绕过审核 |
| [CLI 插件参考](https://www.codebuddy.cn/docs/cli/plugins-reference) | “整个会话（插件启用时）”；“PermissionRequest 权限对话框出现时”：分发作用域及事件存在 |
| [WorkBuddy 插件系统](https://www.workbuddy.cn/docs/workbuddy/Plugins) | “Hook 钩子插件，在特定时机自动执行操作”：办公版已声明支持 Hook |
| [WorkBuddy 更新日志](https://www.codebuddy.cn/docs/workbuddy/Changelog) | “WorkBuddy 扩展插件 Hook”（5.3.5）；页面 deeplink（5.1.0）：发布记录 |
| [WorkBuddy 系统设置](https://www.codebuddy.cn/docs/workbuddy/From-Beginner-to-Expert-Guide/Function-Description/Setting) | “自动识别并加载…用户级 .codebuddy 配置”：兼容范围，不能补推未明列的 Hooks |
| [WorkBuddy Open API](https://open.workbuddy.cn/docs/openapi) | “须与下行 permission 请求一致”：OAuth 方案的请求关联，不能替代本地 Hook 契约 |

