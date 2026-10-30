# Qoder CN 会话跳转调研

调研日期：2026-10-24。范围：本机已安装产品的只读程序包分析。没有读取用户聊天数据库、转录或消息内容，没有操作来源应用 UI、安装扩展或修改配置。以下结论为已安装版本静态代码能力，端到端实测应由主任务另行记录。

## 结论

| 来源 | 已证实入口 | 精度与边界 |
| --- | --- | --- |
| Qoder CN 0.4.11，`com.qodercn.app` | `qoder-cn://chat/open?sessionId=<sessionID>` | 指向已有会话，直接导航，不创建任务、不填入草稿、不执行任意命令。需登录且会话仍在当前账户可用列表。 |
| 同上，可选消息定位 | 加 `&requestSetId=<requestSetID>` | 来源内部将 requestSetId 映射到 turnId；找不到轮次仍打开会话并提示。尚未证明灵宠岛现有 Hook turnID 与 requestSetId 同义，因此本次实现应省略。 |
| Qoder CN IDE 1.36.0，`com.aliyun.lingma.ide` | 将存在的 cwd 文件夹作为 file URL，显式交给此应用打开 | 打开项目；如果该单文件夹工作区已经打开，则激活对应窗口。不能承诺定位聊天中的具体会话。 |
| IDE 通用命令入口 | `qoder-cn-ide://aicoding.aicoding-deeplink/execute-command?command=aicoding.chat.history&args=<Base64 JSON array>` | 内部确实支持 history(sessionID, ASSISTANT) 命令，但每次来源应用会展示命令确认，而且外部扩展 URI 可能还触发信任提示。不是本次默认方案。 |

## 桌面版：真实外部入口

Info.plist 注册 `qoder-cn`。主程序 `app.asar/out/main/electronMain.js` 中的链路为：Electron `open-url` → ingress `P1x.acceptUrl` → router `T1f.route` → 专用 parser `S1f.parse` → `Y40.processNext` → renderer action。

`S1f.parse` 只接受 hostname `chat`、pathname `/open`。query 必须且只能包含一个 `sessionId` 和最多一个 `requestSetId`：

- sessionId：`^[a-zA-Z0-9_-]{1,128}$`。
- requestSetId：`^[a-zA-Z0-9._:-]{1,128}$`。
- router 禁止 username/password/port/hash；拒绝无效编码、前后空白、超长 URL。
- `Y40.processNext` 调用 `chatSessionService.listSessionSummaries([sessionId])`，不存在时发出打开失败动作。
- renderer `out/renderer/assets/C2dqRQMK.js` 收到 `chat.open` 后直接 `navigation.push` 到 `chatSession`、`surface: conversation` 并发出 acknowledge；没有通用命令执行确认步骤。
- 同一个原始 URL 在 5 秒内去重，队列和动作均有过期限制，重复连点不代表每次都会重新导航。

Hook 侧已经携带 `session_id`，灵宠岛 `HookNormalizer` 保存为 sessionID；桌面主程序传给 SDK 的 `sessionId` 同样来源于其会话结构。因此这是可用的关联字段。现有 `turnID`、threadID 不应未经证明代替 requestSetId。来源更换账户、删除会话或 Hook 属于外部 CLI 会话时，来源应用可拒绝不存在的 session。

旧的 `qoder-cn-app://renderer/index.html?...#/chat/<id>?surface=conversation` 是内部 renderer 协议，不在外部 Info.plist 的 URL schemes 中；不能作为系统打开链接使用。

## 双应用协议冲突

桌面版注册 `qoder-cn`；IDE 同时注册 `qoder-cn-ide` 和 `qoder-cn`。因此不能只把 `qoder-cn://...` 交给系统默认 handler：系统可能把桌面消息送进 IDE。灵宠岛应指定 detected desktop applicationURL（本机为 `/Applications/Qoder CN.app`），同时检查 bundle ID，而不是依赖默认 scheme 归属。

## IDE：项目窗口回退

IDE `out/main.js` 中：

1. Electron `open-file` 事件规范化路径，100ms 后调用 windowsMainService.open，携带 `urisToOpen` 和 `preferNewWindow: true`。
2. `resolveOpenable` → `doResolveFilePath` 使用 stat 确认目录，并转换为 folder workspace。
3. `doOpen` 对目录 URI 去重，借助 `ao` 比较现有窗口的单文件夹 workspace URI；匹配时 `doOpenFilesInExistingWindow` → `focusMainOrChildWindow`，不再重复打开同目录。
4. 不匹配时 `doOpenFolderOrWorkspace` 打开目录。是否新窗口遵从 `window.openFoldersInNewWindow`；默认倾向新窗口。

因此可用操作是：验证本地 cwd 存在且为目录 → file URL → 显式交给 IDE applicationURL。需要把按钮和说明标为“打开项目”。多根 `.code-workspace` 的某个子目录不等于整个 workspace URI，不能承诺复用；远程 cwd、已删除目录、空 cwd 应退回仅激活应用，不能用 shell 拼接或猜测目录。

IDE 内置扩展 `aicoding.aicoding-deeplink` 将 URI 解析为 path/query，再发送 `deeplink.handle`。该版本注册的专用路径包含 `/chat`、`/quest`、`/newchat`、`/rule`、`/command`、`/execute-command`、`/guide`、`/plugin/install` 等；未发现专用“只打开已有 session”入口。`/chat` 要求 text，主要用于新建或预填，不能替代现有任务导航。另一个 `aicoding-agent` URI handler 仅处理登录回调。

## 本次证据文件

- `/Applications/Qoder CN.app/Contents/Info.plist`。
- `/Applications/Qoder CN.app/Contents/Resources/app.asar` 的 `out/main/electronMain.js`、`out/renderer/assets/C2dqRQMK.js`、`out/renderer/assets/Cux9x6wn.js`。
- `/Applications/Qoder CN IDE.app/Contents/Info.plist`。
- `/Applications/Qoder CN IDE.app/Contents/Resources/app/extensions/aicoding-deeplink/package.json`、`out/extension.js`。
- `/Applications/Qoder CN IDE.app/Contents/Resources/app/extensions/aicoding-agent/dist/extension.js`。
- `/Applications/Qoder CN IDE.app/Contents/Resources/app/out/main.js`、`out/vs/workbench/workbench.desktop.main.js`。

原始程序包未修改。桌面包中的字符串解码仅在 `/tmp` 对分离的静态字符串函数执行，没有运行应用主模块。不是公开稳定 API 承诺；来源应用升级后需要重新核验 parser 和 handler。

## 2026-10-25 补充：定时任务会话的边界与处置

用户实测：定时任务（如「每天执行万和 E 学」）在岛上行点击后，Qoder CN 弹「无法打开该会话。请确认会话存在且当前账号可以访问。」。

证据（只读诊断，未读聊天内容）：

- `~/.qoder-cn/logs/sessions/-/…/segments/*.jsonl` 的 `hook.started` 记录含完整 `hook_input`。定时任务会话（session_id 即任务运行 UUID，如 `a0f35d06-…`）与普通桌面聊天的载荷**字段完全同形**：`session_id`、`transcript_path`、`cwd`、`hook_event_name`、`permission_mode`、`prompt`、`request_set_id`；`SessionStart.source` 两边同为 `startup`/`resume`。Hook 通道内没有可用判别字段。
- 定时/Quest/无头 CLI 会话的 `cwd` 全部位于 Qoder 自动创建的任务工作区 `…/Documents/Qoder/<yyyy-MM-dd>/<短十六进制 ID>/`（样本 4/4）；普通聊天的 `cwd` 是真实项目目录或用户主目录（样本 3/3）。会话 ID 两边都是 UUID，格式无法区分。
- 桌面深链 parser（前文 `S1f`）仅接受 `chat/open`，没有任务类路由；CLI `--list-sessions` 是项目级 CLI 会话列表，不能预检桌面聊天列表。

处置：`SessionNavigation` 对 `cwd` 命中 `Documents/Qoder/<日期>/<短十六进制>` 形态的会话不再构造 `qoder-cn://chat/open`，点击回退为「打开应用」（不报错、不误标已读）。误判方向是安全的：把可打开的聊天判成任务只会降级为打开应用，不会产生比现状更差的结果。若 Qoder 日后提供任务深链或在 Hook 载荷中给出任务标记，应替换此路径形态启发式。验证：`./scripts/verify-navigation.sh`（含任务工作区正反用例）。
