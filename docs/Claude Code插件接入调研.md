# Claude Code 插件接入调研

当前版本：灵宠岛 0.1.32 / Claude 插件 1.1.1 已支持岛内单次审批，最新实现与实测见文末「岛内单次审批与等待状态修正」。

调研日期：2026 年 10 月 27 日。范围为 Anthropic 的 Claude Code（CLI、桌面 Code 本地会话和相关扩展），不是 Claude 普通聊天或 Cowork；初次调研仅查阅官方文档和项目代码；后续实现及本机验收见文末。

## 结论

**可以采用 Claude Code 原生插件封装 Hooks 接入灵宠岛。** 插件是可安装的目录，能包含 Hooks；Hook 可以通过本地命令读取事件并转发至灵宠岛已有的本地桥。Claude Code 桌面的本地和 SSH 会话提供插件管理，CLI 和桌面本地会话的用户级插件共享设置。能加载插件不代表已证明灵宠岛现有代码直接兼容，仍需要独立适配与真实环境验收。[插件概览](https://code.claude.com/docs/en/plugins)、[桌面插件](https://code.claude.com/docs/en/desktop#install-plugins)、[Hooks 参考](https://code.claude.com/docs/en/hooks)

## 能力与边界

| 需求 | 官方文档提供的能力与建议 |
| --- | --- |
| 插件打包 | 可将 Hook 放在插件的 `hooks/hooks.json` 中，并通过 `${CLAUDE_PLUGIN_ROOT}` 引用插件内文件。开发时可用 `claude --plugin-dir` 加载本地目录；正式分发可配置 marketplace，按用户、项目或本地范围安装。插件在启动或重新加载时进入会话。[插件创建](https://code.claude.com/docs/en/plugins)、[插件概览](https://code.claude.com/docs/en/plugins#make-an-installed-plugin-available-in-your-session)、[Marketplace](https://code.claude.com/docs/en/plugin-marketplaces) |
| 会话及运行状态 | `SessionStart`、`UserPromptSubmit`、`PreToolUse`、`PostToolUse`、`Stop`、`StopFailure`、`SessionEnd` 等提供状态信号；命令 Hook 从 stdin 接收 JSON，公共字段包含 `session_id`、`cwd` 和事件名。`Stop` 代表一轮停止，不应直接视作任务成功；`SessionEnd` 的 `reason` 可能是清空、切换会话或退出，也不能等同成功。[Hooks 参考](https://code.claude.com/docs/en/hooks#hook-input-and-output)、[Stop](https://code.claude.com/docs/en/hooks#stop)、[SessionEnd](https://code.claude.com/docs/en/hooks#sessionend) |
| 审批 | `PermissionRequest` 在权限提示前触发，可返回 `hookSpecificOutput.decision.behavior` 的 `allow` 或 `deny`。输入没有 `tool_use_id`，并行请求须由本地桥建立独立请求关联；`allow` 仍受拒绝规则约束。沙箱网络权限请求不触发该事件，官方建议从 `permission_prompt` 通知获得信号。需要实测原会话与灵宠岛同时显示、竞争响应、超时及回退。[权限 Hook](https://code.claude.com/docs/en/hooks#permissionrequest) |
| 通知 | `Notification` 带 `message`、可选 `title` 与 `notification_type`。`permission_prompt` 有延迟；`idle_prompt` 通常在响应结束约 60 秒后且满足条件时触发，因此不应当作实时通用状态源。[通知](https://code.claude.com/docs/en/hooks#notification) |
| 会话范围 | 桌面插件管理支持本地和 SSH 会话，但 SSH Hook 在远程机器执行，不能假设可以访问 Mac 本地 Unix socket；云端会话不会加载本机安装的插件，WSL 会话不支持插件。[桌面文档](https://code.claude.com/docs/en/desktop#install-plugins)、[插件范围](https://code.claude.com/docs/en/plugins#understand-install-scopes) |
| 普通提问及跳转 | Hooks 支持工具与通知事件并不证明可以可靠回答所有普通问题，也不证明有可用的桌面会话深链。应先回到来源应用处理，并单独验证会话定位；不要承诺全量岛内问答或精准跳转。[Hooks 参考](https://code.claude.com/docs/en/hooks) |

## 建议实施与验收

1. 增加 Claude Code 独立 provider 和插件包；由 command Hook 将 JSON 交给现有 `lingchongdao-hook`，扩展标准化及连接管理，不把 Claude 数据误归入 Codex 或 Qoder。只采集状态必需字段，避免默认读取会话 transcript。
2. 先验证只读状态：安装后新建和恢复本地会话，覆盖多会话、提交、工具执行、停止、失败、清空及退出；记录 CLI、桌面客户端版本及各事件实际载荷。运行中的会话加载时机须另测。
3. 再用同步 Hook 验证简单审批：以独立请求 ID、会话 ID 和连接身份关联，验证允许、拒绝、原端先处理、超时、应用退出等情况；失联时回退原工具处理，不自动批准。`PermissionRequest` 缺失工具调用 ID，不能把会话 ID 当成唯一请求 ID。
4. 最后验证插件安装、升级、禁用和卸载与其他 Hook 共存，以及本地路径变化、权限、桌面进程来源、来源唤起；远程及云端单列能力边界。尚无真实环境运行证据时，以文档能力和待验证事项标识。

官方指出 command Hook 在 macOS/Linux 无控制终端运行；`SessionEnd` 默认总预算较短，插件自身设置的 timeout 不会提高该总预算，转发需快速且不能依赖交互终端。[Hook 执行和超时](https://code.claude.com/docs/en/hooks#hook-input-and-output)、[SessionEnd](https://code.claude.com/docs/en/hooks#sessionend)


## 2026-10-27：首版实现与本机验收

实现版本：灵宠岛 **0.1.30（构建 31）**。本机 Claude App **3.6556.2**，由 App 下载的 Claude Code 引擎为 **2.1.304**；本机 PATH 未安装独立 `claude` 命令。本次真实任务使用用户已配置的模型/网关，不改变模型和账户配置。

### 已交付行为

- 「连接的应用 → Claude Code」使用现有卡片样式，一键安装、更新、修复、卸载和手动导出。市场包位于 `integrations/claude-plugin`，用户级插件 ID 为 `lingchongdao@lingchongdao-local`。
- 优先检测 PATH 中的 Claude CLI；未找到时从 Claude App 的版本化本地引擎目录选用 CLI。只执行插件管理命令，不发起独立模型任务。`CLAUDE_CONFIG_DIR` 在绝对路径时受尊重。
- 状态桥覆盖 11 项事件；插件**不注册 PermissionRequest**。通知只作为观测，不能把已结束任务恢复成运行中；`StopFailure` 记录本轮错误，`Stop` 记作中性的「本轮结束」，子任务结束不关闭主任务。
- 来源依据 helper 的进程祖先和应用 Bundle ID 识别，可区分 Claude App、VS Code、Cursor、常用 JetBrains IDE 以及 Terminal / iTerm / Warp。不能确认宿主时显示来源待识别，避免误跳转。点击任务只打开已确认的来源应用。
- 插件输出始终为空对象，不返回权限决定或附加上下文。AskUserQuestion 只显示回来源回答；审批仍由 Claude 处理。桥未运行时快速返回，不阻塞来源。

### 真实 Claude App 验收

1. 从本机已安装的灵宠岛连接卡片点击「安装插件」，卡片由「未连接」变为「已安装，待验证」，随后重启 Claude App。
2. 在 Claude App 的 **Code → This computer** 选择独立的 `/private/tmp/lingchongdao-claude-acceptance` 空目录。发起只运行 `pwd`、`sleep 15`，最后回复 `LCD_ACCEPTANCE_DONE` 的任务。
3. 执行期间，灵宠岛任务总览显示该提交文本、「正在执行」和 **Claude App · Code · lingchongdao-claude-acceptance**；连接卡片变为「已收到活动」。确认来自真实 App 的 Hook，而非发送 fixture。
4. Claude 执行两个命令并返回 `LCD_ACCEPTANCE_DONE`；灵宠岛随后显示「本轮结束」，没有误报为任务成功。
5. 点击灵宠岛该任务的「打开应用」，实际返回 Claude App，能看到任务结果。会话深链不属于本版承诺。

### 自动校验

- `scripts/verify-claude-plugin.sh <claude-cli>`：状态映射、普通问题返回来源、权限事件不可操作、子任务隔离、宿主身份分离；用真实 Claude CLI 在私有临时配置目录执行安装、跨版本更新、同版本文件修复和卸载，校验原有 Hook / 权限规则 / 全局禁用设置保留。全部通过，不调用模型。
- 现有核心与连接检查：43 项通过；来源识别检查：78 项通过；导航检查：60 项通过；来源关注同步检查：44 项通过。
- 工作台导航性能在无并行构建时连续三轮通过，1000pt 和 850pt 窗口的切换均低于现有 100ms 阈值。首次与发行版编译同时运行时的冷启动测得 236ms，独立复测未重现。
- 发行版包含 Claude 插件目录和导出 ZIP，并通过本地代码签名校验；最终版已安装到 `/Applications/灵宠岛.app`。

本次真人客户端验收覆盖 Claude App 的 Code 本地会话。CLI 和 IDE 的安装共用配置及来源识别经过隔离 CLI 与合成进程校验，未宣称已逐一完成所有 IDE 的真实会话测试。Chat、Cowork、云端、SSH 和容器保持在首版范围外。


## 2026-10-27：插件图标与 Claude App 的本地列表限制

用户反馈 Claude App 的「From marketplaces you added」中灵宠岛显示通用插头占位图。已在本机 Claude App 3.6556.2 复现。

插件包 1.0.1 已加入与其他来源一致的 `assets/icon.png`（256×256），并在 `.claude-plugin/plugin.json` 声明 `icon: "./assets/icon.png"`；灵宠岛 0.1.31（构建 32）把素材纳入完整性检查、图标单独变化的更新检测与手动导出。真实 Claude CLI 验证该 manifest 通过，隔离的安装、更新、图标单独变更、修复、卸载检查通过；本机连接卡片的一键更新也已执行。

**但本机 Claude App 的本地插件列表仍显示通用占位图，未宣称已修复视觉问题。** 已完全退出并重启 Claude 后重新打开 Customize → Plugins，结果相同。

证据与原因：

- 官方 manifest 文档将 `icon` 列在 Directory listing fields 中，说明 Anthropic 插件目录读取它，Claude Code 在加载时忽略这些展示字段；marketplace entry 不能代替 `plugin.json` 设置 `icon`。[官方 manifest 参考](https://code.claude.com/docs/en/plugins/manifest-reference#directory-listing-fields)
- 本机 `/Applications/Claude.app/Contents/Resources/app.asar`，release `20c019a1e61fa5b687616af57d31f97bb3181723`：`index.chunk-DoK94jax.js` 的 `entryToPluginInfo` 只返回身份、路径、启用、时间、描述、版本和作者；`index.chunk-BU5jS0Mq.js` 的 `q` 构造插件展示数据，同样没有插件级图标。`index.chunk-jPKPzV-P.js` 中对应插件 IPC schema 也没有插件级 `icon`（其中 `clis[].icon` 属于另一种 CLI 组件配置，不是 Hook 插件图标）。
- 因此这不是漏复制素材或缓存未刷新的问题；当前本地插件列表缺少传递自定义图标的通道。保留规范的图标声明和素材，供支持该字段的目录或未来客户端使用。没有改写 Claude 的应用包、私有状态或添加虚假组件来改变外观。


## 2026-10-27：岛内单次审批与等待状态修正

交付版本：灵宠岛 **0.1.32（构建 33）**，Claude 插件 **1.1.1**。当前能力覆盖本机来源的 PermissionRequest；首批允许单次批准可完整展示的简单 Bash 与 WebSearch，其他工具或未知参数只允许拒绝及返回来源。输出仅包含 `behavior: allow/deny` 和拒绝说明，不发送 `updatedPermissions`，不写长期权限规则。Hook 最多等待 90 秒，退出、断线、超时交回来源流程。

### 关联与状态

- Claude 原生 PermissionRequest 缺少 `tool_use_id`。helper 为每次调用生成新的 UUID，并将它与同一个 Socket envelope 的 requestID 绑定；应用再次校验两者相等。相同命令、相同查询也不会复用审批 ID。
- 同一会话的并发审批进入队列，依次展示；子任务权限请求可操作，子任务停止、其他工具结果、主任务停止不会误清其他仍存活的审批通道。响应、超时和来源取消只影响对应请求；旧卡片不能批准新请求。
- 真正的审批进入 `waitingApproval`，从绿色运行状态转为橙色待批准。没有可回包通道的原生 `permission_prompt` 则显示只读待确认，不能凭通知生成批准/拒绝结果。
- 点击「回 Claude 处理」会先释放这一条 Hook，再打开已识别的来源应用；岛内保留没有批准/拒绝按钮的只读提示。主任务活动、重新提交、结束或提示超时会清除它。原端拒绝/中断有时不派发后续终态 Hook，不能承诺这类只读提示逐条自动同步；提供「关闭提示」手动收起，不向 Claude 发送任何权限决定。

### 本机 Claude App 3.6556.2 / 引擎 2.1.304 实测

验收使用 `/private/tmp/lingchongdao-claude-acceptance` 中新建的独立本机会话，不处理其他项目已有请求，也未重启正在使用的 Claude App。

1. Claude 发起 WebSearch，灵宠岛显示橙色待批准，完整展示查询和「批准一次 / 拒绝 / 回 Claude 处理」。从岛内批准一次后，Claude 实际执行搜索，原生权限卡片撤销，返回 `LCD_WEBSEARCH_ALLOWED`。
2. 同一会话再次发起不同查询，仍需要权限，证明没有改成长期允许。岛内点击拒绝后，Claude 返回 `LCD_WEBSEARCH_DENIED`，并明确收到灵宠岛拒绝且未重试。
3. 第三次请求点击「回 Claude 处理」后，岛内变为无操作能力的来源待确认提示，原生权限卡片保持可处理。在 Claude 原端拒绝后，该回合显示 Stopped；此路径没有收到完整结束事件，按上述只读提示边界处理。
4. 第四次请求不从岛内回退，直接在 Claude 原端先拒绝；存活的 Hook 被取消，岛内对应的批准/拒绝卡片随即撤销，回到其他正在运行的会话列表，不能继续操作旧审批。

### 校验

`scripts/verify-claude-approvals.sh` 的 13 项检查通过，使用真实 helper 进程与真实 Unix socket 驱动 AppModel，检查独立并发回包、批准、拒绝、来源回退、短观察连接、超时、来源取消、旧 UI 失效和只读提示关闭。`scripts/verify-claude-plugin.sh <cli>` 校验 Bash/WebSearch 预览、并发子任务队列、未知参数降级、状态映射、图标及真实 CLI 安装更新卸载。现有核心/连接 43 项与权限观察检查保持通过。

本次真实客户端闭环验收为 WebSearch。Bash 预览及协议经过自动校验；其他工具的批准、长期允许、来源普通问题回复不在本版支持范围。图标仍受上一节所述 Claude 本地列表展示能力限制。
