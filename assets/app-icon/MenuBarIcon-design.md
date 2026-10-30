# 应用 logo 的菜单栏衍生版

来源：本目录 `AppIcon-preview.png` 中的老板鼠。使用内置 imagegen 的透明背景编辑模式制作，生成图为 `MenuBarIcon.png`，原应用图标保持不变。

设计：沿用宽脸、椭圆大耳朵、发梢、非对称眉形、半眯眼和嘴角神态，保留原图略微侧脸的角度。只取头部，当前菜单栏显示尺寸按用户反馈从 18 pt 放大为 22 pt。去掉应用图标底板、身体、材质和色彩；前景为黑色，背景及面部留白为真实透明区域。运行时设为模板图像，由 macOS 着色。

完整生成提示词：

```text
Use case: style-transfer. Asset type: macOS menu bar template icon, a monochrome identity-preserving adaptation of the attached app icon. Input image 1 is the edit target and identity reference. Extract the SAME boss mouse character's head, preserving its huge oval ears, broad cheeky face, small two-point hair tuft, unequal arched eyebrows, half-lidded sly eyes looking sideways, small nose and smirk. Maintain its original slight three-quarter pose, face proportions and expression; make it immediately recognizable as this exact mascot, not a generic symmetrical mouse. Simplify into a bold small-scale single-color glyph suitable at 18 pixels: solid BLACK foreground only, fully TRANSPARENT background, and fully TRANSPARENT negative spaces for features. Use a compact filled silhouette with just a few thick cutouts. Remove the cream rounded-square app tile completely; remove body/suit/arms to give the recognizable face enough space. No white pixels, no gray fills, no colors, no texture, no shadow, no gradients, no border or enclosing badge, no text. Flat crisp vector-like contours with antialiased edges. Head fills about 90 percent of a square canvas, centered, ears and cheeks entirely visible with modest uniform transparent safety margin. This must be usable as a pure alpha mask; all negative spaces really transparent, not white.
```
