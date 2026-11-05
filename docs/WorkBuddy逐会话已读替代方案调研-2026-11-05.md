# WorkBuddy 逐会话已读替代方案调研

调研日期 2026-11-05。目标是在 WorkBuddy 内直接打开会话 A 时只收起岛上的 A，并保留 B。GitHub 部分按固定提交核对公开源码，引用的项目均未安装或运行。

优先验证**只读观察 WorkBuddy 写入本地 SQLite 的会话未读状态**。本机 5.9.3 的界面查看路径会按会话 ID 落库，隔离实验能读到对应标志变化。zisla 已采用只读 SQLite 获取 WorkBuddy 会话状态，Agent Companion 的 Codex 适配提供了按同一轮次确认未读转已读的参考。WorkDaddy 还演示了通过 CDP 读取选中会话 ID，需要调试启动。 [zisla 的 SQLite 读取](https://github.com/wzz6423/zisla/blob/c55ca5884537c297e345512cf0183c4fe6bfe5f5/mac/Sources/ZislaKit/WorkBuddySessionActivityDetector.swift#L53-L104) · [Agent Companion 的已读观察](https://github.com/changexbc/agent-companion/blob/14430ef9f3ec592f2c898fb088800cc7b7a70097/crates/agent-studio-core/src/codex_read_state.rs#L26-L64) · [WorkDaddy 的会话识别](https://github.com/babygoton/WorkDaddy/blob/c37fb91c725ea4651df0c0699977d74258ccb548/scripts/workbuddy-compat.js#L133-L189)

## GitHub 项目核对

| 项目 | 已实现的信号 | 对逐会话收起的含义 |
| --- | --- | --- |
| zisla | macOS Swift 实现。以 `SQLITE_OPEN_READONLY` 打开 `~/.workbuddy/workbuddy.db`，读取会话 ID、状态和时间，筛选运行、待处理、阻塞、错误等状态。 | 可参考连接、查询和错误处理。查询未取 `unread`，未找到查看后收起的实现。 [读取代码](https://github.com/wzz6423/zisla/blob/c55ca5884537c297e345512cf0183c4fe6bfe5f5/mac/Sources/ZislaKit/WorkBuddySessionActivityDetector.swift#L53-L104) · [默认路径](https://github.com/wzz6423/zisla/blob/c55ca5884537c297e345512cf0183c4fe6bfe5f5/mac/Sources/ZislaKit/WorkBuddySessionActivityDetector.swift#L154-L155) |
| Agent Companion | WorkBuddy 的运行状态来自 Hook，部分沙箱等待从日志补充。从悬浮栏可用 `workbuddy://chat/<id>` 或 `workbuddy-ai://chat/<id>` 打开会话。 | “已读后收起”观察器仅处理 Codex。它先观察当前轮次确实未读，再确认同一轮离开未读集合。WorkBuddy 完成项使用界面自身的保留时间、从悬浮栏打开或手动关闭。 [WorkBuddy 集成说明](https://github.com/changexbc/agent-companion/blob/14430ef9f3ec592f2c898fb088800cc7b7a70097/README.md#L72-L92) · [跳转](https://github.com/changexbc/agent-companion/blob/14430ef9f3ec592f2c898fb088800cc7b7a70097/src/monitor/session-link.ts#L151-L177) · [完成项状态](https://github.com/changexbc/agent-companion/blob/14430ef9f3ec592f2c898fb088800cc7b7a70097/src/monitor/session-model.ts#L125-L145) · [Codex 已读观察器](https://github.com/changexbc/agent-companion/blob/14430ef9f3ec592f2c898fb088800cc7b7a70097/crates/agent-studio-core/src/codex_read_state.rs#L26-L64) |
| WorkDaddy | 支持 macOS。会话适配代码从侧栏 `data-conversation-id` 及选中属性识别会话，或从正文容器的 `data-root-id` 取 ID。部分功能通过 React 内部控制器读取当前会话。 | 证实渲染层有可关联的 ID。它通过 CDP 访问渲染进程，启动器需要调试参数，且兼容层依赖当前界面结构。未找到它面向普通启动提供 WorkBuddy 已读订阅。 [启动器](https://github.com/babygoton/WorkDaddy/blob/c37fb91c725ea4651df0c0699977d74258ccb548/scripts/relaunch-with-cdp.sh#L328-L346) · [会话适配代码](https://github.com/babygoton/WorkDaddy/blob/c37fb91c725ea4651df0c0699977d74258ccb548/scripts/workbuddy-compat.js#L133-L206) |
| workbuddy-copilot | 只读访问会话和工作区表。适配器对当前界面会话明确返回 `unknown_active_session`，没有用 `last_activity_at` 排序结果替代。 | 证实本地库可用于读取会话身份，也说明不能从最后活动时间猜用户当前在看哪一条。 [只读连接](https://github.com/SuperOPC-AI-Incubator/workbuddy-copilot/blob/530aa3fc014705b8a1a2c059a9d513ebdc0156bd/copilot/student_platform/workbuddy.py#L764-L768) · [活动会话识别](https://github.com/SuperOPC-AI-Incubator/workbuddy-copilot/blob/530aa3fc014705b8a1a2c059a9d513ebdc0156bd/copilot/student_platform/workbuddy.py#L369-L377) |
| WorkBuddy Buddy | macOS 桌宠。插件注册 `SessionStart`、`UserPromptSubmit`、`PreToolUse`、`PostToolUse`、`PermissionRequest`、`Notification` 和 `Stop`。 | 这七项用于运行状态和交互通知，插件配置中没有查看或已读事件。 [插件的 Hook 配置](https://github.com/FlashFamily/workbuddy-buddy/blob/2247d8bae4a5f7e33bf59ba522f3c82b466ba362/integrations/workbuddy-plugin/hooks/hooks.json) |
| Opsnook | 通过本地 JSONL 追踪会话运行状态。跳回会话时尝试按任务窗口标题定位，找不到时降级激活应用。 | JSONL 适合跟踪执行，项目没有用它识别用户查看。窗口标题也无法区分同名会话。 [状态逻辑](https://github.com/DevXDojo/Opsnook/blob/ba9fed4bf0c470ae2ac29094a542482723967d80/docs/sessions_status_logic/workbuddy.md) · [回跳目标](https://github.com/DevXDojo/Opsnook/blob/ba9fed4bf0c470ae2ac29094a542482723967d80/Packages/OpsnookKit/Sources/OpsnookAdapters/WorkBuddy/WorkBuddyAdapter.swift#L310-L318) |
| workbuddy-remote | 公开启动指引面向 Windows。用 CDP 将原生 `buddyAPI` 方法和事件桥接给浏览器里的 WorkBuddy 界面。 | 提供进程内调用的技术参考，未确认可在普通 macOS 客户端对外订阅已读。 [启动和结构](https://github.com/vergess3/workbuddy-remote/blob/1258e8278f14ac40ba451f53965627fb62e8cccb/README.md#L7-L55) · [订阅桥](https://github.com/vergess3/workbuddy-remote/blob/1258e8278f14ac40ba451f53965627fb62e8cccb/src/bridge/runtime.mjs#L892-L916) |
| WorkBuddy2API | 核对了可访问的 Zhengyuuuui 版本。HTTP 路由把模型请求转换为 OpenAI、Responses 或 Anthropic 协议。 | 转发模型轮次与用户在桌面打开历史会话是两个不同的入口，代理收不到桌面查看事件。 [代理入口](https://github.com/Zhengyuuuui/workbuddy2api/blob/82941c37f5411e48b463ea42d1489e8c8da0eaea/server/codebuddy_proxy.py#L1289-L1348) |

搜索覆盖 GitHub 的 `WorkBuddy` 搭配 `unread`、`markRead`、`active session`、`workbuddy.db`、`会话监控`、`已读`、`macOS`，并追查命中项目的源码。所核对的项目里，未找到普通启动的 WorkBuddy 可直接订阅逐会话已读的现成组件。

## 本机验证

普通 macOS WorkBuddy 5.9.3 的会话页在可见且获得焦点后，会清除当前会话的未读标志。会话结果的更新时间保持原值。这个行为与官方任务列表描述的完成未读状态一致。 [WorkBuddy 任务管理](https://www.workbuddy.cn/docs/workbuddy/Task-Management)

默认本地数据库 `~/.workbuddy/workbuddy.db` 提供会话级未读标志、状态和更新时间。归档和删除也可能清掉未读标志，因此观察到已读后仍需核对会话状态、结果时间和归属。

隔离 SQLite 实验中，写端把 A 从未读改为已读并提交到 WAL，主库文件哈希保持一致。`mode=ro` 读端能看见 A 的变化，B 保留未读。初始即已读、删除记录、结果时间变化的行均未被判作已查看。读连接执行写语句得到只读错误。实时读取使用正常的 WAL 只读连接，可感知新提交。 [SQLite WAL 只读连接](https://sqlite.org/wal.html#read_only_databases)

普通启动时，macOS 辅助功能接口未提供能与岛上提醒关联的会话标识。 [Apple 辅助功能接口](https://developer.apple.com/documentation/applicationservices/axuielement_h)

## 双会话实机验收

在 macOS WorkBuddy 5.9.3（版本与构建号均为 5.9.3）使用 A、B 两条专用会话。临时探针只将带测试标记的真实 Hook 元数据转交隔离 AppModel，并按这两条会话的 ID 查询真实库。实测期间临时关闭运行中岛的应用级自动收起。结束后 WorkBuddy Hook 配置原样恢复，岛的开关恢复开启。

| 实机步骤 | 隔离岛结果 |
| --- | --- |
| A、B 各完成一轮并停在空白任务页 | 两条未读提醒同时保留 |
| 从 WorkBuddy 侧栏打开 A | A 收起，B 未读保留 |
| A 生成新一轮并重新出现，重放上一轮真实的 A 确认 | A 新结果与 B 均保留 |
| 从 WorkBuddy 侧栏打开 B | B 收起，A 新结果保留 |
| 打开 A 的新结果 | A 独立收起 |

实测中，WorkBuddy 会话页获得焦点后写入已读时，macOS 的全局前台状态可能仍归属于其他应用。最终探针以 WorkBuddy 提交的逐会话已读为依据。真实完成记录的 `status` 为 `completed`，`updated_at` 晚于当轮提问，并且打开会话时结果元数据保持不变。

## 实现边界

- 已有 Hook 继续提供已结束的会话 ID 和轮次。候选读取只覆盖岛上仍保留的对应提醒。用正常 SQLite 只读连接检查已验证版本的结构，并查询必要字段。库缺失、结构变化、来源身份无法关联或查询失败时保留提醒。
- 为每条结束提醒记录对应结果的未读基线。仅同一会话从 `1` 变 `0`、来源记录仍有效且状态和结果时间未变时才有资格收起。应用结果前再核对岛内事件版本，避免把旧查看套到新一轮。删除、归档、换账号、数据库文件更换和未看到 `1` 的情况均保留提醒。 [Agent Companion 的同轮状态测试](https://github.com/changexbc/agent-companion/blob/14430ef9f3ec592f2c898fb088800cc7b7a70097/crates/agent-studio-core/src/codex_read_state.rs#L125-L174)
- 在结果到达和后续岛状态刷新时，只查询仍有未读提醒的会话。SQLite 可能先把变化写到 WAL，读取器使用 SQLite 自己的只读连接读取已提交记录。若用户很快打开、观察端没看到未读基线，该条提醒会保留。 [SQLite WAL 提交机制](https://sqlite.org/wal.html#how_wal_works)
- 首轮接入限定普通 macOS WorkBuddy 5.9.3 的本地会话。数据库是客户端内部结构，版本升级需要重验。WorkBuddy AI 和云任务不在这次接入范围内。
