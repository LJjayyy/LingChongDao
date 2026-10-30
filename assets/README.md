# 老板鼠品牌素材

老板鼠是灵宠岛的默认角色与品牌标识，公开源码和默认 App 均包含：

- `default-pet/`：角色静态图、动作图集、16 帧表演图集和对应帧坐标，以及设计来源记录。
- `app-icon/`：应用图标、各档 iconset、菜单栏图标与制作记录。
- 五个接入插件的 `icon.png`：与老板鼠应用图标一致的 256 × 256 标识。

```sh
./scripts/build-app.sh release
./scripts/install-local.sh --no-build
```

无需本地私有目录或额外获取角色素材。旧参数 `--with-local-artwork` 保留为兼容入口，效果与默认构建相同。`scripts/PublicArtwork.swift` 仍可独立生成几何占位图，但默认打包不使用它。

代码采用 MIT；品牌角色与派生图像的范围单独说明，见根目录 [许可范围与第三方素材](../THIRD_PARTY_NOTICES.md)。宣传工程、配乐、第三方宠物帧与本地素材备份继续排除于公开源码。
