import Combine
import Foundation
import IOKit.pwr_mgt

enum KeepAwakeState: Equatable { case off, on, partial }
enum KeepAwakeAssertionKind: CaseIterable { case system, display }
enum KeepAwakeBackendFailure: Error { case creationFailed }

/// Injectable boundary: tests never invoke the real power-management service.
struct KeepAwakeBackend {
    var create: (KeepAwakeAssertionKind) -> Result<IOPMAssertionID, KeepAwakeBackendFailure>
    var release: (IOPMAssertionID) -> Bool

    static let live = KeepAwakeBackend(create: { kind in
        let type = kind == .system ? kIOPMAssertionTypePreventUserIdleSystemSleep : kIOPMAssertionTypePreventUserIdleDisplaySleep
        var id = IOPMAssertionID(kIOPMNullAssertionID)
        let result = IOPMAssertionCreateWithName(type as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn), "灵宠岛 · 保持唤醒" as CFString, &id)
        guard result == kIOReturnSuccess, id != kIOPMNullAssertionID else { return .failure(.creationFailed) }
        return .success(id)
    }, release: { IOPMAssertionRelease($0) == kIOReturnSuccess })
}

/// Coordinates the privileged clamshell guard with process-owned idle assertions.
/// The UI only reports on after the guard handshake and both assertions succeed.
@MainActor
final class KeepAwakeController: ObservableObject {
    static let shared = KeepAwakeController()
    static let scopeDescription = "保持 Mac 唤醒（含合盖）。开启时需要管理员授权，关闭或退出后恢复；锁屏验证仍按 macOS 设置。"

    @Published private(set) var state: KeepAwakeState = .off
    @Published private(set) var errorMessage: String?
    @Published private(set) var isChanging = false
    private let backend: KeepAwakeBackend
    private let clamshellGuard: ClamshellSleepGuardControlling
    private var ownedIDs: [KeepAwakeAssertionKind: IOPMAssertionID] = [:]
    private var guardNeedsCleanup = false
    private var transition: Task<Void, Never>?
    private var monitor: Task<Void, Never>?
    private var enabling = false

    var isEnabled: Bool { !ownedIDs.isEmpty || guardNeedsCleanup }
    var isFullyEnabled: Bool { state == .on }
    var actionTitle: String {
        if isChanging { return enabling ? "正在等待授权…" : "正在恢复休眠…" }
        if state == .partial { return "重试恢复休眠" }
        return isEnabled ? "保持唤醒中" : "保持唤醒（含合盖）"
    }
    var statusText: String {
        if isChanging { return enabling ? "正在开启" : "正在恢复" }
        return state == .partial ? "需恢复休眠" : (isEnabled ? "已开启（含合盖）" : "已关闭")
    }
    var accessibilityValue: String {
        isChanging ? actionTitle : (state == .partial ? "恢复未完成" : (isEnabled ? "开，含合盖" : "关"))
    }

    init(backend: KeepAwakeBackend = .live, clamshellGuard: ClamshellSleepGuardControlling? = nil) {
        self.backend = backend
        self.clamshellGuard = clamshellGuard ?? ClamshellSleepGuard()
        if self.clamshellGuard.needsRecovery {
            guardNeedsCleanup = true
            state = .partial
            errorMessage = "检测到上次合盖防休眠未完成恢复，请点击重试恢复休眠并完成管理员授权。"
        }
    }

    func setEnabled(_ enabled: Bool) {
        guard !isChanging else { return }
        guard enabled else { stop(); return }
        guard !isEnabled else { return }
        enabling = true
        isChanging = true
        errorMessage = nil
        transition = Task { [weak self] in
            guard let self else { return }
            await self.enable()
            self.isChanging = false
        }
    }

    func toggle() { setEnabled(!isEnabled) }

    func stop() {
        guard !isChanging else { return }
        enabling = false
        isChanging = true
        monitor?.cancel()
        transition = Task { [weak self] in
            guard let self else { return }
            await self.disable()
            self.isChanging = false
        }
    }

    /// AppKit defers termination until privileged restoration is verified.
    func stopBeforeTermination() async -> Bool {
        monitor?.cancel()
        transition?.cancel()
        clamshellGuard.requestStop()
        await transition?.value
        enabling = false
        isChanging = true
        await disable()
        isChanging = false
        return !isEnabled
    }

    /// Last-resort notification; the independent guard also watches this PID.
    func requestStopForTermination() {
        monitor?.cancel()
        transition?.cancel()
        clamshellGuard.requestStop()
        releaseOwnedIDs()
    }

    func waitForTransition() async { await transition?.value }
    func clearError() { if state != .partial { errorMessage = nil } }

    private func enable() async {
        guardNeedsCleanup = true
        do {
            try await clamshellGuard.start()
            try Task.checkCancellation()
            guard clamshellGuard.isRunning else { throw ClamshellSleepGuardError.stateVerificationFailed }
            for kind in KeepAwakeAssertionKind.allCases {
                switch backend.create(kind) {
                case .success(let id): ownedIDs[kind] = id
                case .failure: throw KeepAwakeBackendFailure.creationFailed
                }
            }
            updateState()
            startMonitoring()
        } catch {
            releaseOwnedIDs()
            guardNeedsCleanup = !(await clamshellGuard.stop())
            updateState()
            if state == .partial {
                errorMessage = "保持唤醒未完全关闭，请点击重试恢复休眠。"
            } else if error is CancellationError || (error as? ClamshellSleepGuardError) == .authorizationCancelled {
                errorMessage = nil
            } else if let guardError = error as? ClamshellSleepGuardError {
                errorMessage = guardError.userMessage
            } else {
                errorMessage = "未能开启保持唤醒，已恢复原来的休眠状态，请重试。"
            }
        }
    }

    private func disable() async {
        releaseOwnedIDs()
        guardNeedsCleanup = !(await clamshellGuard.stop())
        updateState()
        errorMessage = isEnabled ? "休眠状态尚未完全恢复，请点击重试恢复休眠。" : nil
    }

    private func releaseOwnedIDs() {
        for kind in KeepAwakeAssertionKind.allCases.reversed() {
            guard let id = ownedIDs[kind] else { continue }
            if backend.release(id) { ownedIDs.removeValue(forKey: kind) }
        }
    }

    private func updateState() {
        state = !isEnabled ? .off : (ownedIDs.count == KeepAwakeAssertionKind.allCases.count && guardNeedsCleanup && clamshellGuard.isRunning ? .on : .partial)
    }

    private func startMonitoring() {
        monitor?.cancel()
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard self?.checkGuard() == true else { return }
            }
        }
    }

    private func checkGuard() -> Bool {
        guard state == .on, !isChanging else { return false }
        guard clamshellGuard.isRunning else {
            if clamshellGuard.needsRecovery {
                releaseOwnedIDs()
                updateState()
                errorMessage = "合盖防休眠辅助程序已停止，请点击重试恢复休眠并完成管理员授权。"
                return false
            }
            enabling = false
            isChanging = true
            transition = Task { [weak self] in
                guard let self else { return }
                await self.disable()
                if !self.isEnabled { self.errorMessage = "合盖防休眠已停止，原来的休眠状态已恢复。需要时请重新开启。" }
                self.isChanging = false
            }
            return false
        }
        return true
    }

    deinit {
        monitor?.cancel()
        transition?.cancel()
        Task { @MainActor [guardToStop = clamshellGuard] in guardToStop.requestStop() }
        for id in ownedIDs.values { _ = backend.release(id) }
    }
}
