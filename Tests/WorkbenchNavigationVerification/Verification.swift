// Drives the real WorkbenchView sidebar with in-process mouse events.
// Reads local connection configuration; never installs plugins or starts the bridge.
import AppKit
import SwiftUI
import IslandCore
import IslandConnections

@main
struct WorkbenchNavigationVerification {
 @MainActor static func main() throws {
  let timingMode = ProcessInfo.processInfo.environment["LINGCHONGDAO_VERIFY_TIMING"] ?? "strict"
  guard ["strict", "report"].contains(timingMode) else {
   print("FAIL: LINGCHONGDAO_VERIFY_TIMING must be strict or report"); exit(2)
  }
  let app = NSApplication.shared
  app.setActivationPolicy(.accessory)
  let suite = "local.lingchongdao.navigation-verification." + UUID().uuidString
  let defaults = UserDefaults(suiteName: suite)!
  defer { defaults.removePersistentDomain(forName: suite) }
  let settings = AppSettings(defaults: defaults)
  let model = AppModel(settings: settings, defaults: defaults)
  let resources = URL(fileURLWithPath: "/Applications/灵宠岛.app/Contents/Resources")
  var environment = ConnectionEnvironment.live(helperURL: URL(fileURLWithPath: "/Applications/灵宠岛.app/Contents/MacOS/lingchongdao-hook"))
  environment.codexPluginSourceURL = resources.appendingPathComponent("LingChongDaoCodexPlugin")
  environment.dshPluginSourceURL = resources.appendingPathComponent("DshPlugin")
  environment.qoderPluginSourceURL = resources.appendingPathComponent("QoderPlugin")
  environment.zcodePluginSourceURL = resources.appendingPathComponent("ZcodePlugin")
  let manager = ConnectionManager(environment: environment)
  PetAppearanceStore.shared.start()
  defer { PetAppearanceStore.shared.stop() }
  var ready = false
  Task { await manager.refresh(); ready = true }
  let host = NSHostingView(rootView: WorkbenchView(model: model, settings: settings, connections: manager))
  let window = NSWindow(contentRect: NSRect(x: 0,y: 0,width: 1000,height: 760),styleMask: [.titled], backing: .buffered,defer: false)
  window.contentView = host
  host.frame = NSRect(x: 0,y: 0,width: 1000,height: 760)
  window.makeKeyAndOrderFront(nil)
  host.layoutSubtreeIfNeeded()
  let readyDeadline = Date().addingTimeInterval(15)
  while !ready && Date() < readyDeadline {
   RunLoop.current.run(until: Date().addingTimeInterval(0.01))
  }
  guard ready else { fatalError("connection checks did not finish") }
  let output = URL(fileURLWithPath: ProcessInfo.processInfo.environment["NAVIGATION_EVIDENCE_DIR"] ?? "/private/tmp/lingchongdao-navigation-evidence")
  try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
  let widths: [CGFloat] = [1000, 850]
  var failures: [String] = []
  for width in widths {
   window.setContentSize(NSSize(width: width, height: 760))
   host.layoutSubtreeIfNeeded()
  var worst = 0.0
  for title in ["连接的应用", "任务总览", "连接的应用", "屏幕顶部", "连接的应用", "检查连接"] {

   let start = Date()
   let checking = title == "检查连接"
   let y: CGFloat = checking ? 45 : title == "连接的应用" ? 216 : title == "任务总览" ? 120 : 168
   let point = host.convert(NSPoint(x: checking ? width - 80 : 100, y: y), to: nil)
   for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
    let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
    window.sendEvent(event)
   }
   host.layoutSubtreeIfNeeded()
   host.displayIfNeeded()
   var previous = start
   var maxGap = Date().timeIntervalSince(start)
   let until = Date().addingTimeInterval(1.5)
   while Date() < until {
    RunLoop.current.run(until: Date().addingTimeInterval(0.005))
    host.layoutSubtreeIfNeeded()
    host.displayIfNeeded()
    let now = Date()
    maxGap = max(maxGap, now.timeIntervalSince(previous))
    previous = now
   }
   let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
   host.cacheDisplay(in: host.bounds, to: bitmap)
   try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output.appendingPathComponent("nav-\(Int(width))-\(title).png").path))
   guard selectedMarker(bitmap, y: checking ? 216 : y, scale: CGFloat(bitmap.pixelsWide) / host.bounds.width) else {
    print("FAIL navigation did not select \(title); inspect screenshot"); exit(1)
   }
   print("NAV width=\(width) page=\(title) maxMainThreadGap=\(maxGap)")
   worst = max(worst, maxGap)
  }
  if worst > 0.10 { failures.append("\(Int(width))pt navigation stalled \(worst)s") }
  }
  if timingMode == "report" {
   for failure in failures { print("TIMING REPORT: \(failure)") }
   print("PASS navigation selection at both widths; timing recorded without a shared-runner performance gate")
   return
  }
  for failure in failures { print("FAIL: \(failure)") }
  print(failures.isEmpty ? "PASS navigation stalls <100ms at both widths" : "FAIL navigation stalls >100ms")
  exit(failures.isEmpty ? 0 : 1)
 }
 // Inspect the rendered selected marker so a missed click cannot pass timing.
 @MainActor static func selectedMarker(_ bitmap: NSBitmapImageRep, y: CGFloat, scale: CGFloat) -> Bool {
  for px in Int(178 * scale)...Int(183 * scale) {
   for py in Int((y - 8) * scale)...Int((y + 8) * scale) {
    guard let color = bitmap.colorAt(x: px, y: py)?.usingColorSpace(.deviceRGB) else { continue }
    if color.redComponent > 0.5 && color.redComponent < 0.85
      && color.redComponent - color.greenComponent > 0.14
      && color.greenComponent - color.blueComponent > 0.10 { return true }
   }
  }
  return false
 }
}
