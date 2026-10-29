import AppKit

/// Lock, sleep and power notifications. On lock or sleep everything pauses; the door is not
/// forced shut, so nothing animates as the display goes dark. On unlock or wake it resumes
/// exactly where it was left.
final class SystemEvents {
    private weak var view: FridgeView?
    private var reasons = Set<String>()
    private var tokens: [(NotificationCenter, NSObjectProtocol)] = []

    init(view: FridgeView) {
        self.view = view

        let workspace = NSWorkspace.shared.notificationCenter
        let distributed = DistributedNotificationCenter.default()

        pair(workspace, NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification, reason: "screen")
        pair(workspace, NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification, reason: "system")
        pair(distributed, Notification.Name("com.apple.screenIsLocked"), Notification.Name("com.apple.screenIsUnlocked"), reason: "lock")

        observe(NotificationCenter.default, .NSProcessInfoPowerStateDidChange) { [weak self] in self?.refreshPower() }
        observe(workspace, NSWorkspace.accessibilityDisplayOptionsDidChangeNotification) { [weak self] in self?.refreshPower() }
        refreshPower()
    }

    deinit {
        for (center, token) in tokens { center.removeObserver(token) }
    }

    private func pair(_ center: NotificationCenter, _ begin: Notification.Name, _ end: Notification.Name, reason: String) {
        observe(center, begin) { [weak self] in
            guard let self = self else { return }
            self.reasons.insert(reason)
            self.view?.pauseEverything()
        }
        observe(center, end) { [weak self] in
            guard let self = self else { return }
            self.reasons.remove(reason)
            if self.reasons.isEmpty { self.view?.resumeEverything() }
        }
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ handler: @escaping () -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { _ in handler() }
        tokens.append((center, token))
    }

    /// Low Power Mode and Reduce Motion both skip the fog plume.
    private func refreshPower() {
        view?.lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        view?.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
}
