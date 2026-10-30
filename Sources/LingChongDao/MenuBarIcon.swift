import AppKit

/// Uses bundled public/local artwork; macOS supplies the template tint.
enum MenuBarIcon {
    static func makeImage() -> NSImage {
        let bundled = Bundle.main.url(forResource: "MenuBarIcon", withExtension: "png")
        let local = Bundle.main.bundleURL.pathExtension == "app" ? nil
            : URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("assets/app-icon/MenuBarIcon.png")
        let image = (bundled ?? local).flatMap { NSImage(contentsOf: $0) }
            ?? NSImage(systemSymbolName: "pawprint.fill", accessibilityDescription: "灵宠岛")
            ?? NSImage(size: NSSize(width: 22, height: 22))
        image.size = NSSize(width: 22, height: 22)
        image.isTemplate = true
        image.accessibilityDescription = "灵宠岛"
        return image
    }
}
