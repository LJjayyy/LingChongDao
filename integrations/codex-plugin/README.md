# 灵宠岛 · Codex 本地伴随插件

把 Codex 的会话、工具和子任务状态同步到灵宠岛。需要 macOS 14 或以上、Apple 芯片 Mac，以及运行中的灵宠岛应用。插件附带本机 helper，无需 Python、Node 或额外网络服务。

这是本地安装包，尚未发布到公开目录。插件版本 `0.1.6` 与 Mac 应用版本独立。导出和解压不会安装插件，也不会自动信任 Hooks。

## 推荐：在灵宠岛里一键安装

打开灵宠岛的「连接的应用 → Codex → 一键安装插件」。应用会放置完整插件到本机持久目录，通过 Codex 官方 CLI 登记并安装，再读取实际安装及启用状态。成功后仅清理灵宠岛管理的旧版直接 Hook，保留其他 Hook；失败会保留旧接入供重试。

安装后到 Codex 的 Hook 审查界面确认「灵宠岛 · …」，然后开启新会话。安装、启用、已审查和实际收到活动是不同状态。已被用户禁用的插件需要在 Codex 中启用；灵宠岛不会修改信任状态或自动重启 Codex。

## 手动安装

将完整文件夹放在不会被删除的位置，运行：

```sh
codex plugin marketplace add /absolute/path/to/LingChongDaoCodexPlugin --json
codex plugin add lingchongdao-codex@lingchongdao-local --json
codex plugin list --marketplace lingchongdao-local --json
```

然后审查 Hooks 并使用新会话验证。手动导出不执行旧直接 Hook 清理，已有用户应优先使用应用的一键安装完成迁移。同名 marketplace 已指向其他目录时，应用会提示冲突，不覆盖未知来源。

## 同步内容与审批回退

| 事件 | Hook 审查名称 |
| --- | --- |
| SessionStart | 灵宠岛 · 同步会话开始 |
| UserPromptSubmit | 灵宠岛 · 同步新任务 |
| PreToolUse | 灵宠岛 · 同步工具开始 |
| PostToolUse | 灵宠岛 · 同步工具结果 |
| PermissionRequest | 灵宠岛 · 处理权限请求 |
| Stop | 灵宠岛 · 同步本轮结束 |
| SessionEnd | 灵宠岛 · 同步会话结束 |
| SubagentStart | 灵宠岛 · 同步子任务开始 |
| SubagentStop | 灵宠岛 · 同步子任务结束 |
| Interrupt | 灵宠岛 · 同步任务中断 |

每条 Hook 通过 macOS 自带 `/bin/sh` 转发原始事件 JSON。只运行包内 `bin/lingchongdao-hook`，通过本机 Unix socket 连接灵宠岛，不依赖用户个人路径。当前本地连接目录为 `~/Library/Application Support/LingChongDao/`，socket 位于其 `run/bridge.sock`。

兼容旧客户端：仅当新 socket 不存在时，插件可连接旧客户端已建立的 `~/Library/Application Support/AIIsland/run/bridge.sock`。新 socket 已存在时不会改连旧端点，也不会使用旧目录中的全局 helper；这不是当前安装路径。

状态事件最多等待约 2 秒；可处理的权限请求最多等待 45 秒。原生 helper 验证事件身份、有效期和支持的操作，只有用户对当前请求作出明确决定时才返回审批结果。没有 helper、灵宠岛未运行、连接中断、超时或 helper 异常时均不产生审批决定，交回 Codex 正常流程。插件不会自动启动应用或在后台重试。

当前协议仍有以下限制：部分权限必须回 Codex 处理，通用问答也不因此获得回复通道。完整操作与能力以岛上当前卡片及 Codex 的审批提示为准。

插件 0.1.6 配合 Mac 应用 0.1.34 接通岛内审批。Codex 的 PermissionRequest 不含 `tool_use_id`，包内 helper 为每次调用绑定独立的连接 ID，用户可在完整预览简单 Bash 命令后「批准一次」，也可拒绝或「回 Codex 处理」。未完整展示的文件变更、MCP 或复杂命令只提供拒绝和回来源处理。并行请求独立排队，超时和断线不产生允许/拒绝决定。helper 更新会使 Codex 要求重新审查插件内容，即使 Hook 命令未变也需要用户确认。

当前应用还会读取该请求指定的本地 transcript 头尾有界片段，核对会话、回合和审查者元数据。只有确认当前回合使用人工审查时才提供上述操作；自动审查或无法确认时立即回 Codex，不等待岛内决定。不会扫描聊天历史寻找当前会话，数据范围见安装镜像或源码根目录的 `PRIVACY.md`。

Mac 应用 0.1.33 起识别 `request_user_input` 和 `request_user_input_async`，在岛上显示「待回答」及问题内容。同步提问由对应工具结果结束；异步提问的 `accepted:true` 仅代表提问已展示，等待会保留到用户在 Codex 答完该批问题。普通新任务、会话结束或中断会清理等待状态。此适配沿用现有 PreToolUse、PostToolUse、UserPromptSubmit Hook，不增加权限或改变 Hook 命令。

## 卸载与更新

在 Codex 插件目录禁用或卸载此插件即可停止插件派发，不会改动 Mac 应用、其他来源的连接或历史设置。重新导出并替换插件来源后，按客户端要求刷新 marketplace、更新插件或重启，再审查变化的 Hooks。灵宠岛的 Codex 接入统一使用插件，不再提供新的直接 Hook 安装入口。

## 为什么仍需本地安装和审查

OpenAI 当前支持本地/仓库 marketplace 插件捆绑 lifecycle hooks，并提供 `PLUGIN_ROOT` 定位包内脚本；安装和启用均不会自动信任 Hooks。参见 [官方插件打包文档](https://developers.openai.com/plugins/build/plugins) 和 [官方 Hooks 文档](https://learn.chatgpt.com/docs/hooks)。

官方公开目录目前不接受包含 lifecycle hooks 的提交，所以本包采用本地分发；在 Web 安装插件也不会把 Mac 应用或脚本部署到本机。参见 [官方提交限制](https://developers.openai.com/plugins/deploy/submission)。此插件不会绕过这些边界。

## 开发验证与打包

源码目录本身不含二进制。先构建 Mac 应用，再从项目根目录运行：

```sh
./scripts/build-codex-plugin.sh
```

打包脚本不启动新的 Swift 编译，只复制当前 `dist/build.noindex/灵宠岛.app/Contents/MacOS/lingchongdao-hook`，验证 arm64 架构、离线契约和包内引用。输出完整的 `dist/codex-plugin/LingChongDaoCodexPlugin` 目录及 `dist/codex-plugin/LingChongDaoCodexPlugin.zip`。`package-info.json` 记录插件版本、应用版本与 helper SHA-256，便于核对。

可单独运行 `python3 integrations/codex-plugin/verify.py`。检查只用临时 HOME、新旧客户端假 socket、假 helper 和合成输入，不安装插件、不读真实聊天或配置、不修改信任状态。Mac 应用的签名、公证和更新机制属于应用分发，不由插件安装代替。

插件 0.1.3 的 helper 会核验桌面宿主归属，供灵宠岛在用户直接回到来源应用时收起该应用已有的结束提示。终端运行内置 CLI 不会仅因安装路径被当作桌面来源；未确认归属的消息继续保留。Hook 事件、命令和权限范围不变。
