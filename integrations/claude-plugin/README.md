# 灵宠岛 Claude Code 插件

支持本机 Claude Code CLI、Claude App 的 Code 本地会话和本机 IDE 会话。灵宠岛内一键安装会将此本地市场注册到 Claude 的用户范围；可在 Claude 插件管理中禁用或卸载。安装后重启来源并开启新会话。

手动安装（将路径换为解压目录）：

```sh
claude plugin marketplace add /absolute/path/to/claude-plugin
claude plugin install lingchongdao@lingchongdao-local --scope user
```

同步会话、用户提交、工具活动、停止、失败、子任务和通知，并通过 PermissionRequest 提供可完整预览的 Bash / WebSearch 单次审批。岛内可以批准一次、拒绝或回 Claude 处理；未知参数、复杂请求和其他工具不在岛内批准，普通问题在 Claude 回答。每次 Hook 绑定独立审批 ID 和 Socket；并发请求排队展示，来源取消、断线或超时撤销操作，不修改长期权限规则、不注入上下文。`Stop` 表示本轮停止，不代表任务成功；`SessionEnd` 表示连接结束。

Hook 用当前用户目录下灵宠岛的 helper 和 Unix socket，审批最多等待 90 秒；桥未启动或 helper 缺失时返回 `{}` 交回来源处理。不读取 transcript，不运行独立模型请求。SSH、容器和云端的 Hook 无法直接访问本机 socket，不属于本版支持范围。

官方契约：[插件](https://code.claude.com/docs/en/plugins)、[Hooks](https://code.claude.com/docs/en/hooks)、[桌面](https://code.claude.com/docs/en/desktop)。


图标素材随包提供，并按官方 manifest 声明 `icon`。Claude App 3.6556.2 的本地插件列表尚不读取插件级自定义图标，仍可能显示通用占位图；这一显示限制不影响 Hook 接入。验收证据见仓库调研文档。


交回来源后显示无批准/拒绝按钮的待确认提示。来源继续执行、新一轮提交或结束事件会清除它；某些原端中断不发送终态 Hook 时，可以手动关闭提示，或在提示过期后自动收起。
