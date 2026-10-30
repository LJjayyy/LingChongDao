# Codex 会话跳转调研

调研日期：2026-10-24。范围：当前 Mac 安装包静态代码、官方文档与官方源码。未读取用户聊天数据库、聊天日志或配置秘密，未启动或操作来源 UI。本文件记录研究时的证据与实现建议，不代表原生实机跳转已经完成。

## 结论

当前安装的 Codex 桌面可以通过外部 URL 打开已有本地任务，格式为 `codex://threads/<thread UUID>`。它不仅是界面内部链接：安装包 Info.plist 声明 `codex` scheme；主进程注册协议并接收操作系统 `open-url` 事件；解析器把 `threads` 路由转换为 `localConversation`；主进程再导航到 `/local/<UUID>`。[本机证据 A、B、C]

灵宠岛应在来源确认为当前 Codex 桌面、来源为本地、目标 ID 合法时，构造该 URL 并指定解析出的应用包接收。优先使用事件中的 `threadID`；若缺少，可用已知主会话 Codex Hook 的 `sessionID`。官方 Hook payload 将 `session_id` 定义为 `ThreadId`；官方主会话恢复测试也明确 `session_id == thread_id`。[官方源码 1、2]

该方案定位到对应会话，未找到通过此 URL 定位某个 turn、某条消息或滚动锚点的契约。因此产品应表述为“打开对应会话”，不能承诺定位到具体消息。

## 调用契约与边界

| 项目 | 已确认行为 | 实现建议 |
|---|---|---|
| 协议 | `codex:` | 固定生成，忽略事件里任意外部 URL |
| URL host | `threads` | 固定生成 |
| 路径 | `/01234567-89ab-cdef-0123-456789abcdef` | 只接受严格 UUID 语法，使用 URLComponents |
| UUID grammar | `^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$`，不区分大小写 | 与本机解析器保持一致，不允许路径分隔、转义或 `new` |
| 本地 host | 缺少 `hostId` 时可落本地；主进程会尝试查找已知 catalog 与连接 | 已知本地 Hook 不带 query；不要将灵宠岛 `localhost` 直接当 Codex hostId |
| 远程 host | 接受驼峰 `hostId`，并参与内部 catalog/connection 选择 | 灵宠岛自定义 `host`/`host_id` 不保证等于 Codex 内部 hostId；没有可信映射就回退打开来源应用 |
| 明确 threadID 与 sessionID 冲突 | 外部 parser 不处理两个 ID 的关系 | 优先显式 threadID，不通过用户标题、cwd 或当前窗口猜另一个任务 |
| 子代理 | 官方证明仅能支持 root session 映射，不能据此证明任意子代理 ID 都等于 root | 保留主会话身份；缺少可信 parent/root 映射时不猜测 |
| `com.openai.chat` | 本机未安装该 bundle，未建立其处理 `codex://threads` 的契约 | 不因都是 OpenAI 应用就套用当前 handler，保持应用级回退 |
| OS 完成回调 | 只表示系统接受/交给应用，不能证明来源页面已加载成功 | 可记录发送结果；失败回退唤起来源应用，显示无法定位的说明 |

主进程的 `m2e` host 选择会遍历 origin host、catalog 中该 thread 的 host、catalog 全部 host，再要求已知 host、有连接且有对应 catalog 记录。找不到时最终回退 `originHostId ?? "local"`。所以省略本地 host 是安全的常规形式；外部传入任意远程字符串并不能创建可用的 remote host。[本机证据 D]

`codex://chat` 没有在该版本 scheme parser 的 destination switch 中建立 local conversation 分支。`codex://threads/new` 是创建新任务入口，不能当定位失败的退路。`codex://threads/<id>?view=review` 是代码 review 辅助视图入口，本轮需求不需该 query。[本机证据 B、C]

## 当前本机证据

### A. 应用与 scheme

- 安装路径：`/Applications/ChatGPT.app`，没有单独的 `/Applications/Codex.app`。
- `/Applications/ChatGPT.app/Contents/Info.plist`：`CFBundleIdentifier=com.openai.codex`，`CFBundleExecutable=ChatGPT`，版本 `26.1016.62342`，构建 `21477`。
- `CFBundleURLTypes[0].CFBundleURLSchemes`：`codex`、`http`、`https`。

路径名称 ChatGPT.app 与 bundle ID com.openai.codex 并存，不能按文件名猜业务身份。

### B. 操作系统入口与 external parser

容器：`/Applications/ChatGPT.app/Contents/Resources/app.asar`。

条目 `.vite/build/bootstrap-DCRTDDSX.js`：

- 条目在 asar 的绝对数据偏移：`6224472`。
- SHA-256：`18ad69fcbc0ecda53536a78b83b6b76bdf2ae2dda6231c7f6f68334cbcc33d39`。
- 文件内 byte offset `1282`：`ce` 只接收 codex/codex-dev 协议，并要求无用户名、密码与端口。
- 文件内 byte offset `531602`：`case threads` 调用共享 parser `i.uo`，成功后返回 `kind: localConversation`；读取 `hostId` 与 `threadAccess` query。
- 文件内 byte offset `540980`：注册 `setAsDefaultProtocolClient`。
- 文件内 byte offset `541468`：`app.on(open-url, ...)` 调用上面的 route parser 并将 route 加入处理队列。

所有偏移为原始 UTF-8 文件内字节偏移，非显示行号。asar 条目数据绝对偏移 + 文件内字节偏移可复核目标片段。

### C. UUID parser 与 route builder

条目 `.vite/build/src-CSKkIr_z.js`：

- 条目在 asar 的绝对数据偏移：`12084447`。
- SHA-256：`4a939ae29c4f4010a62a7890797813363d4d2300afb43df4101872246cc7f0d6`。
- 文件内 byte offset `14796`：UUID 正则 `At` 与 `Mt` route schema。
- 文件内 byte offset `15616`：`Vt` 要求协议为 codex、host 为 threads，解析首段 UUID。
- 导出 `uo` 为 `Vt`，导出 `$a` 为 `Bt`；`Bt` 生成 `/local/<conversationId>`。

### D. 导航与 host 选择

条目 `.vite/build/main-JI9qDiXp.js`：

- 条目在 asar 的绝对数据偏移：`7884046`。
- SHA-256：`b8c5d07cc3c30fbf0abe729b05434e7d1ffa19ee6c4daa818ae8f855be66d1e1`。
- 文件内 byte offset `3708807`：`case localConversation` 使用 `i.$a(t.conversationId)`，按需附加 `hostId`，调用导航到该 route。
- 文件内 byte offset `3715673`：`m2e` 选择本地/远程 host，最后回退 origin 或 local。

## 官方来源

1. [openai/codex — codex-rs/hooks/src/types.rs](https://github.com/openai/codex/blob/main/codex-rs/hooks/src/types.rs)：通过 Context7 `/openai/codex` 当前文档提取。`HookPayload.session_id` 类型为 `ThreadId`。
2. [openai/codex — codex-rs/core/src/session/tests.rs](https://github.com/openai/codex/blob/main/codex-rs/core/src/session/tests.rs)：Context7 返回 `resumed_root_session_uses_thread_id_as_session_id` 测试，主会话恢复后的 session ID 与 thread ID 相同。
3. [openai/codex — codex-rs/hooks/src/schema.rs](https://github.com/openai/codex/blob/main/codex-rs/hooks/src/schema.rs)：Context7 返回 SessionStart、UserPromptSubmit、PermissionRequest、Stop 的 `session_id` 字段。
4. [openai/codex — codex-rs/tui/src/app/history_ui.rs](https://github.com/openai/codex/blob/main/codex-rs/tui/src/app/history_ui.rs)：Context7 返回 `open_desktop_thread`，直接生成 `codex://threads/{thread_id}` 并交给 OS 打开。这是跨进程入口用途的第一方佐证。
5. [OpenAI 当前 features 文档](https://learn.chatgpt.com/docs/features)：已实际打开 `https://developers.openai.com/codex/app/features`，当前重定向到此页。页内未建立外部 thread URL、hostId、具体消息锚点契约，不能拿此总览当稳定 public API 声明。

Context7 调用已执行 library 一次、docs 两次，没有 quota 错误。官方源码对应当前 main，未假定它与本机 alpha CLI 构建完全一致；精确 URL handler 以本机安装包静态证据为准。

## 灵宠岛现有数据与验证建议

研究时 `Sources/IslandCore/HookNormalizer.swift` 将 `thread_id/threadId/threadID` 保留在 threadID，并将 `session_id/sessionId/sessionID` 或 threadID 保留在 sessionID；`host/host_id` 缺失时归为 localhost。`Models.swift` 的 IslandSession 已有这些字段，无需读来源聊天数据库。

研究时 `Sources/LingChongDao/Models/AppModel.swift` 的 navigate 仅解析来源应用 URL 后 openApplication，因此多任务点击只激活来源应用。应先增加独立的、可测试的目的地解析，再复用所有消息入口；不应让标题、项目名称或工具事件改变路由身份。

重点验证：显式 thread UUID、session UUID fallback、不同 UUID 的两会话、不同来源应用、未知远程 host、非法 ID、系统打开失败、来源应用不存在。原生验收需在两个已有任务间切换后分别点击对应岛消息，确认会话确实切换；不要把“应用收到 OS 事件”当成 UI 定位验收。
