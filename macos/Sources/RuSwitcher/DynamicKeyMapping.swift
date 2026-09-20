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
            // С shift — но НЕ перезаписываем уже добавленный (без-shift) маппинг: у иврита нет
            // регистра, shift-символ той же клавиши == без-shift-символу, и без гварда заглавная
            // английская затирала строчную (фидбек kobygold: иврит→англ. давал «A/K/U»). Для
            // языков с регистром (ru/en) коллизии нет: без-shift и shift — РАЗНЫЕ исходные символы.
            if let sourceChar = translateKeycode(keycode, layoutData: sourceData, shift: true),
               let targetChar = translateKeycode(keycode, layoutData: targetData, shift: true),
               sourceChar != targetChar, map[sourceChar] == nil {
                map[sourceChar] = targetChar
            }
        }

        mapCache[cacheKey] = map
        return map
    }

    // MARK: - issue #33: пунктуация «сквозь раскладку» (Русская — ПК)

    /// Пара «текущая → противоположная», та же резолюция, что у convertKeys.
    private static func resolveCurrentPair() -> (source: TISInputSource, target: TISInputSource)? {
        let settings = SettingsManager.shared
        let layouts = LayoutSwitcher.installedLayouts()
        let currentID = LayoutSwitcher.currentLayoutID()
        let l1 = settings.layout1ID.isEmpty ? LayoutSwitcher.autoDetectID1(from: layouts) : settings.layout1ID
        let l2 = settings.layout2ID.isEmpty ? LayoutSwitcher.autoDetectID2(from: layouts) : settings.layout2ID
        let targetID = (currentID == l1) ? l2 : l1
        guard let source = layouts.first(where: { LayoutSwitcher.sourceID($0) == currentID }),
              let target = layouts.first(where: { LayoutSwitcher.sourceID($0) == targetID }) else { return nil }
        return (source, target)
    }

    /// Пара, ориентированная НА язык towardLang: target — раскладка этого языка из пары
    /// настроек, source — противоположная. Для SmartConvert, где направление флипа
    /// известно per-word и может не совпадать с «текущая → противоположная».
    private static func resolvePair(towardLang: String) -> (source: TISInputSource, target: TISInputSource)? {
        let settings = SettingsManager.shared
        let layouts = LayoutSwitcher.installedLayouts()
        let l1 = settings.layout1ID.isEmpty ? LayoutSwitcher.autoDetectID1(from: layouts) : settings.layout1ID
        let l2 = settings.layout2ID.isEmpty ? LayoutSwitcher.autoDetectID2(from: layouts) : settings.layout2ID
        guard let s1 = layouts.first(where: { LayoutSwitcher.sourceID($0) == l1 }),
              let s2 = layouts.first(where: { LayoutSwitcher.sourceID($0) == l2 }) else { return nil }
        let want = towardLang.lowercased().prefix(2)
        if LayoutSwitcher.languageCode(s2)?.lowercased().prefix(2) == want { return (s1, s2) }
        if LayoutSwitcher.languageCode(s1)?.lowercased().prefix(2) == want { return (s2, s1) }
        return nil
    }

    /// issue #33: конвертирует знаки через карту пары, только когда с ОБЕИХ сторон
    /// НЕ буква и НЕ цифра. На «Русская — ПК» клавиша /? даёт знак в обеих раскладках
    /// (? → , и / → .) — такие конвертируем; на стандартной Русской по ту сторону от
    /// «,» — буква «б», такие остаются литералом (issue #15, «привет,» не ломаем).
    /// Целевой символ дополнительно ограничен правдоподобной терминальной пунктуацией
    /// (скептик, MEDIUM): у стандартной Русской знаки живут и на ЦИФРОВОМ ряду
    /// (',' = Shift+6 ↔ '^', '.' = Shift+7 ↔ '&', ';' ↔ '*', ':' ↔ '%') — без белого
    /// списка обратное направление давало бы «hello&» вместо «hello.». Список пропускает
    /// оба направления #33 ('?'↔',', '/'↔'.') и блокирует утечку в ^&*%/@#.
    private static let plausibleTargetPunct = Set("?,.!;:…")

    private static func punctApply(_ s: String, map: [Character: Character]) -> String {
        String(s.map { c in
            guard !c.isLetter, !c.isNumber,
                  let t = map[c], plausibleTargetPunct.contains(t) else { return c }
            return t
        })
    }

    /// Пунктуация «сквозь пару» в направлении текущая → противоположная (буферные пути:
    /// конверсия выполняется ДО переключения раскладки, так что source = текущая).
    static func punctThroughCurrentPair(_ s: String) -> String {
        guard !s.isEmpty, s.contains(where: { !$0.isLetter && !$0.isNumber }) else { return s }
        guard let pair = resolveCurrentPair() else { return s }
        return punctApply(s, map: buildMap(from: pair.source, to: pair.target))
    }

    /// Пунктуация «сквозь пару» в явном направлении (флип SmartConvert к языку towardLang).
    static func punctThroughPair(_ s: String, towardLang: String) -> String {
        guard !s.isEmpty, s.contains(where: { !$0.isLetter && !$0.isNumber }) else { return s }
        guard let pair = resolvePair(towardLang: towardLang) else { return s }
        return punctApply(s, map: buildMap(from: pair.source, to: pair.target))
    }

    /// Конвертирует текст из текущей раскладки в целевую
    static func convert(_ inputText: String) -> String {
        // LTR-текст в NFD (декомпозированные ё/й/умляуты — типично из Finder/PDF)
        // сначала прекомпозируем: иначе bail по комбинирующим знакам ниже отказал бы
        // там, где 2.7.0 конвертировал. RTL не нормализуем (никуд, см. normalizedForInsert).
        let text = TextConverter.containsRTL(inputText)
            ? inputText : inputText.precomposedStringWithCanonicalMapping
        // Комбинирующие знаки (никуд/харакат): char-мап работает по графемным кластерам,
        // «буква+знак» в карте не находится и прошла бы насквозь при конверсии соседних
        // букв → полу-конвертированная смесь. Точность важнее полноты — не трогаем.
        if text.unicodeScalars.contains(where: { $0.properties.generalCategory == .nonspacingMark }) {
            rslog("DynamicKeyMapping: combining marks in text — bail")
            return inputText
        }
        let settings = SettingsManager.shared
        let layouts = LayoutSwitcher.installedLayouts()
        let currentID = LayoutSwitcher.currentLayoutID()

        // Определяем source и target раскладки (авто-детект — общий с LayoutSwitcher)
        let layout1ID = settings.layout1ID.isEmpty ? LayoutSwitcher.autoDetectID1(from: layouts) : settings.layout1ID
        let layout2ID = settings.layout2ID.isEmpty ? LayoutSwitcher.autoDetectID2(from: layouts) : settings.layout2ID

        guard let source = layouts.first(where: { LayoutSwitcher.sourceID($0) == currentID }),
              let targetID = (currentID == layout1ID) ? layout2ID : layout1ID as String?,
              let target = layouts.first(where: { LayoutSwitcher.sourceID($0) == targetID }) else {
            // Статический EN↔RU фолбэк — только когда ОБА языка пары ПОЛОЖИТЕЛЬНО en/ru.
            // Нерезолвящийся ID (настроенный, но удалённый из системы иврит — installedLayouts
            // отдаёт только включённые источники!) — это НЕ «пара без иврита»: фолбэк
            // подменил бы целевой язык (ревью-находка, раунд 2). Честный отказ.
            guard pairIsStaticSafe(layouts: layouts, id1: layout1ID, id2: layout2ID) else {
                rslog("DynamicKeyMapping: pair unresolved and not en/ru — no static fallback")
                return inputText
            }
            rslog("DynamicKeyMapping: fallback to static mapping")
            return KeyMapping.convert(text)
        }

        let map = buildMap(from: source, to: target)

        if map.isEmpty {
            guard pairIsStaticSafe(layouts: layouts, id1: layout1ID, id2: layout2ID) else {
                rslog("DynamicKeyMapping: empty map, pair not en/ru — no static fallback")
                return inputText
            }
            rslog("DynamicKeyMapping: empty map, fallback to static")
            return KeyMapping.convert(text)
        }

        return String(text.map { map[$0] ?? $0 })
    }

    /// Source/target раскладки текущей пары (source = активная, target = противоположная).
    /// nil — если пара не разрешилась (настроен, но удалён из системы источник и т.п.).
    private static func currentPairSources() -> (source: TISInputSource, target: TISInputSource)? {
        let settings = SettingsManager.shared
        let layouts = LayoutSwitcher.installedLayouts()
        let currentID = LayoutSwitcher.currentLayoutID()
        let layout1ID = settings.layout1ID.isEmpty ? LayoutSwitcher.autoDetectID1(from: layouts) : settings.layout1ID
        let layout2ID = settings.layout2ID.isEmpty ? LayoutSwitcher.autoDetectID2(from: layouts) : settings.layout2ID
        guard let source = layouts.first(where: { LayoutSwitcher.sourceID($0) == currentID }),
              let targetID = (currentID == layout1ID) ? layout2ID : layout1ID as String?,
              let target = layouts.first(where: { LayoutSwitcher.sourceID($0) == targetID }) else {
            return nil
        }
        return (source, target)
    }

    /// Двунаправленная карта пары: source→target И target→source слиты в одну. Латиница и
    /// кириллица — непересекающиеся ключи; на ОБЩИХ клавишах-знаках (напр. «.» = «ю» в одну
    /// сторону и «/» в другую) предпочитаем БУКВУ — флип в письменность важнее знака.
    private static func bidirectionalMap() -> [Character: Character]? {
        guard let (source, target) = currentPairSources() else { return nil }
        let forward = buildMap(from: source, to: target)
        let backward = buildMap(from: target, to: source)
        if forward.isEmpty && backward.isEmpty { return nil }
        var map = forward
        for (k, v) in backward {
            if let existing = map[k] {
                if !existing.isLetter && v.isLetter { map[k] = v }   // коллизия → буква побеждает
            } else {
                map[k] = v
            }
        }
        return map
    }

    /// issue #22 (A): «конвертировать по тексту» — переворачивает КАЖДЫЙ символ в его
    /// эквивалент другой раскладки, независимо от активной раскладки. Латиница→кириллица И
    /// кириллица→латиница за один проход (лечит mixed «ghtlkj d ьшчув»→«продолжение в …»).
    /// Комбинирующие знаки не трогаем (как в convert). Фолбэк — статическая пара en/ru.
    static func convertBidirectional(_ inputText: String) -> String {
        let text = TextConverter.containsRTL(inputText)
            ? inputText : inputText.precomposedStringWithCanonicalMapping
        if text.unicodeScalars.contains(where: { $0.properties.generalCategory == .nonspacingMark }) {
            return inputText
        }
        if let map = bidirectionalMap(), !map.isEmpty {
            return String(text.map { map[$0] ?? $0 })
        }
        // Фолбэк: пара en/ru статической таблицей (обе стороны, буква уже побеждает — старт с enToRu).
        let settings = SettingsManager.shared
        let layouts = LayoutSwitcher.installedLayouts()
        let l1 = settings.layout1ID.isEmpty ? LayoutSwitcher.autoDetectID1(from: layouts) : settings.layout1ID
        let l2 = settings.layout2ID.isEmpty ? LayoutSwitcher.autoDetectID2(from: layouts) : settings.layout2ID
        guard pairIsStaticSafe(layouts: layouts, id1: l1, id2: l2) else { return inputText }
        var map = KeyMapping.enToRu
        for (k, v) in KeyMapping.ruToEn where map[k] == nil { map[k] = v }
        return String(text.map { map[$0] ?? $0 })
    }

    /// Очистить кэш (при смене раскладок в настройках)
    static func clearCache() {
        mapCache.removeAll()
    }

    /// Статический EN↔RU фолбэк уместен, только когда оба языка пары положительно
    /// определены как en/ru. Из неудачи резолва ID «безопасность» не выводится.
    private static func pairIsStaticSafe(layouts: [TISInputSource], id1: String, id2: String) -> Bool {
        let langs: [String] = [id1, id2].compactMap { id in
            guard let src = layouts.first(where: { LayoutSwitcher.sourceID($0) == id }),
                  let lang = LayoutSwitcher.languageCode(src) else { return nil }
            return String(lang.lowercased().prefix(2))
        }
        return langs.count == 2 && langs.allSatisfy { $0 == "en" || $0 == "ru" }
    }

    /// Конвертирует набранные keycodes в строки исходной и целевой раскладок —
    /// для движка перепечатки (не читаем поле, не трогаем буфер обмена).
    /// nil — если раскладки не определились (тогда вызывающий падает на clipboard).
    static func convertKeys(_ keys: [TypedKey]) -> (original: String, converted: String)? {
        guard !keys.isEmpty else { return nil }
        // Удалёнка: символы проброшены через Screen Sharing (keyCode 0 + char). Конвертируем
        // по самому символу — направление RU↔EN определяет KeyMapping.convert по скрипту
        // (Cyrillic↔Latin), а не по раскладке локальной машины. Так офисный инстанс правильно
        // конвертит «руддщ»→«hello» независимо от того, какая раскладка активна на нём.
        if keys.allSatisfy({ $0.char != nil }) {
            let original = String(keys.compactMap { $0.char })
            return (original, KeyMapping.convert(original))
        }
        let settings = SettingsManager.shared
        let layouts = LayoutSwitcher.installedLayouts()
        let currentID = LayoutSwitcher.currentLayoutID()
        let layout1ID = settings.layout1ID.isEmpty ? LayoutSwitcher.autoDetectID1(from: layouts) : settings.layout1ID
        let layout2ID = settings.layout2ID.isEmpty ? LayoutSwitcher.autoDetectID2(from: layouts) : settings.layout2ID

        guard let source = layouts.first(where: { LayoutSwitcher.sourceID($0) == currentID }),
              let targetID = (currentID == layout1ID) ? layout2ID : layout1ID as String?,
              let target = layouts.first(where: { LayoutSwitcher.sourceID($0) == targetID }),
              let sourceData = layoutDataForSource(source),
              let targetData = layoutDataForSource(target) else {
            return nil
        }

        var original = "", converted = ""
        for k in keys {
            guard let sc = translateKeycode(k.keyCode, layoutData: sourceData, shift: k.shift, caps: k.caps),
                  let tc = translateKeycode(k.keyCode, layoutData: targetData, shift: k.shift, caps: k.caps) else {
                return nil
            }
            original.append(sc)
            converted.append(tc)
        }
        return (original, converted)
    }

    /// issue #24: восстанавливает как-НАБРАННУЮ строку из буфера строки (буквы → символ ТЕКУЩЕЙ
    /// раскладки, пробел-сентинел char==" " → пробел). Для перепечатки строки в терминале.
    /// nil — если раскладка/ключ не разрешились (тогда whole-line не делаем).
    static func lineString(from keys: [TypedKey]) -> String? {
        guard !keys.isEmpty else { return nil }
        // Удалёнка: все символы уже проброшены — берём их напрямую.
        if keys.allSatisfy({ $0.char != nil }) {
            return String(keys.compactMap { $0.char })
        }
        let layouts = LayoutSwitcher.installedLayouts()
        let currentID = LayoutSwitcher.currentLayoutID()
        guard let source = layouts.first(where: { LayoutSwitcher.sourceID($0) == currentID }),
              let sourceData = layoutDataForSource(source) else { return nil }
        var result = ""
        for k in keys {
            if let ch = k.char { result.append(ch); continue }   // пробел-сентинел / проброшенный
            // Скептик 3.2.0: dead-key раскладки (U.S. International): dead-key + база = 2 записи
            // буфера, но 1 символ на экране → backspace по числу символов переберёт. Такой буфер
            // ненадёжен для перепечатки — отказываемся (вызывающий падает на последнее слово).
            if isDeadKey(k.keyCode, layoutData: sourceData, shift: k.shift, caps: k.caps) { return nil }
            guard let sc = translateKeycode(k.keyCode, layoutData: sourceData, shift: k.shift, caps: k.caps) else {
                return nil
            }
            result.append(sc)
        }
        return result
    }

    /// true — клавиша является dead key в этой раскладке (композиция «мёртвая клавиша + база»),
    /// т.е. сама по себе символа не даёт, а копит состояние. UCKeyTranslate БЕЗ NoDeadKeys-маски:
    /// dead key возвращает length 0 и ненулевой deadKeyState.
    private static func isDeadKey(_ keycode: UInt16, layoutData: Data, shift: Bool, caps: Bool) -> Bool {
        var deadKeyState: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length = 0
        var mods: UInt32 = shift ? (UInt32(shiftKey >> 8) & 0xFF) : 0
        if caps { mods |= UInt32(alphaLock >> 8) & 0xFF }
        let r = layoutData.withUnsafeBytes { raw -> OSStatus in
            guard let ptr = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return -1 }
            return UCKeyTranslate(ptr, keycode, UInt16(kUCKeyActionDown), mods, UInt32(LMGetKbdType()),
                                  0 /* dead keys ВКЛючены */, &deadKeyState, chars.count, &length, &chars)
        }
        return r == noErr && length == 0 && deadKeyState != 0
    }

    // Авто-детект раскладок живёт в LayoutSwitcher (autoDetectID1/ID2).

    // MARK: - Private

    private static func layoutDataForSource(_ source: TISInputSource) -> Data? {
        guard let ptr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return nil
        }
        let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
        return data
    }

    private static func translateKeycode(_ keycode: UInt16, layoutData: Data, shift: Bool, caps: Bool = false) -> Character? {
        var deadKeyState: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length: Int = 0

        var modifierKeyState: UInt32 = shift ? (UInt32(shiftKey >> 8) & 0xFF) : 0
        if caps { modifierKeyState |= UInt32(alphaLock >> 8) & 0xFF }

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
}
