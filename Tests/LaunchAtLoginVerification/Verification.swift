import AppKit
import CoreServices
import ServiceManagement

@MainActor
private final class SimulatedLoginItem: LoginItemRegistration {
    var status: SMAppService.Status = .notRegistered
    var registrationResult: SMAppService.Status = .enabled
    var rejectChanges = false
    var registrations = 0
    var removals = 0

    private enum Denial: Error { case bySystem }

    func register() throws {
        registrations += 1
        if rejectChanges { throw Denial.bySystem }
        status = registrationResult
    }

    func unregister() throws {
        removals += 1
        if rejectChanges { throw Denial.bySystem }
        status = .notRegistered
    }
}

@main
private struct LaunchAtLoginVerification {
    @MainActor static func main() {
        let system = SimulatedLoginItem()
        let settings = LaunchAtLoginController(service: system)
        settings.refresh()
        precondition(!settings.isEnabled && system.registrations == 0, "first launch must not enable autostart")

        system.registrationResult = .requiresApproval
        settings.setEnabled(true)
        precondition(!settings.isEnabled && settings.errorMessage != nil, "pending approval must stay off and explain why")
        settings.setEnabled(true)
        precondition(system.registrations == 1, "a blocked item must not be re-registered to bypass the system")
        system.status = .enabled
        settings.refresh()
        precondition(settings.isEnabled && settings.errorMessage == nil, "approval in System Settings must be reflected")
        system.status = .notRegistered
        settings.refresh()
        precondition(!settings.isEnabled && system.registrations == 1, "external removal must stay off")

        system.rejectChanges = true
        settings.setEnabled(true)
        precondition(!settings.isEnabled && settings.errorMessage != nil, "failed enable must stay off")
        system.rejectChanges = false
        system.registrationResult = .enabled
        settings.setEnabled(true)
        precondition(settings.isEnabled && settings.errorMessage == nil, "successful enable must show on")
        system.rejectChanges = true
        settings.setEnabled(false)
        precondition(settings.isEnabled && settings.errorMessage != nil, "failed disable must stay on")
        system.rejectChanges = false
        settings.setEnabled(false)
        precondition(!settings.isEnabled && settings.errorMessage == nil && system.removals == 2, "explicit disable must unregister")

        let loginEvent = openEvent(id: kAEOpenApplication, marker: keyAELaunchedAsLogInItem)
        let manualEvent = openEvent(id: kAEOpenApplication)
        let reopenEvent = openEvent(id: kAEReopenApplication, marker: keyAELaunchedAsLogInItem)
        precondition(LaunchAtLoginController.isLoginLaunch(loginEvent), "login launch must be quiet")
        precondition(!LaunchAtLoginController.isLoginLaunch(manualEvent), "manual launch must show the workbench")
        precondition(!LaunchAtLoginController.isLoginLaunch(reopenEvent), "reopening must not be mistaken for login")
        precondition(!LaunchAtLoginController.isLoginLaunch(nil), "launch without an Apple event must stay manual")
        print("PASS launch at login: system state, approval, failures, and launch event")
    }

    private static func openEvent(id: AEEventID, marker: OSType? = nil) -> NSAppleEventDescriptor {
        let event = NSAppleEventDescriptor(eventClass: kCoreEventClass, eventID: id,
            targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        if let marker {
            event.setParam(NSAppleEventDescriptor(enumCode: marker), forKeyword: keyAEPropData)
        }
        return event
    }
}
