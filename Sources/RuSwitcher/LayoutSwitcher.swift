import Carbon
import Foundation

/// Управление раскладками через TIS API
enum LayoutSwitcher {
    /// Возвращает ID текущей раскладки
    static func currentLayoutID() -> String {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else {
            return ""
        }
        return sourceID(source)
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
            TISEnableInputSource(target)
            TISSelectInputSource(target)
        }
    }

    /// Переключает на конкретную раскладку по точному ID
    static func switchTo(layoutID: String) {
        let sources = installedLayouts()
        if let target = sources.first(where: { sourceID($0) == layoutID }) {
            TISEnableInputSource(target)
            TISSelectInputSource(target)
        }
    }

    /// Переключает на конкретную раскладку по подстроке ID
    static func switchTo(containing substring: String) {
        let sources = installedLayouts()
        if let target = sources.first(where: { sourceID($0).lowercased().contains(substring.lowercased()) }) {
            TISEnableInputSource(target)
            TISSelectInputSource(target)
        }
    }

    /// Все установленные раскладки
    static func installedLayouts() -> [TISInputSource] {
        let conditions: CFDictionary = [
            kTISPropertyInputSourceCategory as String: kTISCategoryKeyboardInputSource as Any,
            kTISPropertyInputSourceIsSelectCapable as String: true as Any,
        ] as CFDictionary

        guard let list = TISCreateInputSourceList(conditions, false)?.takeRetainedValue() as? [TISInputSource] else {
            return []
        }
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

    // MARK: - Auto-detect

    private static func autoDetectID1(from sources: [TISInputSource]) -> String {
        // Ищем английскую
        for source in sources {
            let id = sourceID(source)
            if id.contains("ABC") || id.contains("US") || id.contains("British") {
                return id
            }
        }
        return sources.first.map { sourceID($0) } ?? ""
    }

    private static func autoDetectID2(from sources: [TISInputSource]) -> String {
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
