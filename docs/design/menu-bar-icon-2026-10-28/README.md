# 菜单栏单色标识

用户明确指定右上角菜单栏入口，并要求参考 macOS 官方规范。此前对顶部岛标识的误改已撤销。

依据 [Apple HIG · Menu bar extras](https://developer.apple.com/design/human-interface-guidelines/the-menu-bar#Menu-bar-extras)（2026-10-28 查阅），菜单栏入口可以使用自定义界面图标或 SF Symbol；形状由黑色与透明区域定义，系统适配深浅背景和选中状态。白色是系统渲染结果，不应固定写死。

最终版本基于应用现有的 `AppIcon-preview.png` 制作，替换先前另画的通用鼠头。使用内置 imagegen 编辑生成透明的 `assets/app-icon/MenuBarIcon.png`，保留原角色的椭圆大耳朵、宽脸、发梢、非对称眉形、半眯眼及嘴角神态，只取头部以适应菜单栏尺寸。完整提示词见 `assets/app-icon/MenuBarIcon-design.md`。

`MenuBarIcon.makeImage()` 以 22 × 22 pt 加载此素材，设为 `isTemplate = true`，由系统负责着色；图形为黑色与真实透明的留白，无底板、渐变或阴影。初版为 18 pt，后按用户反馈放大到 22 pt（约 22%）；尺寸是本项目的设计选择，并非 Apple 强制指定。打包脚本复制素材，安装脚本检查素材存在。

验证：应用编译通过；离屏检查确认逻辑尺寸、模板标记、黑色与透明像素、有效图形和透明边角。最终版本的 `mascot-light-dark-preview.png` 展示浅深背景、18 pt 效果及 3 倍细节，是离屏效果预览，不是系统菜单栏截图；旧的 `light-dark-preview.png` 仅保留先前通用鼠头的记录。构建与安装脚本语法检查通过，签名验证通过后已安装并重启 `/Applications/灵宠岛.app`。
