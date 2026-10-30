# 灵宠岛 Codex 插件接入

从应用 0.1.15 起，Codex 统一使用插件。连接页保留一键安装、修复和卸载；Qoder CN / IDE 延续原有接入方式。

## 一键流程

1. 检查完整插件包和本机 Codex CLI。
2. 将插件放到本机持久目录，校验归属与内容；拒绝同名未知来源。
3. 使用官方 CLI 添加本地 marketplace 并安装插件。
4. 读取 `plugin list --marketplace lingchongdao-local --json`，核对安装和启用状态。
5. 成功后备份并清理灵宠岛自己管理的旧直接 Hook，保留其他 Hook；失败保留旧接入。
6. 用户在 Codex 中审查 Hooks，使用新会话验证活动。

导出仍可作为手动安装方式，但不代表自动安装或迁移。禁用、卸载、未审查、尚未收到新活动分别呈现，不以文件存在冒充接入成功。

## 已核实接口

2026-10-24 本机 Codex CLI 0.163.0-alpha.11.2 已在临时 HOME 下实际验证 marketplace add → plugin add → plugin list，结果为 installed=true、enabled=true。命令通过参数数组调用，HOME/CODEX_HOME 显式指定，执行有超时和输出上限，不读取或改写 Hook 信任数据库。

[官方插件文档](https://developers.openai.com/plugins/build/plugins) 描述本地 marketplace、缓存与安装方式；CLI 当前 `plugin add` 与 JSON 字段以本机帮助和隔离安装结果为准。包含 lifecycle hooks 的插件仍采用本地分发，见 [官方提交限制](https://developers.openai.com/plugins/deploy/submission)。
