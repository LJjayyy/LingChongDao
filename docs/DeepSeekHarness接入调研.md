# DeepSeek Harness 接入调研

结论：DeepSeek Harness（dsh）**支持接入**，灵宠岛已把插件做成 **dsh 原生组合包（bundle）**：装好后会出现在 DeepSeek Harness 的「插件 → 已安装插件」里，可自行开关/移除。不依赖 Harness 的实验性 `dsh-hooks-claude-code` / `dsh-hook-protocol` 包，安装完全离线。能力为「会话开始 + 任务/工具活动 + 本轮结束 + 点击提醒定位对应会话 + 手动查看会话后同步收起提醒」，**不含权限请求回传**。会话定位由灵宠岛插件通过官方客户端扩展实现，不是 DSH 现成的外部深链。

## 证据来源

- 本机 `DeepSeek Harness.app` 0.2.1-rc.2，Bundle ID `com.deepseek.dsh`；自带 CLI `Contents/Resources/runtime/cli/bin/dsh`（`dsh -V` = `0.2.1-rc.2`）。
- 本机源码树 `~/Documents/deepseek-harness`：`packages/boot/app-boot`（profile 与 patch 组合）、`packages/hooks/hooks-claude-code`（官方桥接插件，仅作为观测点参考实现）。
- profile 结构：`~/.dsh/profiles/desktop/package.json` + `cordis.patch.yml`。组合包是声明了 `"dsh": { "bundle": { "patch": "./cordis.patch.yml" } }` 的包，启用 = 把包名追加到 `package.json` 的 `dsh.profile.bundles`；合成顺序是「bundles 按序 → 用户 patch」。
- 组合包在 dsh 插件页的图标来自包根 `package.json` 的 `icon` 字段（相对路径，PNG/SVG/JPEG/WebP，≤256 KiB），host 会编码成 data URL。本插件用灵宠岛的应用图标（老板鼠）。
- dsh 的插件页只列：内置插件配置、实验性插件、以及**已安装的组合包**。普通依赖（没声明 bundle patch）不会出现在「已安装插件」里——这正是旧版 loader 行方案看不到的原因。
- 官方 CLI 对 `desktop` profile 有独占保护：拒绝 boot/dump，但允许 `dsh plugin --profile desktop add …` 管理依赖。`dsh plugin add <本地目录>` 以 pnpm `link:` 登记，并**自动选中组合包**（不需要网络）。

## 本插件接入了什么

插件源码在 [`integrations/dsh-plugin`](../integrations/dsh-plugin)，打包进 `灵宠岛.app/Contents/Resources/DshPlugin`。它订阅 Harness 的原生扩展点，把事件转成灵宠岛 helper 已经认识的 JSON（Claude Code 形状），再启动 helper 上报：

| Harness 扩展点 | 上报事件 | 主要字段 |
| --- | --- | --- |
| `agent/session-start` | `SessionStart` | `session_id`、`cwd`、`source` |
| `agent/pre-step`（仅真实用户消息） | `UserPromptSubmit` | `prompt` |
| `tools/pre-execute` | `PreToolUse` | `tool_name`、`tool_input`、`tool_use_id` |
| `tools/post-execute` | `PostToolUse` | 同上 + `tool_response` |
| `agent/turn-stopping` | `Stop` | `stop_hook_active` |
| `subagent/start` / `subagent/end` | `SubagentStart` / `SubagentStop` | `agent_id`、`agent_type` |

要点：

- **仅观测**：不注入上下文、不拦截工具、不回答权限，因此不会改变 Harness 的决策或阻塞会话。
- helper 以 `--provider dsh` 启动，单次最多 1.5 秒；失败只写日志。
- `agent/pre-step` 每步都会触发，插件只把 `source.kind === 'user'` 的消息当作新提问，避免工具结果覆盖任务标题。
- `agent/session-start` 在启动阶段可能早于插件激活（官方桥接也有同类竞态），插件会在**同一会话的首个 prompt** 补发一次 `SessionStart`，不会漏掉会话开头。

## 一键安装做了什么

1. 把 helper 复制到 `~/Library/Application Support/LingChongDao/bin/lingchongdao-hook`（固定位置，应用移动后仍有效）。
2. 把组合包（包括 `package.json` / `index.js` / `navigation.js` / `client.js` / `cordis.patch.yml` 与图标、语言资源）复制到 `~/Library/Application Support/LingChongDao/dsh-plugin/`。
3. 用应用自带 `dsh plugin --profile desktop add <该目录>` 登记依赖并选中组合包（`link:`，离线）；若它没有自动选中，再幂等追加到 `dsh.profile.bundles`。
4. 清理 0.1.x 遗留的 loader 行（如果有），避免与组合包重复上报。

之后在 DeepSeek Harness 的「插件 → 已安装插件」里能看到带灵宠岛图标的 `lingchongdao-dsh-hooks`，可开关或卸载。灵宠岛的卡片与 Codex 一致：一键安装/修复、卸载插件、打开应用、手动导出插件包；「卸载插件」会取消启用、移除 profile 依赖并删除本地副本（共享 helper 保留）。

## 真机验证

- 临时 profile 中登记本组合包并选中 `dsh.profile.bundles`：无界面任务实测 `SessionStart`、`UserPromptSubmit`、`PreToolUse`、`PostToolUse`、`Stop` 全部触发，payload 含 `session_id`、`cwd`、`hook_event_name`、`tool_name`、`tool_input`、`prompt`；用相同 `id` 的 patch 覆盖 `config` 也能生效。
- 同一份 payload 交给 `lingchongdao-hook --provider dsh` 可正常解析；桥未启动时只输出 `{}`，不会替用户批准。
- 回归：`./scripts/verify.sh` 39 项、`./scripts/verify-origins.sh` 78 项、应用路由验证全部通过（新增组合包选中/取消、遗留行清理、插件文件集校验、应用识别与导航）。

## 2026-11-01 会话导航验证

- 本机安装版本为 `0.2.1-rc.5`；读取安装包与[官方桌面入口](https://github.com/deepseek-ai/deepseek-harness/blob/master/apps/desktop/src/main.ts)，确认 `dsh://open` 仅唤起窗口。下面的导航能力来自灵宠岛插件，而非给深链拼接参数。
- 插件通过官方 [`dsh.client`](https://github.com/deepseek-ai/deepseek-harness/blob/master/packages/client/modules/README.md) 加载客户端，并使用官方 `ctx.connection.fetch.register` 注册 owner 鉴权的同源路由。隔离真实 runtime 对未鉴权请求返回 401，对跨来源请求返回 403；不读取或导出桌面认证令牌。
- 客户端调用官方 [`ctx.uiWorkspace.openSession`](https://github.com/deepseek-ai/deepseek-harness/blob/master/packages/client/ui-workspace/src/client/navigation.ts)。回执需目标独占 `mainView`、历史 `openState === 'open'`、Conversation 主面板，60 ms 后仍满足。安装包实现已独立复核这些字段的语义。
- 官方 rc.5 隔离 Web runtime 中加载生产插件，浏览器核实 A/B 页面标题分别对应目标；再用生产 Swift `DshNavigationClient` 发送 A/B，各收到匹配 `opened`。GUI 使用合成空白会话，不是用户真实的已完成模型任务；其身份由页面标题与官方选中状态确认，不能将截图说成非空聊天历史验收。真实 Desktop 的前台唤起仍由既有应用打开接口处理。
- 生产 AppModel 的合成双结束任务验证覆盖仅清目标、失败保留、新结果保护、连续点击，以及跨来源点击后旧传输收束。最终应用检查 85/85、来源关注检查 45/45、Swift 实际 Unix socket 检查 10/10、插件检查 10/10 通过；核心独立验证 43/43 通过。独立 Review 已复核回修，未发现阻塞问题。此环境缺少 XCTest 模块，相关 XCTest 文件保留给完整 Xcode 环境；本轮实际执行的是独立验证程序。
- 安装器将 `navigation.js` 和 `client.js` 纳入完整性检查、复制与更新摘要。当前插件版本为 `0.4.0`；旧版需更新并重启 DSH。新增的手动查看同步沿用已确认的主视图、加载和面板快照，额外要求窗口可见并连续获得焦点约 1 秒；仅上报会话身份和停留起点，不读取聊天内容。2026-11-05 已完成本地 Debug 打包及签名验证，并核对内置插件、导出 ZIP 与源码一致；手动查看的合成回归通过，真实桌面焦点行为尚待实机验收。

## 当前边界

- **仍是应用内挂载**：`desktop` profile 由 DeepSeek Harness 独占管理，应用升级可能重写 `package.json` 或 `dsh.profile.bundles`；连接卡片会显示「配置不完整」，重新预览安装即可恢复。
- **需要重启**：组合包只在应用启动时组合（未开 HMR 时），安装后必须完全退出并重启 DeepSeek Harness，再开新会话。
- **无权限请求**：Harness 的权限确认发生在自己的界面里，岛内不会出现待批准卡片。
- **无官方外部会话深链**：rc.5 的 `dsh://open` 只唤起窗口，不支持传入 session ID；灵宠岛通过自己的插件导航桥补足定位。插件未就绪或导航失败时打开应用并保留提醒。
- 观测点属于 Harness 的扩展 API，版本升级后若名称变化，插件的相关事件会静默失效；升级后请「检查连接」并用新会话确认。
