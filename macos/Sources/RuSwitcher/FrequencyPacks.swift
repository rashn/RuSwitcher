import Foundation
import CryptoKit
import Compression

/// Словарь частых словоформ одного языка (скачиваемый пак, 3.5). Файл — слова в нижнем
/// регистре по одному на строку, отсортированные по байтам UTF-8. Держим файл целиком и
/// ищем двоичным поиском: ~2 МБ памяти на 80 тыс. слов против ~8 МБ у Set<String>.
final class WordPack: @unchecked Sendable {
    let count: Int
    private let bytes: [UInt8]
    private let starts: [Int32]

    /// nil — файл битый: не UTF-8, пустые строки, не отсортирован или слишком большой.
    init?(data: Data) {
        guard data.count > 1, data.count <= 16 << 20, data.last == 0x0A,
              String(data: data, encoding: .utf8) != nil else { return nil }
        let b = [UInt8](data)
        var starts: [Int32] = [0]
        for i in 0..<(b.count - 1) where b[i] == 0x0A { starts.append(Int32(i + 1)) }
        bytes = b
        self.starts = starts
        count = starts.count
        for i in 0..<count {
            if line(i).isEmpty { return nil }
            if i > 0, Self.compare(bytes[line(i - 1)], bytes[line(i)]) >= 0 { return nil }
        }
    }

    func contains(_ word: String) -> Bool {
        let q = Array(word.utf8)
        guard !q.isEmpty else { return false }
        var lo = 0, hi = count - 1
        while lo <= hi {
            let mid = (lo + hi) >> 1
            let c = Self.compare(bytes[line(mid)], q[...])
            if c == 0 { return true }
            if c < 0 { lo = mid + 1 } else { hi = mid - 1 }
        }
        return false
    }

    /// Начинается ли с `prefix` хоть одно слово пака. Тот же двоичный поиск, только ищем
    /// первое слово не меньше префикса: в отсортированном списке все слова с этим началом
    /// идут подряд сразу за ним. Нужно конверсии на лету — она судит по незаконченному слову.
    func hasPrefix(_ prefix: String) -> Bool {
        let q = Array(prefix.utf8)
        guard !q.isEmpty else { return false }
        var lo = 0, hi = count
        while lo < hi {
            let mid = (lo + hi) >> 1
            if Self.compare(bytes[line(mid)], q[...]) < 0 { lo = mid + 1 } else { hi = mid }
        }
        return lo < count && bytes[line(lo)].starts(with: q)
    }

    /// Все слова пака по порядку — для разовой сборки таблиц конверсии на лету.
    func forEachWord(_ body: (String) -> Void) {
        for i in 0..<count {
            if let w = String(bytes: bytes[line(i)], encoding: .utf8) { body(w) }
        }
    }

    private func line(_ i: Int) -> Range<Int> {
        let end = i + 1 < count ? Int(starts[i + 1]) - 1 : bytes.count - 1
        return Int(starts[i])..<end
    }

    private static func compare(_ a: ArraySlice<UInt8>, _ b: ArraySlice<UInt8>) -> Int {
        for (x, y) in zip(a, b) where x != y { return x < y ? -1 : 1 }
        return a.count == b.count ? 0 : (a.count < b.count ? -1 : 1)
    }
}

/// Скачиваемые частотные словари для автоконверсии (3.5). Системный словарь не знает
/// сленга, имён, новых слов; пак дополняет его частыми словоформами из субтитров
/// (FrequencyWords, CC BY-SA 4.0). В сборку приложения ничего не входит: паки качаются
/// по желанию с GitHub, проверяются по sha256 из манифеста, слова проверяются локально.
@MainActor
enum FrequencyPacks {
    static var manifestURL = URL(string: "https://raw.githubusercontent.com/rashn/RuSwitcher/main/dicts/manifest.json")!
    /// Не в Caches: оттуда система удаляет файлы сама.
    static var storeDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("RuSwitcher/dicts", isDirectory: true)

    private static var loaded: [String: WordPack] = [:]
    private static var absent: Set<String> = []

    /// Пак языка, если словари включены и пак скачан. Грузится при первом обращении.
    static func pack(for lang: String) -> WordPack? {
        guard SettingsManager.shared.frequencyPacks else { return nil }
        let l = String(lang.prefix(2))
        if let p = loaded[l] { return p }
        if absent.contains(l) { return nil }
        if let data = try? Data(contentsOf: storeDirectory.appendingPathComponent("\(l).dict")),
           let p = WordPack(data: data) {
            loaded[l] = p
            return p
        }
        absent.insert(l)
        return nil
    }

    static func reload() {
        loaded = [:]
        absent = []
    }

    struct Manifest: Decodable {
        let format: Int
        let packs: [Entry]
    }

    struct Entry: Codable, Equatable {
        let lang: String
        let version: Int
        let count: Int
        let file: String
        let size: Int
        let sha256: String
    }

    enum SyncError: Error {
        case network
        case badManifest
        case badPack(String)
        case noPacks
        case cancelled
    }

    /// Установленные паки (по файлам метаданных рядом с паками).
    static func installed() -> [Entry] {
        let files = (try? FileManager.default.contentsOfDirectory(at: storeDirectory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .compactMap { try? JSONDecoder().decode(Entry.self, from: Data(contentsOf: $0)) }
            .filter { FileManager.default.fileExists(atPath: storeDirectory.appendingPathComponent("\($0.lang).dict").path) }
            .sorted { $0.lang < $1.lang }
    }

    /// Скачать недостающие и устаревшие паки для языков пары раскладок. Актуальные не трогает.
    /// Возвращает паки, которые стоят после синхронизации.
    static func sync(languages: [String]) async throws -> [Entry] {
        let wanted = Set(languages.map { String($0.prefix(2)) })
        var request = URLRequest(url: manifestURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        guard let (data, response) = try? await URLSession.shared.data(for: request) else { throw SyncError.network }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw SyncError.network }
        guard let manifest = try? JSONDecoder().decode(Manifest.self, from: data), manifest.format == 1 else {
            throw SyncError.badManifest
        }
        // Словари могли выключить, пока шёл запрос: тогда ничего не пишем.
        guard SettingsManager.shared.frequencyPacks else { throw SyncError.cancelled }
        let entries = manifest.packs.filter { wanted.contains($0.lang) && isSafeName($0.file) }
        guard !entries.isEmpty else { throw SyncError.noPacks }

        // Установленным считаем только пак, который действительно читается: битый файл
        // при валидных метаданных скачаем заново.
        let have = installed().filter { pack(for: $0.lang) != nil }
        try FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
        defer { reload() }   // и после частичной неудачи: уже поставленные паки должны подхватиться
        for entry in entries where !have.contains(entry) {
            let url = manifestURL.deletingLastPathComponent().appendingPathComponent(entry.file)
            let req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
            guard let (blob, resp) = try? await URLSession.shared.data(for: req),
                  (resp as? HTTPURLResponse)?.statusCode == 200 else { throw SyncError.network }
            let plain = try await Task.detached { try verify(blob, entry) }.value
            guard SettingsManager.shared.frequencyPacks else { throw SyncError.cancelled }
            try plain.write(to: storeDirectory.appendingPathComponent("\(entry.lang).dict"), options: .atomic)
            try JSONEncoder().encode(entry).write(to: storeDirectory.appendingPathComponent("\(entry.lang).json"), options: .atomic)
            rslog("packs: installed \(entry.lang) v\(entry.version) (\(entry.count) words)")
        }
        return installed()
    }

    enum Outcome {
        case installed([Entry])
        case noPacks
        case failed
        case cancelled   // выключили, пока шла загрузка
    }

    /// Включить словари и скачать паки для текущей пары раскладок. Если скачать не вышло и
    /// ставить нечего, настройка снова выключается: галочка не врёт о том, что словаря нет.
    static func enable() async -> Outcome {
        let settings = SettingsManager.shared
        settings.frequencyPacks = true
        do {
            let entries = try await sync(languages: LayoutSwitcher.pairLanguages())
            settings.frequencyPacksChecked = Date()
            return .installed(entries)
        } catch SyncError.noPacks {
            settings.frequencyPacks = false
            return .noPacks
        } catch SyncError.cancelled {
            return .cancelled
        } catch {
            rslog("packs: sync failed: \(error)")
            if installed().isEmpty { settings.frequencyPacks = false }
            return .failed
        }
    }

    /// Выключить словари: настройка off, файлы удалены — на диске не остаётся ничего.
    static func disable() {
        SettingsManager.shared.frequencyPacks = false
        try? FileManager.default.removeItem(at: storeDirectory)
        reload()
    }

    /// Раз в неделю сверка с манифестом: новые версии паков и паки для сменившейся пары
    /// раскладок. Тихо: при ошибке остаются уже скачанные паки, попробуем в следующий раз.
    static func refreshIfDue() async {
        let settings = SettingsManager.shared
        guard settings.frequencyPacks else { return }
        if let last = settings.frequencyPacksChecked, Date().timeIntervalSince(last) < 7 * 86400 { return }
        do {
            _ = try await sync(languages: LayoutSwitcher.pairLanguages())
            settings.frequencyPacksChecked = Date()
        } catch SyncError.noPacks {
            settings.frequencyPacksChecked = Date()   // для этой пары паков нет — не спрашиваем каждые 6 часов
        } catch {
            rslog("packs: refresh failed: \(error)")
        }
    }

    /// sha256 сжатого файла сверяем с манифестом, распакованный пак обязан пройти проверку
    /// формата — иначе ничего не записываем.
    nonisolated private static func verify(_ blob: Data, _ entry: Entry) throws -> Data {
        guard blob.count == entry.size, blob.count <= 8 << 20 else { throw SyncError.badPack(entry.lang) }
        let digest = SHA256.hash(data: blob).map { String(format: "%02x", $0) }.joined()
        guard digest == entry.sha256.lowercased() else { throw SyncError.badPack(entry.lang) }
        guard let plain = inflate(blob, limit: 16 << 20),
              let pack = WordPack(data: plain), pack.count == entry.count else { throw SyncError.badPack(entry.lang) }
        return plain
    }

    /// raw DEFLATE с потолком на размер результата: NSData.decompressed потолка не имеет,
    /// а 8 МБ сжатых нулей разворачиваются в гигабайты.
    nonisolated private static func inflate(_ blob: Data, limit: Int) -> Data? {
        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }
        guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else { return nil }
        defer { compression_stream_destroy(stream) }
        let chunk = 64 << 10
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk)
        defer { buffer.deallocate() }
        var out = Data()
        return blob.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Data? in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return nil }
            stream.pointee.src_ptr = base
            stream.pointee.src_size = blob.count
            while true {
                stream.pointee.dst_ptr = buffer
                stream.pointee.dst_size = chunk
                let status = compression_stream_process(stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                out.append(buffer, count: chunk - stream.pointee.dst_size)
                if out.count > limit { return nil }
                switch status {
                case COMPRESSION_STATUS_END: return out
                case COMPRESSION_STATUS_OK: continue
                default: return nil
                }
            }
        }
    }

    /// Имя файла из манифеста — только простое имя, без путей.
    nonisolated private static func isSafeName(_ name: String) -> Bool {
        !name.isEmpty && name.count < 64 && name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_" }
            && !name.hasPrefix(".")
    }
}
