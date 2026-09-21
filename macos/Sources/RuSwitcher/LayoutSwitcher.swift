import Carbon
import Foundation

/// Управление раскладками через TIS API
enum LayoutSwitcher {
    /// Кэш списка раскладок: авто-путь дёргает TISCreateInputSourceList по 3–4 раза на
    /// каждый пробел (convertKeys → currentAndOppositeLanguage → switchToOpposite), а
    /// список меняется только при добавлении/удалении раскладки в системе. Инвалидация —
    /// по распределённому уведомлению TIS (см. installObserverIfNeeded).
    nonisolated(unsafe) private static var cachedLayouts: [TISInputSource]?
    /// Кэш языка по sourceID: для сторонних раскладок languageCode гоняет UCKeyTranslate-пробы.
    /// nil кодируем пустой строкой, чтобы не пере-пробовать безъязыкие раскладки.
    nonisolated(unsafe) private static var languageCache: [String: String] = [:]
    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var observerInstalled = false

    private static func installObserverIfNeeded() {
        // Вызывается только под cacheLock (из installedLayouts) — гонки на флаге нет.
        guard !observerInstalled else { return }
        observerInstalled = true
        let name = Notification.Name(kTISNotifyEnabledKeyboardInputSourcesChanged as String)
        _ = DistributedNotificationCenter.default().addObserver(forName: name, object: nil, queue: nil) { _ in
            cacheLock.lock()
            cachedLayouts = nil
            languageCache.removeAll()
            cacheLock.unlock()
            DynamicKeyMapping.clearCache()   // данные раскладки могли смениться вместе со списком
        }
    }

    /// Возвращает ID текущей раскладки
    static func currentLayoutID() -> String {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else {
            return ""
        }
        return sourceID(source)
    }

    /// Код языка ТЕКУЩЕЙ раскладки (BCP-47, например "ru"/"en"). nil если недоступен.
    /// Надёжнее парсинга ID: тот же признак, что использует сама ОС.
    static func currentLanguageCode() -> String? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else {
            return nil
        }
        return languageCode(source)
    }

    /// Переключает на противоположную раскладку (из настроенной пары)
    static func switchToOpposite() {
        let current = currentLayoutID()
        let settings = SettingsManager.shared
        let sources = installedLayouts()

        let id1 = settings.layout1ID.isEmpty ? autoDetectID1(from: sources) : settings.layout1ID
        let id2 = settings.layout2ID.isEmpty ? autoDetectID2(from: sources) : settings.layout2ID

        let targetID = (current == id1) ? id2 : id1

        if let target = sources.first(where: { sourceID($0) == targetID }) {
            select(target)
        }
    }

    /// Переключает на конкретную раскладку по точному ID
    static func switchTo(layoutID: String) {
        let sources = installedLayouts()
        if let target = sources.first(where: { sourceID($0) == layoutID }) {
            select(target)
        }
    }

    /// issue #19: выбирает источник, вызывая TISEnableInputSource ТОЛЬКО если он
    /// реально выключен. На сторонних раскладках (напр. «Ilya Birman Typography»)
    /// enable уже включённого источника даёт системный запрос безопасности на КАЖДОЕ
    /// переключение. Наш `installedLayouts()` через TISCreateInputSourceList(_, false)
    /// и так отдаёт только включённые источники, так что обычно enable не нужен вовсе.
    private static func select(_ source: TISInputSource) {
        if let ptr = TISGetInputSourceProperty(source, kTISPropertyInputSourceIsEnabled),
           Unmanaged<CFBoolean>.fromOpaque(ptr).takeUnretainedValue() != kCFBooleanTrue {
            TISEnableInputSource(source)
        }
        TISSelectInputSource(source)
    }

    /// Все установленные раскладки (кэш; инвалидация по уведомлению TIS)
    static func installedLayouts() -> [TISInputSource] {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        installObserverIfNeeded()
        if let cached = cachedLayouts { return cached }

        let conditions: CFDictionary = [
            kTISPropertyInputSourceCategory as String: kTISCategoryKeyboardInputSource as Any,
            kTISPropertyInputSourceIsSelectCapable as String: true as Any,
        ] as CFDictionary

        guard let list = TISCreateInputSourceList(conditions, false)?.takeRetainedValue() as? [TISInputSource] else {
            return []   // сбой не кэшируем — следующий вызов попробует снова
        }
        cachedLayouts = list
        return list
    }

    /// ID раскладки (например "com.apple.keylayout.Russian")
    static func sourceID(_ source: TISInputSource) -> String {
        guard let ptr = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else {
            return ""
        }
        return Unmanaged<CFString>.fromOpaque(ptr).takeUnretainedValue() as String
    }

    /// Локализованное имя раскладки (например "Русская")
    static func sourceName(_ source: TISInputSource) -> String {
        guard let ptr = TISGetInputSourceProperty(source, kTISPropertyLocalizedName) else {
            return sourceID(source)
        }
        return Unmanaged<CFString>.fromOpaque(ptr).takeUnretainedValue() as String
    }

    /// Код языка раскладки (BCP-47, например "ru", "en").
    /// Стандартные раскладки Apple отдают конкретный код первым в kTISPropertyInputSourceLanguages
    /// ("ru"/"uk"/"en"…). Сторонние `.keylayout` (Ilya Birman и др.) НЕ декларируют язык — macOS
    /// отдаёт пустую строку первой и мусорный список дальше (проверено: ["", "af", …]), из-за чего
    /// флаг/авто/каретка ломались (#18). Поэтому при пустых метаданных определяем язык по РЕАЛЬНОМУ
    /// выводу раскладки (UCKeyTranslate → скрипт → язык).
    static func languageCode(_ source: TISInputSource) -> String? {
        let id = sourceID(source)
        cacheLock.lock()
        if let cached = languageCache[id] {
            cacheLock.unlock()
            return cached.isEmpty ? nil : cached
        }
        cacheLock.unlock()

        let result: String?
        if let ptr = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages),
           let langs = Unmanaged<CFArray>.fromOpaque(ptr).takeUnretainedValue() as? [String],
           let first = langs.first, !first.isEmpty {
            result = first                     // стандартная раскладка: конкретный язык из метаданных
        } else {
            result = scriptLanguage(source)    // сторонняя: определяем по выводу
        }

        cacheLock.lock()
        languageCache[id] = result ?? ""
        cacheLock.unlock()
        return result
    }

    /// Язык по СКРИПТУ реального вывода раскладки (для сторонних раскладок без метаданных).
    /// Пробуем несколько буквенных клавиш домашнего ряда, берём скрипт первого буквенного глифа.
    static func scriptLanguage(_ source: TISInputSource) -> String? {
        guard let dp = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return nil
        }
        let data = Unmanaged<CFData>.fromOpaque(dp).takeUnretainedValue() as Data
        // keycodes домашнего ряда QWERTY: a s d f j k l — буквы почти в любой раскладке
        for keyCode: UInt16 in [0, 1, 2, 3, 38, 40, 37] {
            guard let ch = translate(data, keyCode: keyCode)?.unicodeScalars.first, ch.properties.isAlphabetic else { continue }
            switch ch.value {
            case 0x0400...0x04FF: return "ru"   // кириллица (конкретика ru/uk/be недоступна без метаданных — берём ru как самый частый)
            case 0x0041...0x005A, 0x0061...0x007A: return "en"  // латиница
            case 0x0590...0x05FF: return "he"   // иврит
            case 0x0370...0x03FF: return "el"   // греческий
            case 0x0530...0x058F: return "hy"   // армянский
            case 0x10A0...0x10FF: return "ka"   // грузинский
            case 0x0600...0x06FF: return "ar"   // арабский
            default: continue
            }
        }
        return nil
    }

    /// Один символ, который печатает раскладка для keyCode (без мёртвых клавиш, без модификаторов).
    private static func translate(_ layoutData: Data, keyCode: UInt16) -> String? {
        var deadState: UInt32 = 0
        var len = 0
        var chars = [UniChar](repeating: 0, count: 4)
        let status = layoutData.withUnsafeBytes { raw -> OSStatus in
            guard let kl = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return -1 }
            return UCKeyTranslate(kl, keyCode, UInt16(kUCKeyActionDown), 0, UInt32(LMGetKbdType()),
                                  OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadState, chars.count, &len, &chars)
        }
        guard status == noErr, len > 0 else { return nil }
        return String(utf16CodeUnits: chars, count: len)
    }

    /// Коды языков текущей и противоположной раскладок (для авто-детекта раскладки).
    static func currentAndOppositeLanguage() -> (current: String, opposite: String)? {
        let settings = SettingsManager.shared
        let sources = installedLayouts()
        let currentID = currentLayoutID()
        let id1 = settings.layout1ID.isEmpty ? autoDetectID1(from: sources) : settings.layout1ID
        let id2 = settings.layout2ID.isEmpty ? autoDetectID2(from: sources) : settings.layout2ID
        let targetID = (currentID == id1) ? id2 : id1
        guard let cur = sources.first(where: { sourceID($0) == currentID }),
              let tgt = sources.first(where: { sourceID($0) == targetID }),
              let curLang = languageCode(cur), let tgtLang = languageCode(tgt) else {
            return nil
        }
        return (curLang, tgtLang)
    }

    // MARK: - Auto-detect

    /// Авто-определение «английской» (латинской) раскладки (используется и из DynamicKeyMapping).
    static func autoDetectID1(from sources: [TISInputSource]) -> String {
        // По ЯЗЫКУ (теперь надёжно и для сторонних раскладок — см. languageCode/scriptLanguage).
        if let en = sources.first(where: { languageCode($0) == "en" }) {
            return sourceID(en)
        }
        // Фолбэк на подстроку ID (вдруг язык не определился вовсе).
        for source in sources {
            let id = sourceID(source)
            if id.contains("ABC") || id.contains("US") || id.contains("British") {
                return id
            }
        }
        return sources.first.map { sourceID($0) } ?? ""
    }

    /// Авто-определение второй (не-английской) раскладки.
    static func autoDetectID2(from sources: [TISInputSource]) -> String {
        let id1 = autoDetectID1(from: sources)
        // Ищем вторую (не английскую)
        for source in sources {
            let id = sourceID(source)
            if id != id1 {
                return id
            }
        }
        return ""
    }
}
