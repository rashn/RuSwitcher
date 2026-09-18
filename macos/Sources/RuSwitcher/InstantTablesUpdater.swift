import CryptoKit
import Foundation

/// Скачивание языковых паков для конверсии на лету. Данные не лежат в бинаре — приложение
/// берёт их с GitHub по включению настройки, сверяет sha256 из манифеста и кладёт в
/// Application Support (см. InstantTables).
///
/// Манифест — индекс языков: `{formatVersion, languages: {ru: {file, size, sha256, version}}}`.
/// Паки лежат рядом с ним, поэтому URL пака строится от URL манифеста: чтобы переехать на
/// другой релиз/зеркало, достаточно поменять одну константу. Новый язык — запись в манифесте
/// плюс ассет, править приложение не нужно.
///
/// Ошибки не мешают работать: не скачалось или не сошёлся хеш — фича молчит, остаётся обычный
/// путь на пробеле, а попытка повторится при следующем включении или через сутки.
@MainActor
enum InstantTablesUpdater {
    /// Где лежит индекс языков. При мёрдже в апстрим сюда встанет релиз автора.
    static let manifestURL = URL(string:
        "https://github.com/russelgal/RuSwitcher/releases/download/instant-tables-v1/manifest.json")!

    enum Status: Equatable {
        case idle             // паки на месте (или фича выключена)
        case downloading
        case ready
        case failed(String)
    }

    private(set) static var status: Status = .idle
    /// UI подписывается сюда, чтобы обновлять подпись под галкой.
    static var onStatusChange: ((Status) -> Void)?

    private static var inFlight = false
    private static let lastCheckKey = "com.ruswitcher.instantTablesLastCheck"

    /// Убедиться, что паки нужных языков на месте. `force` — пользователь только что включил
    /// настройку (проверяем сразу), иначе проверка манифеста троттлится сутками, как у
    /// авто-обновления: пак меняется редко, ходить в сеть на каждый запуск незачем.
    static func ensurePacks(for languages: [String], force: Bool) {
        let codes = Set(languages.map { String($0.prefix(2)).lowercased() }).sorted()
        guard !codes.isEmpty, !inFlight else { return }

        let allInstalled = codes.allSatisfy { InstantTables.isDownloaded($0) }
        if allInstalled, !force, !checkDue() { return }
        if allInstalled { setStatus(.ready) }

        inFlight = true
        setStatus(allInstalled ? status : .downloading)
        Task {
            defer { inFlight = false }
            do {
                let manifest = try await fetchManifest()
                UserDefaults.standard.set(Date(), forKey: lastCheckKey)
                var installed = 0
                for code in codes {
                    guard let entry = manifest.languages[code] else {
                        rslog("instant tables: языка \(code) нет в манифесте")
                        continue
                    }
                    // Уже стоит нужная версия — не качаем.
                    if InstantTables.isDownloaded(code), InstantTables.installedVersion(code) == entry.version {
                        installed += 1
                        continue
                    }
                    let data = try await fetchPack(entry)
                    try InstantTables.install(data, lang: code)
                    installed += 1
                    rslog("instant tables: установлен пак \(code) (\(data.count) Б, версия \(entry.version))")
                }
                setStatus(installed == codes.count ? .ready : .failed(L10n.instantTablesNoLanguage))
            } catch {
                rslog("instant tables: не скачались — \(error.localizedDescription)")
                setStatus(.failed(L10n.instantTablesFailed))
            }
        }
    }

    /// Языки текущей пары раскладок — их паки и нужны. nil, если пара не определилась.
    static func languagesForCurrentPair() -> [String]? {
        guard let langs = LayoutSwitcher.currentAndOppositeLanguage() else { return nil }
        return [langs.current, langs.opposite]
    }

    // MARK: - Внутреннее

    private struct Manifest: Decodable {
        struct Entry: Decodable {
            let file: String
            let size: Int
            let sha256: String
            let version: Int
        }
        let formatVersion: Int
        let languages: [String: Entry]
    }

    private static func fetchManifest() async throws -> Manifest {
        let (data, response) = try await URLSession.shared.data(from: manifestURL)
        try check(response)
        let manifest = try JSONDecoder().decode(Manifest.self, from: data)
        guard manifest.formatVersion == 1 else { throw Failure.formatMismatch }
        return manifest
    }

    private static func fetchPack(_ entry: Manifest.Entry) async throws -> Data {
        let url = manifestURL.deletingLastPathComponent().appendingPathComponent(entry.file)
        let (data, response) = try await URLSession.shared.data(from: url)
        try check(response)
        // Размер и хеш — из манифеста: пак приходит по сети, и подсунуть вместо него что угодно
        // не должно быть возможно. Не сошлось — считаем, что пака нет.
        guard data.count == entry.size else { throw Failure.sizeMismatch }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == entry.sha256.lowercased() else { throw Failure.hashMismatch }
        return data
    }

    private static func check(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else { throw Failure.http(http.statusCode) }
    }

    /// Пора ли снова сверяться с манифестом (раз в сутки).
    private static func checkDue() -> Bool {
        guard let last = UserDefaults.standard.object(forKey: lastCheckKey) as? Date else { return true }
        return Date().timeIntervalSince(last) > 24 * 3600
    }

    private static func setStatus(_ new: Status) {
        status = new
        onStatusChange?(new)
    }

    private enum Failure: LocalizedError {
        case http(Int), sizeMismatch, hashMismatch, formatMismatch
        var errorDescription: String? {
            switch self {
            case let .http(code):   return "HTTP \(code)"
            case .sizeMismatch:     return "размер пака не совпал с манифестом"
            case .hashMismatch:     return "sha256 пака не совпал с манифестом"
            case .formatMismatch:   return "версия формата манифеста не поддерживается"
            }
        }
    }
}
