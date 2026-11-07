import AppKit
import Combine
import CoreServices
import OSLog
import ServiceManagement

@MainActor
protocol LoginItemRegistration {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
}

extension SMAppService: LoginItemRegistration {}

@MainActor
final class LaunchAtLoginController: ObservableObject {
    private let service: (any LoginItemRegistration)?
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "LingChongDao", category: "LaunchAtLogin")
    @Published private var status: SMAppService.Status?
    @Published private(set) var errorMessage: String?

    var isAvailable: Bool { service != nil }
    var isEnabled: Bool { status == .enabled }

    convenience init(available: Bool) {
        self.init(service: available ? SMAppService.mainApp : nil)
    }

    init(service: (any LoginItemRegistration)?) {
        self.service = service
    }

    func refresh() {
        let current = service?.status
        guard current != status else { return }
        status = current
        errorMessage = nil
    }

    func setEnabled(_ enabled: Bool) {
        guard let service else { return }
        refresh()
        errorMessage = nil
        guard enabled != isEnabled else { return }

        // If the system requires approval, only the user can grant it there.
        if status != .requiresApproval {
            do {
                if enabled { try service.register() }
                else { try service.unregister() }
            } catch {
                logger.error("Could not change login item: \(error.localizedDescription, privacy: .private)")
            }
            refresh()
        }
        guard enabled != isEnabled else { return }
        if status == .requiresApproval {
            errorMessage = "请在 macOS 登录项中允许灵宠岛。"
        } else {
            errorMessage = enabled ? "无法开启开机自启动。" : "无法关闭开机自启动。"
        }
    }

    func openLoginItems() {
        SMAppService.openSystemSettingsLoginItems()
    }

    static func isLoginLaunch(_ event: NSAppleEventDescriptor?) -> Bool {
        guard let event, event.eventClass == kCoreEventClass, event.eventID == kAEOpenApplication else { return false }
        return event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }
}
