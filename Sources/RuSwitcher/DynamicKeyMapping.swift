import Carbon
import Foundation

/// Динамический маппинг keycode↔символ для любой пары раскладок через UCKeyTranslate
enum DynamicKeyMapping {
    /// Кэш маппинга: ключ = "layoutID1→layoutID2"
    nonisolated(unsafe) private static var mapCache: [String: [Character: Character]] = [:]

    /// Все keycodes для букв/знаков (0-50 покрывает основную клавиатуру)
    private static let allKeycodes: [UInt16] = Array(0...50)

    // MARK: - Public API

    /// Получить символ для keycode в конкретной раскладке
    static func characterForKeycode(_ keycode: UInt16, layout: TISInputSource) -> Character? {
        guard let layoutData = layoutDataForSource(layout) else { return nil }
        return translateKeycode(keycode, layoutData: layoutData, shift: false)
    }

    /// Проверяет, является ли keycode "буквой" в любой из двух раскладок
    static func isLetterKeycode(_ keycode: UInt16) -> Bool {
        let settings = SettingsManager.shared
        let layouts = LayoutSwitcher.installedLayouts()

        // Пробуем с настроенными раскладками
        for layout in layouts {
            let id = LayoutSwitcher.sourceID(layout)
            if id == settings.layout1ID || id == settings.layout2ID || settings.layout1ID.isEmpty {
                if characterForKeycode(keycode, layout: layout) != nil {
                    return true
                }
            }
        }

        // Fallback на статическую таблицу
        return KeyMapping.keycodeToEN[keycode] != nil
    }

    /// Построить маппинг между двумя раскладками
    static func buildMap(from source: TISInputSource, to target: TISInputSource) -> [Character: Character] {
        let sourceID = LayoutSwitcher.sourceID(source)
        let targetID = LayoutSwitcher.sourceID(target)
        let cacheKey = "\(sourceID)→\(targetID)"

        if let cached = mapCache[cacheKey] {
            return cached
        }

        guard let sourceData = layoutDataForSource(source),
              let targetData = layoutDataForSource(target) else {
            return [:]
        }

        var map: [Character: Character] = [:]

        for keycode in allKeycodes {
            // Без shift
            if let sourceChar = translateKeycode(keycode, layoutData: sourceData, shift: false),
               let targetChar = translateKeycode(keycode, layoutData: targetData, shift: false),
               sourceChar != targetChar {
                map[sourceChar] = targetChar
            }
            // С shift
            if let sourceChar = translateKeycode(keycode, layoutData: sourceData, shift: true),
               let targetChar = translateKeycode(keycode, layoutData: targetData, shift: true),
               sourceChar != targetChar {
                map[sourceChar] = targetChar
            }
        }

        mapCache[cacheKey] = map
        return map
    }

    /// Конвертирует текст из текущей раскладки в целевую
    static func convert(_ text: String) -> String {
        let settings = SettingsManager.shared
        let layouts = LayoutSwitcher.installedLayouts()
        let currentID = LayoutSwitcher.currentLayoutID()

        // Определяем source и target раскладки
        let layout1ID = settings.layout1ID.isEmpty ? autoDetectLayout1(from: layouts) : settings.layout1ID
        let layout2ID = settings.layout2ID.isEmpty ? autoDetectLayout2(from: layouts) : settings.layout2ID

        guard let source = layouts.first(where: { LayoutSwitcher.sourceID($0) == currentID }),
              let targetID = (currentID == layout1ID) ? layout2ID : layout1ID as String?,
              let target = layouts.first(where: { LayoutSwitcher.sourceID($0) == targetID }) else {
            // Fallback на статический маппинг
            rslog("DynamicKeyMapping: fallback to static mapping")
            return KeyMapping.convert(text)
        }

        let map = buildMap(from: source, to: target)

        if map.isEmpty {
            rslog("DynamicKeyMapping: empty map, fallback to static")
            return KeyMapping.convert(text)
        }

        return String(text.map { map[$0] ?? $0 })
    }

    /// Очистить кэш (при смене раскладок в настройках)
    static func clearCache() {
        mapCache.removeAll()
    }

    // MARK: - Private

    private static func layoutDataForSource(_ source: TISInputSource) -> Data? {
        guard let ptr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return nil
        }
        let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
        return data
    }

    private static func translateKeycode(_ keycode: UInt16, layoutData: Data, shift: Bool) -> Character? {
        var deadKeyState: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length: Int = 0

        let modifierKeyState: UInt32 = shift ? (UInt32(shiftKey >> 8) & 0xFF) : 0

        let result = layoutData.withUnsafeBytes { rawBuffer -> OSStatus in
            guard let ptr = rawBuffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else {
                return -1
            }
            return UCKeyTranslate(
                ptr,
                keycode,
                UInt16(kUCKeyActionDown),
                modifierKeyState,
                UInt32(LMGetKbdType()),
                UInt32(kUCKeyTranslateNoDeadKeysMask),
                &deadKeyState,
                chars.count,
                &length,
                &chars
            )
        }

        guard result == noErr, length > 0 else { return nil }

        guard let scalar = UnicodeScalar(chars[0]) else { return nil }
        let char = Character(scalar)

        // Фильтруем контрольные символы
        if char.isNewline || char.asciiValue == 0 || chars[0] < 32 {
            return nil
        }

        return char
    }

    private static func autoDetectLayout1(from layouts: [TISInputSource]) -> String {
        // Ищем английскую раскладку
        for layout in layouts {
            let id = LayoutSwitcher.sourceID(layout)
            if id.contains("ABC") || id.contains("US") || id.contains("British") {
                return id
            }
        }
        return layouts.first.map { LayoutSwitcher.sourceID($0) } ?? ""
    }

    private static func autoDetectLayout2(from layouts: [TISInputSource]) -> String {
        let layout1 = autoDetectLayout1(from: layouts)
        // Ищем вторую раскладку (не английскую)
        for layout in layouts {
            let id = LayoutSwitcher.sourceID(layout)
            if id != layout1 {
                return id
            }
        }
        return ""
    }
}
