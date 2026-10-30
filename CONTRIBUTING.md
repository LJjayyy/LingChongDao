# 参与贡献

欢迎报告可复现的问题、改进文档或提交小范围修复。提交 Issue 时提供灵宠岛、macOS、来源应用版本、Mac 架构和最小复现步骤；请先脱敏私人聊天、命令、目录、令牌和会话 ID。安全问题使用 [私密报告渠道](SECURITY.md)。

## 构建与验证

当前面向 macOS 14+ 的 Apple Silicon Mac。源码构建需要 Swift 6 工具链（Xcode 或相应 Command Line Tools）及 Python 3；普通 DMG 用户不需要开发工具。

```sh
./scripts/build-app.sh release
./scripts/verify-all.sh
./scripts/package-dmg.sh --no-build
```

`verify-all.sh` 串行执行不需要真实来源 CLI 的验证，失败时返回非零状态。动效与布局检查需要活动的 macOS 图形会话；其窗口在屏幕外使用合成数据，不安装真实来源插件。运行这些时避免同时进行重型编译，以免干扰时序采样。完整 Xcode 环境还可运行 `swift test`。

本机默认严格检查布局 250ms 和导航 100ms 的性能预算。共享 GitHub runner 上，CI 与发布工作流设置 `LINGCHONGDAO_VERIFY_TIMING=report`：仍实际渲染页面、点击导航、核对截图中的选中状态，但绝对耗时只记录，不因虚拟机调度抖动阻止构建。状态、审批、插件、悬停、打包等其他检查仍正常判定成败。系统开启“减少动态效果”时，动效插值专项会明确标记跳过；应另在关闭该选项的本机运行 `verify-motion.sh`。

异步提醒与展开的正向验证等待真实状态变化，并设两秒上限；快速返回的取消操作在同一次主线程执行中完成，再等待检查结果，避免把共享 runner 的短暂调度延迟误判为功能错误。

`verify-claude-plugin.sh /absolute/path/to/claude` 需真实 Claude CLI，作为可选专项验证；`verify-pet-renderer.sh --live` 会额外只读本机当前宠物。它们不属于默认验证，不要在普通 CI 中假设用户装有来源工具。

## 改动边界

- 核心状态和桥接在 `Sources/IslandCore`，来源接入在 `Sources/LingChongDao/Connections`，宠物读取在 `Sources/IslandPets`，界面与原生窗口在 `Sources/LingChongDao`。
- 审批缺少身份、回合或支持的响应契约时回来源处理，不增加自动允许、模拟信任或演示豁免。Qoder 正式插件只观察权限状态。
- 配置修改保留其他 Hook 和设置、完成备份后再替换；未知文件、来源和符号链接应保留并报错。
- 修复行为问题时，在实际调用边界补充能复现问题的回归。说明改动原因、验证命令和没有验证的环境，避免夹带无关重构。
- 老板鼠动画和应用标识属于公开品牌素材；宣传工程、配乐、第三方宠物帧、本地备份和构建产物不提交。代码与素材范围见 [许可说明](THIRD_PARTY_NOTICES.md)。

首次推送前运行 `python3 scripts/verify-public-source.py` 检查候选文件、文档链接和常见凭据模式。该检查是启发式辅助，提交者仍需审阅实际 diff 和即将公开的文件。

版本在 `scripts/build-app.sh` 的 Info.plist 中维护，DMG 发布流程见 [发布说明](docs/发布DMG.md)。CI 使用合成数据验证，不以修改真实来源信任或电源设置换取通过。
