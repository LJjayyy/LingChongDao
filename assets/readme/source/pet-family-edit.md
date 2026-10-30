# 灵宠合影制作记录

- 用途：README「为什么叫『灵宠岛』」中的作者命名故事配图。
- 工具：内置 `image_gen.imagegen`，编辑模式，非透明背景。
- 成品：[pet-family.png](../pet-family.png)，1859 × 846，带应用名称，小黄鸭保留白色圆角底。
- 输入：作者在对话中提供的两张个人桌面截图；原截图不随仓库分发。
  - `codex-clipboard-fda1c3fd-8903-46a7-902c-b5a1064ad6f8.png`，SHA-256：`f8d1771ccf1509863be6be9967185ba0b21c58fc03ef4c43468afc401354f9e5`。
  - `codex-clipboard-f9678c72-351f-4e18-9028-05c90a299aef.png`，SHA-256：`f33813be6f5ded73208a117913648b17910cc7a8f1f788aef4354b0f770a02e3`。

精修去掉截图中的窗口、悬浮标签、按钮和 Dock，仅保留三只灵宠并统一构图，再补上对应应用名称。它是作者个人宠物收藏的故事配图，不是产品功能截图；角色权利范围见 [素材说明](../../../THIRD_PARTY_NOTICES.md)。生成式编辑不能保证重新生成逐像素相同的结果。

## 当前版提示词

以提交 `842b465` 中的首版合影为编辑底图，新增作者提供的 Dock 截图作为白底图标参考：`codex-clipboard-afdfb615-eb81-4512-99d9-3de02532c811.png`，SHA-256：`c12bdc73e159344811f84a942f1d4e033f652a9fe8e6db4f789b28821f567a8e`。应用名称对应作者前两张截图中的悬浮标签及本项目默认图标。

```text
Use case: precise-object-edit / identity-preserve. Edit Image 1 (the existing polished three-pet portrait) with only two requested corrections. Image 2 is a supporting reference: the author's actual Dock screenshot, showing the yellow duck DOES have a white rounded-square app-icon background.
Correction 1: Restore a WHITE rounded-square app-icon tile behind the center yellow duck, matching the original Dock screenshot in Image 2 and the size/corner radius of the left cat's white icon tile. Keep the duck's original yellow fuzzy silhouette, orange bill, black eyebrow, face and three tufts, without inventing a new body. The three icon tiles must have balanced equal optical sizes and aligned bottoms; do not leave the duck as a free-standing oversized head. Preserve the left blue-gray cat with red bottle cap and laptop in its white tile and the right brown mouse boss with folded arms and dark suit in its warm cream tile EXACTLY in their current styles and poses. Do not repaint or change their identities, expressions, clothes or props.
Correction 2: Add ONE clear application-name label centered beneath EACH corresponding icon, using exactly these labels from LEFT to RIGHT: "ChatGPT", "Qoder CN", "灵宠岛". These are app names, not character names. Use clean semibold sans-serif, dark warm charcoal #302B27, all labels aligned on the same baseline, no label capsules or extra badges. Lettering must be spelled EXACTLY, Chinese text exactly 灵宠岛. Make the labels prominent enough to stay legible when the entire image is displayed at 345 CSS pixels wide: about 90–100 px font on a roughly 1980 px wide image. No other text anywhere.
Retain the clean warm-paper background #FAF8F4, generous even spacing, subtle soft contact shadows, and original left-to-right order. Expand the canvas vertically if necessary, approximately 1980 by 900 landscape, to create proper breathing room between icons and labels and at the outer edges. No extra objects, no Dock, no hover bubbles, no windows, no buttons, no black indicator dots, no watermark. Exactly three existing pets. Output one publication-ready opaque image.
```

## 首版提示词

```text
Use case: compositing / identity-preserve. Edit the two supplied screenshots into ONE polished, wide horizontal image for the naming-story section of the Chinese macOS app 灵宠岛's GitHub README. Both images are edit targets showing the SAME three pet icons in slightly different sizes; use them together to recover clean details, do not duplicate characters. This is a cleaned-up portrait of the author's own three app pets, not a new product UI screenshot.
Keep exactly these three existing characters, their original hand-painted/cartoon design, poses, expressions, colors, distinctive framing and props: left a blue-gray cat wearing a bright red bottle cap, working at a silver laptop in a white rounded app-icon tile; middle the fuzzy bright yellow duck head with orange bill, three small tufts and thick curved black eyebrow, preserving its original silhouette; right the brown mouse boss in a dark suit and tie, folded arms, in its existing warm cream rounded icon tile. Preserve the cat's laptop and all original facial details. Do not reinvent, simplify, change style, change costumes or expressions. High fidelity to the original is essential; clean pixelation and edges tastefully.
Remove ALL surrounding screenshot debris: app windows, chat text, blue stop buttons, mic icons, app-name hover bubbles, black Dock indicator dots, green Dock wallpaper, cropped UI remnants. No text at all, no app-name labels, no badges, no captions, no decorative objects.
Compose the three existing icon subjects left-to-right in their original order, with balanced optical scale, aligned bottom edges, consistent generous spacing, subtle soft contact shadows, on a perfectly clean flat warm-paper background #FAF8F4 matching the README. Keep their individual original visual styles, do not force them into a new matching illustration style. The icons together occupy about 75% of the width and 70% of the height, giving a neat, friendly, well-composed portrait rather than an empty banner. Approximately 2.5:1 landscape framing, crisp publication-quality edges. Exactly three characters. No watermark, no new logos, no added furniture or scene. Output a finished opaque PNG-style image.
```
