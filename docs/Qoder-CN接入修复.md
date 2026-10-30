# Qoder CN 接入修复（0.1.1）

0.1.0 将 Qoder CN 的用户 Hook 错写到 Qoder IDE 的默认目录 `~/.qoder/settings.json`。当前独立 Qoder CN 0.4.9 读取 `~/.qoder-cn/settings.json`，因此配置检查与本地 helper ping 正常，客户端却未加载这些 Hook。

0.1.1 使用 CN 专用目录，并识别 `QODERCN_CONFIG_DIR`、`QODERCN_CLI_HOME` 和 `QODERCN_CONFIG_DIR_NAME`。发现旧版本的精确受管命令后，连接预览会说明迁移路径；安装备份新旧文件、向 CN 合并 Hook，再从旧文件仅移除本应用管理的命令。无关设置与 Hook 保留，预览后文件变动会取消安装；中途失败保留历史命令身份以支持重试。

实机验证：

- 修复前 Qoder 刷新后仅显示原有 3 条插件 Hook，修复后显示 15 条。
- 在 Qoder 新建专用连接验证任务，仅执行 `sleep 8`，不读取/修改文件或访问网络。
- Qoder 回报连接验证完成；Hook 摘要为 SessionStart × 3、UserPromptSubmit × 3、PreToolUse、PostToolUse、Stop 全部成功。
- 灵宠岛收到真实活动，任务从正在执行回收到本轮结束。
- 对新旧配置中无关设置及无关 Hook 做摘要比较，迁移前后一致；两个文件均存在本次备份。
- 核心/连接独立验证 33 项通过，包含本次路径、覆盖规则、迁移、并发修改和失败重试回归。

路径依据来自本机 Qoder CN 0.4.9 安装包的 product 配置与用户设置服务：`cliConfigDirectoryName=.qoder-cn`、`cliEnvironmentPrefix=QODERCN`，服务在解析出的目录追加 `settings.json`。磁盘配置可见和实际 Runtime 执行分别验证，避免把安装成功当成连接成功。

## 0.2 插件化接入

0.1.x 把灵宠岛命令直接合并进 `~/.qoder-cn/settings.json` 的 `hooks`。0.2 改为 **Qoder 原生插件**：`integrations/qoder-plugin`（`.qoder-plugin/plugin.json` + `qoder-hooks.json` + `forward-hook.sh` + 图标）复制到 `Application Support/LingChongDao/qoder-plugin`，用 Qoder 自带 `qoderclicn plugins install <目录> -s user` 装为 `lingchongdao-qoder@local`，可在 Qoder 插件管理中开关/卸载。安装同时清理旧版配置 Hook（包括 0.1.0 误装的 `~/.qoder/settings.json`）。

验证：`plugins validate` 通过并加载 **12 个 Hook**；`plugins list --json` 显示 `displayName`、描述与 12 个事件；临时插件用相同 schema 实测 `SessionStart / UserPromptSubmit / PreToolUse / PostToolUse / Stop` 触发，`${QODER_PLUGIN_ROOT}` 替换生效；`forward-hook.sh` 在 helper 缺失时返回 `{}`。插件 Hook 会随 Qoder 原生插件机制自动生效，不再依赖 `settings.json` 的 Hook 配置。

## 2026-10-28 岛内审批复测

真实 Qoder App 的 PermissionRequest 不含工具 ID，旧版没有建立有效回传。应用 0.1.37 / 插件 0.1.1 通过独立连接 ID 修复，允许、拒绝和回来源均按预期控制了命令；但本机 Qoder App 0.4.11 在 Hook 直接决定后报 `waiting-user -> completed` 非法状态转换，完整桌面验收仍未通过。回来源 UI 处理可以正常结束。详见 [实机验收记录](Qoder岛内审批实机验收.md)。
