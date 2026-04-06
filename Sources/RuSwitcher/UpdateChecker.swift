import AppKit
import Foundation

/// Проверяет наличие обновлений через GitHub
@MainActor
enum UpdateChecker {
    // URL к JSON с информацией о версии (заменить на реальный)
    private static let versionURL = "https://raw.githubusercontent.com/rashn/RuSwitcher/main/version.json"

    /// Структура JSON версии
    private struct VersionInfo: Decodable {
        let version: String
        let url: String
        let notes: String?
    }

    /// Проверить при запуске (с задержкой 5 сек, не чаще раза в сутки)
    static func checkOnLaunch() {
        let settings = SettingsManager.shared
        if let lastCheck = settings.lastUpdateCheck,
           Date().timeIntervalSince(lastCheck) < 86400 {
            return // Проверяли менее суток назад
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            Task { await check(silent: true) }
        }
    }

    /// Проверить вручную (всегда показывает результат)
    static func checkNow() {
        Task { await check(silent: false) }
    }

    private static func check(silent: Bool) async {
        guard let url = URL(string: versionURL) else { return }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let info = try JSONDecoder().decode(VersionInfo.self, from: data)

            SettingsManager.shared.lastUpdateCheck = Date()

            let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"

            if compareVersions(info.version, isNewerThan: currentVersion) {
                if SettingsManager.shared.skippedVersion == info.version && silent {
                    return // Пользователь пропустил эту версию
                }
                await showUpdateAlert(info: info)
            } else if !silent {
                await showUpToDateAlert()
            }
        } catch {
            rslog("UpdateChecker error: \(error)")
            if !silent {
                await showErrorAlert()
            }
        }
    }

    private static func showUpdateAlert(info: VersionInfo) async {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = L10n.updateAvailable
        alert.informativeText = "\(L10n.updateNewVersion) \(info.version)\n\(info.notes ?? "")"
        alert.addButton(withTitle: L10n.updateDownload)
        alert.addButton(withTitle: L10n.updateSkip)
        alert.addButton(withTitle: L10n.updateLater)

        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:
            if let url = URL(string: info.url) {
                NSWorkspace.shared.open(url)
            }
        case .alertSecondButtonReturn:
            SettingsManager.shared.skippedVersion = info.version
        default:
            break
        }
    }

    private static func showUpToDateAlert() async {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = L10n.updateUpToDate
        alert.informativeText = L10n.updateLatestInstalled
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private static func showErrorAlert() async {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.updateCheckFailed
        alert.informativeText = L10n.updateCheckFailedDetail
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    /// Сравнивает версии ("2.0.1" > "1.9.0")
    private static func compareVersions(_ v1: String, isNewerThan v2: String) -> Bool {
        let parts1 = v1.split(separator: ".").compactMap { Int($0) }
        let parts2 = v2.split(separator: ".").compactMap { Int($0) }

        for i in 0..<max(parts1.count, parts2.count) {
            let p1 = i < parts1.count ? parts1[i] : 0
            let p2 = i < parts2.count ? parts2[i] : 0
            if p1 > p2 { return true }
            if p1 < p2 { return false }
        }
        return false
    }
}
