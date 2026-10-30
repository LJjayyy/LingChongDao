# 灵宠合影制作记录

- 用途：README「为什么叫『灵宠岛』」中的作者命名故事配图。
- 工具：内置 `image_gen.imagegen`，编辑模式，非透明背景。
- 成品：[pet-family.png](../pet-family.png)，1981 × 793。
- 输入：作者在对话中提供的两张个人桌面截图；原截图不随仓库分发。
  - `codex-clipboard-fda1c3fd-8903-46a7-902c-b5a1064ad6f8.png`，SHA-256：`f8d1771ccf1509863be6be9967185ba0b21c58fc03ef4c43468afc401354f9e5`。
  - `codex-clipboard-f9678c72-351f-4e18-9028-05c90a299aef.png`，SHA-256：`f33813be6f5ded73208a117913648b17910cc7a8f1f788aef4354b0f770a02e3`。

精修去掉截图中的窗口、标签、按钮和 Dock，仅保留三只灵宠并统一构图。它是作者个人宠物收藏的故事配图，不是产品功能截图；角色权利范围见 [素材说明](../../../THIRD_PARTY_NOTICES.md)。生成式编辑不能保证重新生成逐像素相同的结果。

## 最终提示词

```text
Use case: compositing / identity-preserve. Edit the two supplied screenshots into ONE polished, wide horizontal image for the naming-story section of the Chinese macOS app 灵宠岛's GitHub README. Both images are edit targets showing the SAME three pet icons in slightly different sizes; use them together to recover clean details, do not duplicate characters. This is a cleaned-up portrait of the author's own three app pets, not a new product UI screenshot.
Keep exactly these three existing characters, their original hand-painted/cartoon design, poses, expressions, colors, distinctive framing and props: left a blue-gray cat wearing a bright red bottle cap, working at a silver laptop in a white rounded app-icon tile; middle the fuzzy bright yellow duck head with orange bill, three small tufts and thick curved black eyebrow, preserving its original silhouette; right the brown mouse boss in a dark suit and tie, folded arms, in its existing warm cream rounded icon tile. Preserve the cat's laptop and all original facial details. Do not reinvent, simplify, change style, change costumes or expressions. High fidelity to the original is essential; clean pixelation and edges tastefully.
Remove ALL surrounding screenshot debris: app windows, chat text, blue stop buttons, mic icons, app-name hover bubbles, black Dock indicator dots, green Dock wallpaper, cropped UI remnants. No text at all, no app-name labels, no badges, no captions, no decorative objects.
Compose the three existing icon subjects left-to-right in their original order, with balanced optical scale, aligned bottom edges, consistent generous spacing, subtle soft contact shadows, on a perfectly clean flat warm-paper background #FAF8F4 matching the README. Keep their individual original visual styles, do not force them into a new matching illustration style. The icons together occupy about 75% of the width and 70% of the height, giving a neat, friendly, well-composed portrait rather than an empty banner. Approximately 2.5:1 landscape framing, crisp publication-quality edges. Exactly three characters. No watermark, no new logos, no added furniture or scene. Output a finished opaque PNG-style image.
```
