# DMG 构建与发布

灵宠岛沿用维护者 [ClearZip 的发布方式](https://github.com/LJjayyy/ClearZip/releases/tag/v1.0.0)：GitHub Releases 提供 Apple Silicon DMG 和 `SHA256SUMS.txt`，用户拖入“应用程序”安装。采用 ad hoc 签名，首次打开的系统提示按 Apple 官方说明处理。Developer ID 和公证可作为后续分发改进。

## 本地构建

在 Apple Silicon Mac 上准备 Swift 6 工具链和 Python 3，运行：

```sh
./scripts/package-dmg.sh
```

脚本先构建 Release App 与五个伴随插件，再生成压缩只读 DMG。版本取自构建产物的 `CFBundleShortVersionString`；当前输出为：

```text
dist/release/LingChongDao-0.1.40-macOS-arm64.dmg
dist/release/SHA256SUMS.txt
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

该清单对应最近一次打包的 DMG；本地保留的其他版本不会被删除。

## GitHub 发布

仓库推送与 App 版本一致的 `vX.Y.Z` 标签后，`.github/workflows/release.yml` 自动构建发布。也可在 Actions 手动指定一个已经存在的版本标签。

工作流从标签获取源码，使用 `macos-15` ARM runner，校验标签、架构和 App 版本，运行公开源码检查和 24 项串行隔离验证，再生成 DMG。构建任务只有读取权限；发布任务获取该构建的确切 artifact ID，复核 SHA-256 和标签提交，再上传 DMG 与校验文件。已有同名 Release 时失败，不替换旧附件。

当前版本为 `0.1.40`（build `41`），版本号在 `scripts/build-app.sh` 的 Info.plist 中维护。后续发布前同步更新版本和 `docs/RELEASE-NOTES.md`，再创建对应标签。

本地生成 DMG 不会上传 GitHub、安装 App 或修改来源插件配置。当前 [GitHub 仓库](https://github.com/LJjayyy/LingChongDao)仅作私有预览；首次源码推送不会创建 Release，后续推送版本标签才会触发发布工作流。

## 用户安装流程

用户从 Releases 下载 DMG，打开后拖入“应用程序”，启动灵宠岛，再在“连接的应用”接入自己的 AI 工具。Swift、Python、Node 都不属于普通用户安装步骤。

首次打开若被 macOS 拦截，请确认下载来源后，按 [Apple 官方说明](https://support.apple.com/zh-cn/102445)处理。更新前先退出旧版，再拖入新版替换。当前需手动启动与更新。

GitHub runner 标签依据 [官方 runner 文档](https://docs.github.com/en/actions/how-tos/write-workflows/choose-where-workflows-run/choose-the-runner-for-a-job)核对；动作版本与 ClearZip 现有发布流程一致。GitHub 上的工作流尚需首个标签发布时实际验证，本机打包验证不等同于已完成线上发布。
