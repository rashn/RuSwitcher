import AppKit

/// Запоминает раскладку клавиатуры для каждого приложения и восстанавливает при переключении.
@MainActor
final class PerAppLayoutManager {
    private var layoutByApp: [String: String] = [:]
    private var previousBundleID: String?
    private var observer: NSObjectProtocol?

    var onLayoutRestored: (() -> Void)?

    func start() {
        previousBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated {
                self?.handleAppActivated(app)
            }
        }
        rslog("PerAppLayout: started")
    }

    func stop() {
        if let observer {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        observer = nil
        layoutByApp.removeAll()
        previousBundleID = nil
        rslog("PerAppLayout: stopped")
    }

    private func handleAppActivated(_ app: NSRunningApplication?) {
        guard let newBundleID = app?.bundleIdentifier else { return }

        let currentLayout = LayoutSwitcher.currentLayoutID()

        // Сохраняем раскладку для предыдущего приложения
        if let prevID = previousBundleID {
            layoutByApp[prevID] = currentLayout
        }

        // Восстанавливаем раскладку для нового приложения
        if let savedLayout = layoutByApp[newBundleID], savedLayout != currentLayout {
            rslog("PerAppLayout: \(newBundleID) → restore \(savedLayout)")
            LayoutSwitcher.switchTo(layoutID: savedLayout)
            onLayoutRestored?()
        }

        previousBundleID = newBundleID
    }
}
