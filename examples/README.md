# 协议样例与交互预览

这些 JSON 仅用于展示原始 Hook 输入格式；helper 不执行其中展示的命令。

| 文件 | 用途 |
| --- | --- |
| `running.json` | 注入合成的运行状态。 |
| `completed.json` | 注入合成的结束状态。 |
| `approval.json` | 简单 Bash 权限事件的原始格式，缺少真实回合/审查上下文时回退来源。 |
| `complex-approval.json` | 复杂权限事件的原始格式，不代表可在岛内批准。 |

希望体验批准、拒绝、问答与草稿，请在灵宠岛“任务总览 → 交互预览”选择状态。该预览使用独立合成模型，不执行真实任务。

`--send-fixture` 仍受生产身份、审查者和有效期判断约束，不会因为输入来自文件而跳过检查。真实审批链路的自动验证使用 `Tests/VerificationSupport/CodexReviewFixture.swift` 等隔离夹具；不要将自己的 transcript 或来源配置放进示例目录。
