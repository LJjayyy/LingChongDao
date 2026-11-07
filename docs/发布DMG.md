# DMG 构建与发布

灵宠岛沿用维护者 [ClearZip 的发布方式](https://github.com/LJjayyy/ClearZip/releases/tag/v1.0.0)：GitHub Releases 提供 Apple Silicon DMG 和 `SHA256SUMS.txt`，用户拖入“应用程序”安装。采用 ad hoc 签名，首次打开的系统提示按 Apple 官方说明处理。Developer ID 和公证可作为后续分发改进。

## 本地构建

在 Apple Silicon Mac 上准备 Swift 6 工具链和 Python 3，配置更新签名公私钥后运行：

```sh
export LINGCHONGDAO_SPARKLE_PUBLIC_KEY="公钥的 Base64"
# SPARKLE_PRIVATE_KEY 从受保护的环境注入，不要把实际值写入命令历史。
./scripts/package-dmg.sh
```

脚本先构建 Release App 与五个伴随插件，再生成压缩只读 DMG。版本取自构建产物的 `CFBundleShortVersionString`；当前输出为：

```text
dist/release/LingChongDao-0.1.45-macOS-arm64.dmg
dist/release/SHA256SUMS.txt
dist/release/appcast.xml
```

已有完整 App 时可运行 `./scripts/package-dmg.sh --no-build`。打包校验 App 身份、素材配置、arm64 架构和代码签名，复制后再次验证签名；DMG 生成后校验镜像并计算 SHA-256。

镜像包含：

- `灵宠岛.app`：包含老板鼠动画、应用标识、helper 和五个插件包。
- `Applications`：指向 `/Applications` 的拖放安装入口。
- `安装说明.txt`、`LICENSE.txt`、`THIRD_PARTY_NOTICES.md`。
- `PRIVACY.md`、`SECURITY.md` 和 `docs/卸载与数据清理.md`，便于离线查看数据与卸载说明。

核对下载或本地产物：

```sh
cd dist/release
shasum -a 256 -c SHA256SUMS.txt
```

该校验文件包含最近一次打包的 DMG 和 appcast.xml；本地保留的其他版本不会被删除。appcast 中的 DMG 签名会先用 App 内嵌公钥验证，公私钥不匹配、缺钥或构建号未递增均失败。

## GitHub 发布

仓库推送与 App 版本一致的 `vX.Y.Z` 标签后，`.github/workflows/release.yml` 自动构建发布。也可在 Actions 手动指定一个已经存在的版本标签。

工作流从标签获取源码，使用 `macos-15` ARM runner，校验标签、架构和 App 版本，运行公开源码检查、串行隔离验证与更新签名验证，再生成 DMG 和 appcast。构建任务只有读取权限；发布任务获取该构建的确切 artifact ID，复核 SHA-256 和标签提交，先建立草稿 Release，确认 DMG、校验文件和 appcast 附件齐全后再发布并设为 latest。已有同名 Release（包括失败遗留草稿）时失败，不替换旧附件。稳定发布工作流串行执行，避免不同版本竞争 latest。

当前版本为 `0.1.45`（build `46`），版本号在 `scripts/build-app.sh` 的 Info.plist 中维护。后续发布前同步更新版本和 `docs/RELEASE-NOTES.md`，再创建对应标签。

本地生成 DMG 不会上传 GitHub、安装 App 或修改来源插件配置。[GitHub 仓库](https://github.com/LJjayyy/LingChongDao)、Release 与安装包均公开可见；普通源码推送不会创建 Release，推送版本标签才会触发发布工作流。

## 用户安装流程

用户从 Releases 下载 DMG，打开后拖入“应用程序”，启动灵宠岛，再在“连接的应用”接入自己的 AI 工具。Swift、Python、Node 都不属于普通用户安装步骤。

首次打开若被 macOS 拦截，请确认下载来源后，按 [Apple 官方说明](https://support.apple.com/zh-cn/102445)处理。未含更新器的旧版本仍需手动安装一次新版。后续正式版静默检查 GitHub appcast，有新版仅在工作台版本号旁显示红点；点击后由用户决定是否下载安装及重启。当前任务列表只保存在内存中，重启后不恢复。

GitHub runner 标签依据 [官方 runner 文档](https://docs.github.com/en/actions/how-tos/write-workflows/choose-where-workflows-run/choose-the-runner-for-a-job)核对；动作版本与 ClearZip 现有发布流程一致。线上构建与发布的实际结果可在 [Actions](https://github.com/LJjayyy/LingChongDao/actions/workflows/release.yml)查看。


## 更新签名初始化

使用项目锁定的 Sparkle 2.10.0 官方工具。先运行 `swift package resolve`，工具位于 `.build/artifacts/sparkle/Sparkle/bin/`；SwiftPM 按其包清单校验二进制 ZIP。

1. 本项目固定密钥保存在维护者登录钥匙串的 `LJjayyy.LingChongDao` account。使用 `.build/artifacts/sparkle/Sparkle/bin/generate_keys --account LJjayyy.LingChongDao -p` 读取公钥；初始化新环境时应导入已备份的同一密钥，不能为已有用户重新生成一对。
2. 将公钥配置为 GitHub Actions 仓库变量 `SPARKLE_PUBLIC_KEY`。本地 Release 构建对应环境变量为 `LINGCHONGDAO_SPARKLE_PUBLIC_KEY`。
3. 如由 CI 签名，用官方 `generate_keys --account LJjayyy.LingChongDao -x` 导出私钥到受保护临时文件，将其 Base64 文本配置为 Actions Secret `SPARKLE_PRIVATE_KEY`。私钥不要提交、贴入 issue、输出到日志或与公开安装包一起分发；另做离线备份。初始化只需一次，不能每个版本换钥匙。
4. 发布任务通过标准输入把私钥交给 `sign_update --ed-key-file -`，不放进命令参数；签名完成后使用 CryptoKit 对照 App 内嵌公钥验签。脚本接受 Sparkle 新版 32 字节 seed 的 Base64 导出格式（依据固定版本 `common_cli/Secret.swift`，工具报错中的长度提示并不准确）。

发布工作流自动下载上一正式版的 appcast，保留旧系统兼容项，并要求版本号和构建号严格增加。首次迁移允许旧版 `<=0.1.42` 没有 appcast；此后缺少清单会阻止发布。只把含完整更新附件的正式版设为 latest。固定入口为 `https://github.com/LJjayyy/LingChongDao/releases/latest/download/appcast.xml`，清单中的安装包 URL 必须指向具体版本。

本地连续签包时，可设置 `LINGCHONGDAO_PREVIOUS_APPCAST` 指向上一发布清单以执行同样的历史检查。正式发布前必须验证真实旧 App → 新 App 的升级、保持唤醒恢复和插件兼容；当前 ad hoc 签名不等于 Developer ID 签名或 Apple 公证。

## 普通 CI 与一次性测试密钥

普通分支和 PR 验证不使用生产签名秘密。它通过 `Tests/UpdateReleaseVerification/generate-test-key.swift` 在 runner 临时目录生成一次性密钥，给 App 写入 `LingChongDaoUpdateTesting=true` 以禁用生产更新，再验证 Release 打包和签名。该测试安装包不上传为开发产物，结束时删除密钥。

本地可运行 `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s Tests/UpdateReleaseVerification`，验证版本排序、历史保留、外部资产拒绝、缺钥失败、真实 Ed25519 验签与篡改拒绝。测试密钥不进入钥匙串或仓库。
