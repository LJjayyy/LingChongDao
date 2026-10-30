# 许可范围与第三方素材

本文件说明根目录 [MIT 许可证](LICENSE) 的适用范围，并记录随工程保存的素材来源。版权署名为 `Copyright (c) 2026 LJjayyy`，对应维护者的 [GitHub 账号](https://github.com/LJjayyy)。

老板鼠是灵宠岛的默认角色与品牌标识。公开源码及默认 App 包含 `assets/default-pet/`、`assets/app-icon/` 和五个接入插件中的老板鼠图标；默认构建直接打包这些素材。README 的 `assets/readme/` 另提供现有 30 秒产品介绍成片、封面和示例界面图。宣传源工程目录 `promo/`、素材备份 `local-assets.noindex/` 及相关历史截图仍由 Git 忽略。下方涉及这些忽略目录的路径仅作为本地来源记录，不是公开源码中的下载入口。

## 项目代码

除文件内另有声明或属于下面列出的例外外，根 MIT 许可证适用于本项目有权授权的原创源代码、配置、示例和配套文档，包括：

- `Sources/`、`Tests/`、`scripts/`、`examples/` 中的项目代码和文本配置。
- `integrations/` 中本项目编写的接入代码、Hook 配置和说明。
- `Package.swift`、`.gitignore`、`README.md` 及 `docs/` 中本项目编写的说明文字。
- `assets/README.md`、`scripts/PublicArtwork.swift` 及其生成的原创通用几何标识；默认 App 与插件使用的老板鼠图像另见下方品牌素材说明。
- `assets/readme/attention-flow.svg` 原创设计示意图，以及 `assets/readme/source/` 中的界面渲染代码。
- 由上述源代码编译得到的本项目可执行程序与库。

使用、修改和分发上述代码时，应按 MIT 正文保留版权和许可声明。根 MIT 许可证不变更任何第三方文件已有的许可，也不授予第三方品牌、商标或角色的使用权。

## 例外范围

以下内容不由根 MIT 许可证授权；使用或分发前需分别核对其原始条款和权利来源：

- `assets/default-pet/`、`assets/app-icon/` 中的品牌角色图像、动画图集和派生应用图标，以及五个接入插件中的老板鼠 `icon.png`。这些素材随本项目公开提供，不纳入代码的 MIT 授权；公开收录本身不授予设计中涉及的第三方角色或品牌权利。设计记录作为来源说明保留。
- `promo/` 全部内容，包括宣传源工程、复用模板、字体、图标、图片、音频和成片。
- `assets/readme/intro.mp4` 和 `intro-cover.png`：作为产品展示公开提供，包含的角色、品牌、字体渲染、配乐和音效分别保留原有权利，不纳入代码 MIT 授权。
- `assets/readme/overview.png`、`attention.png`、`boss-idle.png`、`connections.png`：当前产品视图的示例界面图，包含老板鼠和来源应用标识，各组成部分保留原有权利，不纳入代码 MIT 授权；任务与配置数据为隔离示例。
- `assets/readme/pet-family.png`：按作者要求，由其提供的个人桌面截图精修的灵宠合影，用于说明命名故事；其中的角色及品牌分别保留原有权利，不纳入代码 MIT 授权。此图为 README 展示素材，不随 App 或插件打包。
- 除上述原创通用几何标识和设计示意图外，其他目录中的图片、截图、字体、音频、视频，以及其中呈现的第三方角色和品牌。
- 引用、复制或改编的第三方内容；其原有版权与许可声明继续适用。

“收录在工程中”不表示已确认可公开再分发。“待核验”项目不因本文件或根 MIT 许可证获得额外授权；本清单也不替代其原始许可证正文。

## 素材清单

### 默认宠物与品牌图形

| 内容与位置 | 已记录的来源 | 当前许可状态 |
| --- | --- | --- |
| `assets/default-pet/` 中的老板鼠及动画 | 本项目通过 imagegen 制作；设计记录见同目录 `design.json`、`actions-design.json`、`performance-design.json`，包含 Jerry 角色参考 | 随公开源码与默认 App 提供；角色及相关权利的再分发范围待核验，排除于根 MIT 许可 |
| `assets/app-icon/` 与五个接入插件的 `icon.png` | 从老板鼠素材衍生；菜单栏图标制作记录见 `assets/app-icon/MenuBarIcon-design.md`，插件使用 iconset 的 256 × 256 图像 | 随公开源码、默认 App 和插件包提供；排除于根 MIT 许可 |
| `scripts/PublicArtwork.swift` 可单独生成的几何占位图 | 直接绘制圆角底板、胶囊和圆点，无角色或外部图片输入 | 本项目原创通用标识，MIT；默认构建不使用 |
| `docs/` 下的截图与宣传成片中的界面截图 | 本项目界面，可能包含来源应用的图标、宠物和品牌 | 各组成部分分别适用其权利范围；排除于根 MIT 许可 |
| `promo/2026-10-29/film/public/brand/pets/codex/`（24 张）及 `qoder/`（254 张） | 本机来源宠物；名称及时序记录在相邻 `manifest.json`，分别为“瓶盖汤姆”和“Q 达鸭” | 未找到逐项再分发授权证据，待核验；排除于根 MIT 许可 |
| `promo/2026-10-29/film/public/brand/` 中的来源应用标识 | Codex、Qoder、Claude 等第三方品牌 | 品牌和标识使用范围待核验；排除于根 MIT 许可 |

运行时从用户自己安装的应用读取宠物，不改变素材的许可。本项目不对这些来源素材授予再分发权。

### 字体

字体位于 `promo/2026-10-29/type-proposal/fonts/`。下载来源和版本记录见 `promo/2026-10-29/type-proposal/font-sources.json`。以下字体分别保留 SIL Open Font License 1.1，不使用根 MIT 许可证重新授权。

| 字体目录 | 版权声明来源 | 随工程保存的许可 |
| --- | --- | --- |
| `fraunces/` | The Fraunces Project Authors | `promo/2026-10-29/type-proposal/fonts/fraunces/OFL.txt` |
| `fredoka/` | The Fredoka Project Authors | `promo/2026-10-29/type-proposal/fonts/fredoka/OFL.txt` |
| `inter/` | The Inter Project Authors | `promo/2026-10-29/type-proposal/fonts/inter/OFL.txt` |
| `manrope/` | The Manrope Project Authors | `promo/2026-10-29/type-proposal/fonts/manrope/OFL.txt` |
| `noto-sans-sc/` | Adobe，含保留字体名称声明 | `promo/2026-10-29/type-proposal/fonts/noto-sans-sc/OFL.txt` |
| `nunito/` | The Nunito Project Authors | `promo/2026-10-29/type-proposal/fonts/nunito/OFL.txt` |
| `zcool-kuaile/` | The ZCOOL KuaiLe Project Authors | `promo/2026-10-29/type-proposal/fonts/zcool-kuaile/OFL.txt` |
| `lxgw-wenkai/` | LXGW、The Klee Project Authors；来源版本 v1.522 | 字体内有版权和 OFL 名称/网址；工程缺少完整许可正文，分发前仍需补齐 [上游 OFL.txt](https://github.com/lxgw/LxgwWenKai/blob/v1.522/OFL.txt) |

### 宣传图标、音乐、音效与模板

| 内容与位置 | 已记录的来源与许可 | 分发边界 |
| --- | --- | --- |
| `assets/readme/intro.mp4` 与 `intro-cover.png` | 本地现有 30 秒宣传片及封面；音乐为 Francisco Alvear 的 Upbeat Jazz，音效与制作来源见 [展示素材说明](assets/readme/README.md) | 按维护者要求公开用于产品介绍；成片与封面不纳入代码 MIT，独立配乐、音效、字体和第三方宠物逐帧素材不随此目录分发 |
| `promo/2026-10-29/film/src/icons/la/` | pqoqubbw，Copyright (c) 2024-2026；局部 `promo/2026-10-29/film/src/icons/la/LICENSE` | 保留该目录的上游署名和许可，不能用项目维护者署名替换 |
| `promo/2026-10-29/film/public/music/bgm.wav` | 本地记录标注 Francisco Alvear 的 Upbeat Jazz，Mixkit 曲目 644；见 `promo/2026-10-29/film/public/music/credit.txt`、[Mixkit Music License](https://mixkit.co/license/#musicFree) 和 [User Terms](https://mixkit.co/terms/) | 已从公开源码、App 和插件导出包中排除，原文件仅保留本地；不受根 MIT 许可。来源及自行获取方式见 [宣传配乐与分发](docs/宣传配乐与分发.md) |
| `promo/2026-10-29/film/public/sfx/` 中的键盘音 | 已有记录标注 unicaegames 的 [Keyboard Sounds](https://opengameart.org/content/keyboard-sounds)，按 CC0 收录 | 依据目录内的来源记录；公开前仍需核对原始素材与许可对应关系 |
| 同目录中的界面、翻页、碰撞等音效 | 已有记录标注 [Kenney](https://kenney.nl/assets) 音效包，按 CC0 收录 | 具体映射见目录内 `promo/2026-10-29/film/public/sfx/README.md`；保留来源记录 |
| 同目录中的合成音效 | 已有记录标注由制作脚本生成 | 生成脚本与模板的许可来源待核验，排除于根 MIT 许可 |
| `promo/2026-10-29/film/examples/`、通用动效组件及宣传制作模板 | 随宣传制作工具复用的模板和示例 | 未完成独立来源与许可核对，整个 `promo/` 排除于根 MIT 许可 |

宣传工程的 npm 依赖继续按各上游包的许可证使用。`package.json` 和 lockfile 仅记录依赖关系，不将上游代码变为本项目所有。

## 分发时保留的文件

源码分发保留根 `LICENSE`、本文件以及各第三方内容的原始许可和署名。应用构建将根 `LICENSE` 和本文件复制到 `Contents/Resources/`；接入插件携带自己的代码许可证与 `NOTICE.md`，Codex 导出包还携带根许可范围清单。默认 App 的 `LingChongDaoArtworkProfile` 为 `public`，其中包含老板鼠；旧参数 `--with-local-artwork` 与默认构建相同。

当前公开源码与默认构建包含老板鼠；README 附带产品介绍成片、封面及示例界面图，App 和接入插件不打包这些展示文件。公开目录不附带独立的第三方宠物帧、配乐原文件或宣传制作工程。老板鼠作为项目品牌保留，不改变设计中涉及的第三方角色权利；其来源及尚未核验的范围按上表记录。原始问题与处理进度见 [开源前体检](docs/开源前体检-2026-10-30.md)。
