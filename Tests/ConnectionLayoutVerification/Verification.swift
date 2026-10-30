// Native rendering regression: exercises the same ConnectionsView shown on navigation.
// Reads local connection status; never installs, removes, or modifies source configuration.
import AppKit
import SwiftUI
import IslandCore
import IslandConnections
@main
struct ConnectionLayoutVerification {
 @MainActor static func main() async throws {
  NSApplication.shared.setActivationPolicy(.prohibited)
  // Navigation happens after the workbench has initialized SwiftUI. Warm only
  // the generic controls renderer; the real ConnectionsView is still measured on
  // its first layout, with the same 250ms limit on every measured sample.
  let rendererStart = Date()
  let startupHost = NSHostingView(rootView: ScrollView {
    VStack {
      Label("灵宠岛", systemImage: "rectangle.stack")
      Button("任务总览") {}
    }.font(.system(size: 13))
  }.frame(width: 600, height: 800))
  let startupWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 800),
    styleMask: [.borderless], backing: .buffered, defer: false)
  startupWindow.isReleasedWhenClosed = false
  startupWindow.contentView = startupHost
  startupHost.frame = NSRect(x: 0, y: 0, width: 600, height: 800)
  startupHost.layoutSubtreeIfNeeded()
  startupHost.displayIfNeeded()
  startupWindow.close()
  print("renderer initialization", Date().timeIntervalSince(rendererStart))
  let manager = ConnectionManager()
  let refreshStart = Date()
  await manager.refresh()
  print("refresh", Date().timeIntervalSince(refreshStart))
  for provider in [ProviderID.qoder, .codex, .zcode] { manager.recordEvent(provider: provider, at: Date()) }
  await manager.refresh()
  var worst = 0.0
  for width in [600.0, 850.0, 600.0, 850.0] {
   let start = Date()
   let view = ScrollView { ConnectionsView(manager: manager).padding(28) }
     .frame(width: width, height: 800).background(Color(hex: 0xFAFAFA))
     .font(.system(size: 13)).foregroundStyle(BossWorkbenchStyle.text)
     .tint(BossWorkbenchStyle.copperText).buttonStyle(BossButtonStyle()).preferredColorScheme(.light)
   let host = NSHostingView(rootView: view)
   let window = NSWindow(contentRect: NSRect(x: 0,y: 0,width: width,height: 800),styleMask: [.borderless], backing: .buffered,defer: false)
   window.contentView = host
   host.frame = NSRect(x: 0,y: 0,width: width,height: 800)
   host.layoutSubtreeIfNeeded()
   host.displayIfNeeded()
   let elapsed = Date().timeIntervalSince(start)
   worst = max(worst, elapsed)
   print("LAYOUT width=\(width) seconds=\(elapsed)")

  }
  print(worst > 0.25 ? "FAIL: page blocks main thread >250ms" : "PASS: page layout under250ms")
  exit(worst > 0.25 ? 1 : 0)
 }
}
