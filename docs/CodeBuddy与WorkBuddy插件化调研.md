# CodeBuddy 与 WorkBuddy 插件化调研

调研日期：2026-10-24（Asia/Shanghai）。问题来源：CodeBuddy CN 与 WorkBuddy 当前以「改写 `settings.json` 安装六项 Hook 命令」接入，是否可以像 ZCode / Codex / Qoder / DeepSeek Harness 一样改为**原生插件形式**。本文仅调研：查官方文档与本机公开安装资源，未安装、未改写、未触发真实 Hook。

证据标记沿用既有约定：**[官方]** 产品官方文档；**[本机]** 本机安装包或运行态文件的只读静态证据；**[建议]** 工程推断；**[未实测]** 无端到端验证。

## 结论

**CodeBuddy CN：可以，且强烈建议插件化。** CodeBuddy Code 有完整的官方插件体系（`.codebuddy-plugin/plugin.json` + `hooks/hooks.json`），配套非交互 CLI（`codebuddy plugin marketplace add` / `plugin install`，支持本地目录市场），CodeBuddy CN IDE 的 genie 扩展内置同一插件引擎并与 CLI 共享 `~/.codebuddy` 注册表。实现与灵宠岛现有 `CodexPluginService` / `ZcodePluginBridge` 完全同构，是第三个同模式实例。

**WorkBuddy：引擎侧可行，但没有无人值守安装通道，首版建议维持 settings.json 接入。** WorkBuddy 的 lite 引擎与 CodeBuddy 插件系统同构且会执行插件 Hook，本机也存在 directory 类型本地市场实例；但 GUI 插件面板只支持输入市场地址（本地路径未实测），包内 CLI 不能独立运行，直接写内部注册表风险高于 ZCode「用自带 CLI 注册」的等级。

| 维度 | CodeBuddy CN IDE | CodeBuddy Code CLI | WorkBuddy GUI |
|---|---|---|---|
| 插件格式 | **[本机]** 引擎读取 plugin.json / hooks.json / `${CODEBUDDY_PLUGIN_ROOT}` | **[官方]** 完整规范 + 校验工具 | **[本机]** lite 引擎同一格式；包内自带 hooks 插件先例 |
| 插件 Hook 执行 | **[本机]** genie 扩展有加载链；触发面 **[未实测]** | **[官方]** 插件启用时自动与用户/项目 hooks 合并 | **[本机]** HookManager 在 settings hooks 后追加插件 hooks（前次核验已证） |
| 非交互安装 | **[未实测]** 无自带 agent CLI；`buddycn` 只是 IDE 启动器 | **[本机]** `codebuddy plugin marketplace add <路径>` + `plugin install <名>@<市场>` 实测存在 | 无。包内 `cli/bin/codebuddy` 缺依赖不能独立运行；插件管理走 GUI → lite 引擎内部 HTTP 控制器 |
| 启用状态存储 | 与 CLI 共享：`~/.codebuddy/settings.json` 的 `enabledPlugins` + `~/.codebuddy/plugins/`（**[本机]**） | 同左 | `~/.workbuddy/settings.json` 的 `enabledPlugins` + `~/.workbuddy/plugins/`（**[本机]**） |

## CodeBuddy 侧证据

### 插件格式与官方市场（[官方]）

[创建插件](https://www.codebuddy.cn/docs/cli/plugins) 与[插件市场](https://www.codebuddy.cn/docs/cli/plugin-marketplaces)：

- 插件根含 `.codebuddy-plugin/plugin.json`（`name`、`version` 语义化版本、`description`、`author`、`"hooks": "hooks/hooks.json"` 等）；hooks、commands、skills 等资源目录放在插件根、不放进 `.codebuddy-plugin/`。
- `hooks/hooks.json` 与 settings.json 的 hooks 同 schema（事件 → `[{matcher, hooks:[{type:"command", command, timeout}]}]`），command 可用 `${CODEBUDDY_PLUGIN_ROOT}` 引用插件内脚本；另有 `type: prompt/agent/http`。
- 生效机制：“在插件启用时自动与用户和项目级 hooks 合并（不会覆盖）”，“不受 allowUntrustedFrontmatterHooks 闸门约束”。对比 settings.json 方式“任何外部文件修改都需要在面板确认后生效”——插件化把逐次审查变成一次性安装动作。
- 市场是含 `.codebuddy-plugin/marketplace.json` 的目录：`name`（kebab-case）、`owner`、`plugins[]`（`name`/`source`/`description`，`source` 支持相对路径 `"./plugins/xxx"`）。
- 管理命令（均为正式子命令，非会话内斜杠命令独占）：`plugin marketplace add <source> [-n name]`、`plugin install <名>@<市场> [-s scope]`、`uninstall`、`enable/disable`、`update`、`validate`、`plugin list --json`。本地目录与本地 marketplace.json 文件是官方声明的市场来源（“用于开发和测试”）。安装“写入版本化 cache、提交 installed_plugins.json”；“移除市场将卸载从该市场安装的所有插件”。
- `enabledPlugins` 是期望态声明（enable“只声明 desired state”），运行时“首轮投影 cache-first（读 enabledPlugins 和 installed_plugins.json registry），后台 reconcile 负责同步、补齐与清理”——本机实测 `plugin list` 只列已物化插件，与 `~/.codebuddy/settings.json` 里已有的 8 个 `enabledPlugins` 条目（docx、xlsx、pdf、playwright-cli 等）互不矛盾：后者正是期望态 + 引擎按需补齐的形态。

### 本机实证（2026-10-24）

- **CLI**：npm 全局 `@tencent-ai/codebuddy-code` 2.151.0，`codebuddy plugin --help` 实测列出 install/uninstall/enable/disable/update/marketplace/validate 全套子命令；`plugin list --json`、`plugin marketplace add --help`（`-n, --name`）可用。
- **注册表**：`~/.codebuddy/plugins/known_marketplaces.json` 已登记两个内置市场（`codebuddy-plugins-official`、`cb_teams_marketplace`，zip 远程源），`marketplaces/codebuddy-plugins-official/` 是完整市场快照（207 个插件，`.codebuddy-plugin/marketplace.json` 的 `plugins[].source` 全为相对路径）。
- **官方 Hook 插件样板**：市场内 `atuin`、`chainguard`、`hookify` 等即为纯 Hook 插件。`atuin` 的 `plugin.json` 声明 `"hooks": "hooks/hooks.json"`，hooks.json 内 `PreToolUse` → `command: "node ${CODEBUDDY_PLUGIN_ROOT}/dist/atuin_hook_client.cjs"`——与灵宠岛需要的形态（command 指向插件内 helper）一致。
- **CodeBuddy CN IDE 4.12.2 共享该注册表**：genie 扩展（`extensions/genie/out/extension/index.js`）内置同一插件引擎——`USER_DATA_DIR_NAME=".codebuddy"`、`DEFAULT_PLUGINS_DIR="plugins"`、`MARKETPLACE_FILE_NAME="known_marketplaces.json"`、`PLUGIN_MANIFEST_FILE="plugin.json"`；有 `hooks/hooks.json` 加载链（`defaultHooksFile:"hooks/hooks.json"`、读取插件的 `hooksConfig`）、`enabledPlugins` 锁与处理、插件市场 UI（“插件市场”文案与 marketplace 进度态）。即：**IDE 与 CLI 通过 `~/.codebuddy` 共用同一插件注册表**；`~/.codebuddy/settings.json` 里的 `enabledPlugins` 即本机 IDE 使用插件体系的实证。
- **IDE 侧边界**：genie 4.12.2 引擎**不含** `extraKnownMarketplaces`（0 处），即 CLI 文档的“settings.json 声明市场+插件由 reconcile 补齐”通道在当前 IDE 引擎不可用；`~/.codebuddy/bin/buddycn` 只是 IDE 启动器 symlink，IDE 不带 agent CLI。IDE 插件面板能否添加本地目录市场 **[未实测]**。

## WorkBuddy 侧证据

- **引擎同构**：lite 引擎（`app.asar.unpacked/cli/dist/codebuddy-lite-wb.mjs`，2.161.0-wb）内含同一插件系统——`known_marketplaces.json`/`installed_plugins.json`、`addMarketplace`（19 处，含 `pluginManager.addMarketplace(source, {name, autoUpdate})`）、`"directory"` 市场类型（14 处）、`extraKnownMarketplaces`（4 处，含 reconcile 校验逻辑）。
- **注册表实证**：`~/.workbuddy/plugins/` 下 `known_marketplaces.json`（内置市场 + 一个 `type:"directory"`、`isBuiltIn:false`、指向本机路径的 `experts` 市场——**本地目录市场在 WorkBuddy 真实存在**，虽为自动生成）、`installed_plugins.json`（version 2：`plugins: {"名@市场": [{scope, installPath(cache 路径), version, installedAt}]}`）、`configured-plugins.json`（builtInMarketPlugins）、`cache/<市场>/<插件>/<版本>/` 物化目录；`~/.workbuddy/settings.json` 有 `enabledPlugins`（含 `false` 的禁用条目，证明启用开关走此键）。
- **Hook 执行链**：前次《Buddy 接入实施核验》已证 lite 的 `HookManager.getHooks(event)` 在 settings hooks 之后追加插件/scoped hooks。
- **无无人值守通道**：包内 `cli/bin/codebuddy` wrapper require `../dist/codebuddy` 失败（实测复现，只有 lite 产物、无 full dist）；GUI 插件管理走界面（[官方插件系统文档](https://www.workbuddy.cn/docs/workbuddy/Plugins)只描述“插件页 → 安装/管理/卸载”与“点 + 输入插件市场地址”，未提本地路径、命令行或离线安装）→ 内部 HTTP 控制器（`local_plugins_controller`，OpenAPI operationId 如 `addMarketplace`）。该控制器无稳定契约与鉴权承诺，不建议灵宠岛调用。

## 建议方案

### CodeBuddy CN：新增 `integrations/codebuddy-plugin/`，与 ZCode/Codex 同构

1. **插件包**：`lingchongdao-codebuddy/`（`.codebuddy-plugin/plugin.json` 声明 `"hooks": "hooks/hooks.json"`；`hooks/hooks.json` 承接现有六事件的 adapter 调用，command 用 `${CODEBUDDY_PLUGIN_ROOT}/...` 指向插件内 helper；helper 复用现有 `lingchongdao-hook` 通道）+ 市场清单 `.codebuddy-plugin/marketplace.json`（`name: "lingchongdao-local"`，`plugins[].source: "./plugins/lingchongdao-codebuddy"`）。参照本机 `atuin` 样板与 `integrations/zcode-plugin/marketplace.json` 现有写法。
2. **安装流程**（复刻 `CodexPluginService.swift` 状态机：installed/enabled/version/source 核验 + `needsRepair`）：复制到 `Application Support/LingChongDao/codebuddy-plugin/` → 探测 `codebuddy` CLI（PATH 及 nvm 等常见位置）→ `plugin marketplace add <路径> -n lingchongdao-local`（若同名市场来自其他路径则报错不动）→ `plugin install lingchongdao-codebuddy@lingchongdao-local -s user` → `plugin list --json` 核验 → 成功后从 `~/.codebuddy/settings.json` 精确移除灵宠岛六命令 Hook（保留其他），与 ZCode 安装后清理 `config.json` 旧 Hook 同理。
3. **卸载/更新**：`plugin uninstall`（或 `marketplace remove` 连带卸载）+ 确认 `enabledPlugins` 自有条目移除；更新走版本号 + `plugin update`，不再需要迁移 settings.json 里的绝对路径（`${CODEBUDDY_PLUGIN_ROOT}` 解决了《名称与兼容迁移》里的 helper 绝对路径痛点）。
4. **通道分级**：用户装有 CodeBuddy Code CLI → 全自动；仅 IDE → 保留现有 settings.json 接入作为默认（或「手动安装」导出市场目录），待验证 IDE 插件面板是否接受本地市场后再升级。注意本机 npm CLI 是前次调研所装，不能假设普通 IDE 用户有 `codebuddy` 命令。
5. **不改行为边界**：仍只观测、不代答权限（现状），插件化只换分发形态；安装后重启来源应用 + 新会话验证的提示照旧。

### WorkBuddy：首版维持现状，插件化作为后续可选

- 现有 settings.json 接入已实施并核验，卸载边界清晰，不动。
- 后续若要插件化，按风险递增三档：①验证 GUI“添加市场”是否接受本地路径（引擎层支持 directory 类型，只是 GUI 输入框行为未实测），成立则走“导出市场 + 用户粘贴路径 + 界面安装”的半官方渠道；②WorkBuddy 未运行时直接写 `known_marketplaces.json`（directory 条目）+ `installed_plugins.json` + `enabledPlugins`——格式本机全证据，但属内部状态：存在 GUI 并发重写（CodeBuddy 引擎自身就有“另一进程可能正在重写 known_marketplaces.json”的告警文案）、版本升级变格式、reconcile 清理三重风险，必须配完整回滚与多版本验证，不建议默认开启；③调用 lite 引擎内部 HTTP 接口——无契约，不做。

## 风险与未实测清单

1. CodeBuddy CN IDE 4.12.2 的插件 Hook 触发面（普通聊天/Agent 会话是否都触发、是否需要面板确认）未端到端验证；建议按《Buddy 接入实施核验》的无副作用验证法在隔离目录实测。
2. 三引擎版本差异：npm CLI 2.151.0、lite 2.161.0-wb、genie 4.12.2（无 `extraKnownMarketplaces`）。注册表格式当前互通，但 `installed_plugins.json` 的 version 字段（本机见 version 2）与 cache 布局属内部演化接口，升级需跟踪。
3. `plugin install` 的 `--scope user` 写入与 IDE 读取的一致性（IDE 是否要求物化到 cache 才执行插件 Hook）未实测；若 IDE 只认 cache-first，需确认 reconcile 会补齐。
4. 官方 CLI 在线文档标注 Hooks/插件体系为 Beta，命令与格式可能随版本变动。

## 证据索引

| 来源 | 关键内容 |
|---|---|
| [CLI 创建插件](https://www.codebuddy.cn/docs/cli/plugins) | 插件目录/plugin.json/hooks.json 格式、`--plugin-dir`、不受 frontmatter 闸门约束 |
| [CLI 插件市场](https://www.codebuddy.cn/docs/cli/plugin-marketplaces) | marketplace.json 格式、本地目录市场、install/uninstall/enable 语义、cache 与 reconcile |
| [WorkBuddy 插件系统](https://www.workbuddy.cn/docs/workbuddy/Plugins) | 五类插件含 Hook；GUI 安装/管理/卸载；添加市场仅“输入地址” |
| `codebuddy plugin --help`（npm 2.151.0） | install/uninstall/enable/disable/update/marketplace/validate/list 子命令实测存在 |
| `~/.codebuddy/plugins/`、`~/.workbuddy/plugins/` | known_marketplaces.json、marketplaces 快照、installed_plugins.json v2、directory 市场（experts）、cache 布局 |
| `~/.codebuddy/settings.json`、`~/.workbuddy/settings.json` | `enabledPlugins` 映射（含禁用条目）实证 |
| genie `extensions/genie/out/extension/index.js` | `USER_DATA_DIR_NAME=".codebuddy"`、插件 manifest/marketplace 常量、hooks.json 加载链、插件市场 UI；无 `extraKnownMarketplaces` |
| `codebuddy-lite-wb.mjs` | `addMarketplace`/directory 类型/extraKnownMarketplaces/reconcile；`local_plugins_controller` |
| 市场内 `atuin` 插件 | 纯 Hook 插件 + `${CODEBUDDY_PLUGIN_ROOT}` command 样板 |
| `/Applications/WorkBuddy.app/.../cli/bin/codebuddy` | require `../dist/codebuddy` 失败，无独立 CLI（实测） |
| `~/.codebuddy/bin/buddycn` | symlink → IDE `bin/code`，仅为 IDE 启动器 |
