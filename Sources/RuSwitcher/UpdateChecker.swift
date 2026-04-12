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
        let sha256: String?
    }

    /// Проверить при запуске (с задержкой 5 сек, не чаще раза в сутки).
    /// Отключается через настройку `checkUpdatesEnabled`. Ручная проверка (`checkNow`) работает всегда.
    static func checkOnLaunch() {
        let settings = SettingsManager.shared
        guard settings.checkUpdatesEnabled else { return }
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
        alert.addButton(withTitle: L10n.updateInstallRestart)  // 1st
        alert.addButton(withTitle: L10n.updateDownload)         // 2nd
        alert.addButton(withTitle: L10n.updateSkip)             // 3rd
        alert.addButton(withTitle: L10n.updateLater)            // 4th

        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:
            await installAndRestart(info: info)
        case .alertSecondButtonReturn:
            if let url = URL(string: info.url) {
                NSWorkspace.shared.open(url)
            }
        case .alertThirdButtonReturn:
            SettingsManager.shared.skippedVersion = info.version
        default:
            break
        }
    }

    // MARK: - Install & Restart

    private static func installAndRestart(info: VersionInfo) async {
        let dmgURL: URL
        let version = info.version
        let expectedURL = "https://github.com/rashn/RuSwitcher/releases/download/v\(version)/RuSwitcher-\(version).dmg"
        dmgURL = URL(string: expectedURL)!

        let tmpPath = "/tmp/RuSwitcher-update.dmg"
        let tmpURL = URL(fileURLWithPath: tmpPath)

        // 1. Скачать
        rslog("Update: downloading \(dmgURL)")
        do {
            let (data, response) = try await URLSession.shared.data(from: dmgURL)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                await showInstallError(L10n.updateDownloadFailed)
                return
            }
            try data.write(to: tmpURL)
        } catch {
            rslog("Update: download failed — \(error)")
            await showInstallError(L10n.updateDownloadFailed)
            return
        }

        // 2. Проверить sha256
        if let expectedSHA = info.sha256, !expectedSHA.isEmpty {
            let actualSHA = sha256OfFile(at: tmpPath)
            if actualSHA != expectedSHA {
                rslog("Update: sha256 mismatch expected=\(expectedSHA) actual=\(actualSHA ?? "nil")")
                try? FileManager.default.removeItem(at: tmpURL)
                await showInstallError(L10n.updateVerifyFailed)
                return
            }
            rslog("Update: sha256 verified")
        }

        // 3. Смонтировать DMG
        let mountPoint = "/tmp/RuSwitcher-update-mount"
        let mount = Process()
        mount.launchPath = "/usr/bin/hdiutil"
        mount.arguments = ["attach", tmpPath, "-nobrowse", "-readonly", "-mountpoint", mountPoint]
        mount.standardOutput = FileHandle.nullDevice
        mount.standardError = FileHandle.nullDevice
        do {
            try mount.run()
            mount.waitUntilExit()
            guard mount.terminationStatus == 0 else {
                rslog("Update: hdiutil attach failed with status \(mount.terminationStatus)")
                await showInstallError(L10n.updateInstallFailed)
                return
            }
        } catch {
            rslog("Update: hdiutil attach error — \(error)")
            await showInstallError(L10n.updateInstallFailed)
            return
        }

        defer {
            // Размонтировать и почистить
            let detach = Process()
            detach.launchPath = "/usr/bin/hdiutil"
            detach.arguments = ["detach", mountPoint, "-quiet"]
            detach.standardOutput = FileHandle.nullDevice
            detach.standardError = FileHandle.nullDevice
            try? detach.run()
            detach.waitUntilExit()
            try? FileManager.default.removeItem(at: tmpURL)
        }

        // 4. Найти .app в смонтированном томе
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(atPath: mountPoint),
              let appName = contents.first(where: { $0.hasSuffix(".app") }) else {
            rslog("Update: no .app found in mounted DMG")
            await showInstallError(L10n.updateInstallFailed)
            return
        }

        let sourceApp = URL(fileURLWithPath: mountPoint).appendingPathComponent(appName)
        let currentApp = URL(fileURLWithPath: Bundle.main.bundlePath)

        // 5. Атомарно заменить .app
        do {
            _ = try fm.replaceItemAt(currentApp, withItemAt: sourceApp)
            rslog("Update: app replaced successfully")
        } catch {
            rslog("Update: replace failed — \(error)")
            await showInstallError(L10n.updateInstallFailed)
            return
        }

        // 6. Перезапуск
        rslog("Update: restarting...")
        let appPath = currentApp.path
        let task = Process()
        task.launchPath = "/bin/sh"
        task.arguments = ["-c", "sleep 1; open '\(appPath)'"]
        try? task.run()
        NSApplication.shared.terminate(nil)
    }

    private static func sha256OfFile(at path: String) -> String? {
        let pipe = Pipe()
        let process = Process()
        process.launchPath = "/usr/bin/shasum"
        process.arguments = ["-a", "256", path]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8) else { return nil }
            return output.split(separator: " ").first.map(String.init)
        } catch {
            return nil
        }
    }

    private static func showInstallError(_ message: String) async {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.updateInstallFailed
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
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
