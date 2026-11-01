import AppKit
import ApplicationServices
import CoreGraphics

/// Конвертация текста между раскладками
@MainActor
final class TextConverter {
    private var lastConvertedCount = 0
    private var lastBoundaryCount = 0
    private var savedClipboardItems: [NSPasteboardItem]?
    private var clipboardRestoreWork: DispatchWorkItem?
    /// Буфер реально менялся: выделение, прочитанное через AX, его не трогает, и при отказе
    /// от конверсии переписывать нечего.
    private var clipboardDirty = false
    private var isConverting = false
    /// Очередь для инжекта нажатий буферного движка — чтобы usleep не блокировал
    /// main-поток, на котором висит event tap (иначе тап голодает → лаги/потери нажатий).
    nonisolated private let injectQueue = DispatchQueue(label: "com.ruswitcher.inject", qos: .userInteractive)

    // Состояние движка перепечатки (буфер нажатий → юникод-вставка)
    private var lastOriginal = ""
    private var lastConverted = ""
    private var lastWasBuffer = false
    /// 3.5.0b: откат последней замены меняет раскладку (конверсия) или нет (автозамена, правка).
    private(set) var lastUndoSwitchesLayout = true

    /// 3.5.0b (ревью C1): приостановка event tap на время путей, которые шлют клавиши
    /// (Cmd+C, Shift+Cmd+←, Cmd+A) с главного потока и ждут результата в usleep. Активный tap
    /// (.defaultTap — придержка Enter/Tab или Caps Lock-триггер) держит каждое событие до
    /// ответа колбэка, а колбэк живёт в главном run loop: свои же клавиши доходили бы только
    /// после возврата, копирование «не удавалось», а опоздавший Cmd+C затирал буфер обмена.
    /// Ставит AppDelegate (KeyboardMonitor.withTapSuspended); без него — просто выполняем.
    var suspendTap: ((() -> Void) -> Void)?

    private func gated<T>(_ body: () -> T) -> T {
        guard let suspend = suspendTap else { return body() }
        var result: T?
        suspend { result = body() }
        return result!
    }
    /// Последняя clipboard-конверсия содержала RTL — реконверт стрелками небезопасен.
    private var lastClipboardRTL = false

    /// RTL-скаляры: иврит, арабский + презентационные формы (копипаста из PDF).
    nonisolated static func containsRTL(_ s: String) -> Bool {
        s.unicodeScalars.contains {
            ($0.value >= 0x0590 && $0.value <= 0x06FF)
            || ($0.value >= 0xFB1D && $0.value <= 0xFDFF)
            || ($0.value >= 0xFE70 && $0.value <= 0xFEFF)
        }
    }

    /// NFC-нормализация перед вставкой — но НЕ для иврита/арабского: канонич. композиция
    /// может переставить/слить комбинирующие знаки (никуд/харакат), и число кодпоинтов
    /// разъедется со счётчиком Backspace/Shift-Left. Для RTL оставляем строку как есть.
    nonisolated static func normalizedForInsert(_ s: String) -> String {
        containsRTL(s) ? s : s.precomposedStringWithCanonicalMapping
    }

    /// Создаёт CGEventSource с маркером, чтобы KeyboardMonitor игнорировал наши события
    nonisolated private func makeSource() -> CGEventSource? {
        let source = CGEventSource(stateID: .hidSystemState)
        source?.userData = kRuSwitcherEventMarker
        return source
    }

    /// Проверяет, что текущий фокусированный элемент — редактируемое текстовое поле
    private func isFocusedElementEditable() -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication else { return false }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        // Занятое приложение (Electron в GC, IDE в индексации) без таймаута держит main
        // до 6с (дефолт AX) — это и есть «фризы». 0.2с хватает живому ответу; SpotlightAX
        // такой же таймаут уже ставит.
        AXUIElementSetMessagingTimeout(axApp, 0.2)

        var focusedRaw: AnyObject?
        let err = AXUIElementCopyAttributeValue(axApp, kAXFocusedUIElementAttribute as CFString, &focusedRaw)
        guard err == .success, let focused = focusedRaw else {
            rslog("editable: no focused element")
            return false
        }

        let element = focused as! AXUIElement

        // Проверяем роль
        var roleRaw: AnyObject?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRaw)
        let role = (roleRaw as? String) ?? ""

        // Текстовые роли
        let textRoles = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField", "AXWebArea"]
        if textRoles.contains(role) {
            // Дополнительно: не read-only?
            var editableRaw: AnyObject?
            let editErr = AXUIElementCopyAttributeValue(element, "AXEditable" as CFString, &editableRaw)
            // Если атрибут отсутствует — считаем editable (у AXWebArea его может не быть)
            if editErr == .success, let editable = editableRaw as? Bool {
                rslog("editable: role=\(role) editable=\(editable)")
                return editable
            }
            rslog("editable: role=\(role) (no AXEditable attr, assuming yes)")
            return true
        }

        rslog("editable: role=\(role) — not a text field")
        return false
    }

    // MARK: - Public API

    /// Движок перепечатки: стираем набранное и впечатываем конвертированное через
    /// юникод-вставку — без буфера обмена и без выделения (работает в Atom/Electron).
    /// Падает на clipboard-движок, если буфера нет (текст выделен мышью) или
    /// раскладки не определились.
    /// passthroughSuffix (issue #15): прилипшая к слову пунктуация — стирается вместе со
    /// словом и возвращается в поле как есть, БЕЗ кейкод-конверсии (',' EN ↔ 'б' RU).
    /// typedSuffix (issue #33): суффикс КАК НАБРАН, если passthroughSuffix уже
    /// сконвертирован («?»→«,» на Русской — ПК) — для честного отката реконвертом.
    /// Пустой typedSuffix означает «совпадает с passthroughSuffix».
    func convert(wordKeys: [TypedKey], prevWordKeys: [TypedKey], boundaryCount: Int,
                 passthroughSuffix: String = "", typedSuffix: String = "",
                 convertedOverride: String? = nil) -> Bool {
        let keys: [TypedKey]
        let trailingSpaces: Int
        if !wordKeys.isEmpty {
            keys = wordKeys; trailingSpaces = 0
        } else if !prevWordKeys.isEmpty && boundaryCount > 0 {
            keys = prevWordKeys; trailingSpaces = boundaryCount
        } else {
            // нет буфера — возможно, выделен мышью старый текст: пусть решает clipboard
            return convertViaClipboard(wordLength: 0, prevWordLength: 0, boundaryCount: 0)
        }

        guard let pair = DynamicKeyMapping.convertKeys(keys) else {
            // Clipboard-путь про суффикс не знает (селекция посчиталась бы неверно) —
            // точность важнее полноты: с суффиксом тихо отказываемся.
            guard passthroughSuffix.isEmpty else {
                rslog("buffer convert: suffix + unresolved layouts — bail")
                return false
            }
            rslog("buffer convert: layouts not resolved — fallback to clipboard")
            return convertViaClipboard(wordLength: wordKeys.count, prevWordLength: prevWordKeys.count, boundaryCount: boundaryCount)
        }

        // 3.5.0b: ядро с исправленными двумя заглавными («RJulf» → «Когда», а не «КОгда»).
        let converted = convertedOverride ?? pair.converted

        guard !isConverting else { return false }
        isConverting = true

        let spaces = String(repeating: " ", count: trailingSpaces)
        let bsCount = keys.count + passthroughSuffix.count + trailingSpaces
        // issue #33 (скептик, HIGH): в lastOriginal — суффикс КАК НАБРАН, иначе реконверт
        // после «tkrb?»→«елки,» восстанавливал бы «tkrb,» вместо «tkrb?».
        let originalSuffix = typedSuffix.isEmpty ? passthroughSuffix : typedSuffix
        let insert = converted + passthroughSuffix + spaces
        lastOriginal = pair.original + originalSuffix + spaces
        lastConverted = converted + passthroughSuffix + spaces
        lastWasBuffer = true
        lastUndoSwitchesLayout = true
        rslog("buffer convert: \(keys.count) keys (+\(passthroughSuffix.count) punct, +\(trailingSpaces) sp)")

        // Инжект — вне main, чтобы usleep не голодал event tap.
        injectQueue.async { [weak self] in
            guard let self else { return }
            self.backspace(bsCount)
            usleep(8_000)   // короткий зазор стирание→вставка: порядок и так гарантирован очередью HID
            self.insertText(insert)
            Task { @MainActor in self.isConverting = false }
        }
        return true
    }

    /// 3.5.0b: заменить хвост поля — стереть deleteCount символов и вставить insert.
    /// repostKey — придержанная клавиша (Enter/Tab), уходит ПОСЛЕ вставки в той же очереди,
    /// поэтому порядок гарантирован. Уходит ВСЕГДА, даже если движок занят: проглоченный
    /// Enter без повтора — потерянная отправка сообщения.
    /// clearInlineCompletion — перед стиранием убрать выделенное автодополнение (адресная
    /// строка): иначе первый Backspace съест его, и слово сотрётся со сдвигом (класс #16).
    /// undoOriginal — что вернёт откат триггером; nil — отката нет, состояние чистится.
    @discardableResult
    func replaceTail(deleteCount: Int, insert: String,
                     repostKey: (code: UInt16, flags: CGEventFlags)? = nil,
                     clearInlineCompletion: Bool = false, undoOriginal: String? = nil,
                     skipIfInlineCompletion: Bool = false) -> Bool {
        // Ревью M7: фокус не в тексте (список Finder с быстрым поиском по имени, таблица) —
        // Backspace и вставка ушли бы не туда. Только отдаём клавишу.
        if let k = repostKey, focusIsNotText() {
            injectQueue.async { [weak self] in self?.simKey(keyCode: k.code, flags: k.flags) }
            rslog("replaceTail: focus not in text — key passed through")
            return false
        }
        guard !isConverting else {
            if let k = repostKey { injectQueue.async { [weak self] in self?.simKey(keyCode: k.code, flags: k.flags) } }
            rslog("replaceTail: busy — key passed through")
            return false
        }
        isConverting = true
        if let orig = undoOriginal {
            lastOriginal = orig
            lastConverted = insert
            lastWasBuffer = true
            lastUndoSwitchesLayout = false
        } else {
            clearState()
        }
        var extra = 0
        if clearInlineCompletion, let sel = selectedTextAX(), !sel.isEmpty {
            // Ревью M6: под выделением — подсказка адресной строки, слово в поле — её начало
            // («weath» → weather.com). Исправление опечатки тут превратило бы его в «wrath».
            if skipIfInlineCompletion {
                if let k = repostKey { injectQueue.async { [weak self] in self?.simKey(keyCode: k.code, flags: k.flags) } }
                isConverting = false
                rslog("replaceTail: inline completion — typo fix skipped, key passed through")
                return false
            }
            extra = 1
        }
        let normalized = Self.normalizedForInsert(insert)
        rslog("replaceTail: del=\(deleteCount)+\(extra) ins=\(insert.count) key=\(repostKey != nil)")
        injectQueue.async { [weak self] in
            guard let self else { return }
            self.backspace(deleteCount + extra)
            usleep(8_000)
            self.insertText(normalized)
            if let k = repostKey {
                usleep(8_000)
                self.simKey(keyCode: k.code, flags: k.flags)
            }
            Task { @MainActor in self.isConverting = false }
        }
        return true
    }

    /// issue #24: конвертировать всю набранную строку (от курсора до начала строки) без
    /// выделения мышью. Сами выделяем Shift+Cmd+← и прогоняем через путь выделения (умная
    /// конверсия починит только слова не в той раскладке, верные — оставит). При no-op/сбое
    /// снимаем выделение (иначе строка осталась бы подсвеченной). Реконверт восстановит через
    /// сохранённый оригинал (см. convertViaClipboard/reconvertViaClipboard).
    func convertLine() -> Bool { gated { convertLineImpl() } }
    private func convertLineImpl() -> Bool {
        guard !isConverting else { return false }
        // Скептик 3.2.0: не шлём Shift+Cmd+← вне текстового поля — иначе аккорд сработает как
        // ярлык приложения (напр. выделит не то). В поле — работаем.
        guard isFocusedElementEditable() else { rslog("convertLine: non-editable focus — bail"); return false }

        // Выделяем до начала строки влево (обычный LTR). Проверяем через AX, реально ли что-то
        // выделилось: только тогда конвертим и (при no-op) безопасно снимаем стрелкой.
        simKey(keyCode: KC.left, flags: [.maskShift, .maskCommand])
        usleep(60_000)
        if !focusedSelectionIsEmpty() {
            let ok = convertViaClipboard(wordLength: 0, prevWordLength: 0, boundaryCount: 0, wholeLine: true)
            if !ok { simKey(keyCode: KC.right, flags: []) }   // снять выделение (оно есть — стрелка не двигает каретку лишнего)
            return ok
        }

        // issue #26: влево выделилось ПУСТО → RTL-веб-поле (адресная строка Chrome, WhatsApp Web),
        // где начало строки справа. Пробуем вправо. Стрелку-collapse влево НЕ жали — каретка на месте,
        // так что первый символ не теряется. Пробуем другую сторону ТОЛЬКО при пустом влево — значит
        // LTR-строку «вперёд» мы не трогаем (нет переписывания верного текста, скептик #26).
        simKey(keyCode: KC.right, flags: [.maskShift, .maskCommand])
        usleep(60_000)
        if !focusedSelectionIsEmpty() {
            let ok = convertViaClipboard(wordLength: 0, prevWordLength: 0, boundaryCount: 0, wholeLine: true)
            if !ok { simKey(keyCode: KC.left, flags: []) }
            return ok
        }
        return false   // пусто в обе стороны — пустая строка; каретка не двигалась
    }

    /// true — текущее выделение фокус-элемента ПУСТО (по AX). На любой неопределённости (нет фокуса,
    /// атрибут недоступен) возвращаем false = «выделение есть» — безопасно для LTR: не пробуем вторую
    /// сторону и не переписываем текст «вперёд». RTL-фикс сработает лишь там, где AX надёжно отдаёт пусто.
    private func focusedSelectionIsEmpty() -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication else { return false }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(axApp, 0.25)
        var focusedRaw: AnyObject?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedUIElementAttribute as CFString, &focusedRaw) == .success,
              let focused = focusedRaw else { return false }
        let element = focused as! AXUIElement
        var selRaw: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &selRaw) == .success,
              let sel = selRaw as? String else { return false }
        return sel.isEmpty
    }

    /// Фокусный элемент фронтмост-приложения (nil — AX недоступен).
    private func focusedElement() -> AXUIElement? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(axApp, 0.25)
        var focusedRaw: AnyObject?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedUIElementAttribute as CFString, &focusedRaw) == .success,
              let focused = focusedRaw else { return nil }
        let element = focused as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.25)   // ревью M5: запросы идут к элементу, не к приложению
        return element
    }

    /// 3.5.0b (ревью M7): роль сфокусированного элемента — только если AX её отдал.
    private func focusedRole() -> String? {
        guard let element = focusedElement() else { return nil }
        var roleRaw: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRaw) == .success else { return nil }
        return roleRaw as? String
    }

    /// Роли, где Enter/Tab точно не текст: список файлов, таблица, кнопка. Неизвестная роль
    /// или сбой AX — считаем текстом (Electron, Qt часто отдают пусто).
    private static let nonTextRoles: Set<String> = [
        "AXList", "AXOutline", "AXTable", "AXBrowser", "AXGrid", "AXButton",
        "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenu", "AXMenuItem",
    ]

    /// Enter/Tab нельзя заменять перепечаткой. AXScrollArea считается не текстом только в
    /// Finder (вид значками): в Outlook так выглядит тело письма, и там Enter не срабатывал.
    private func focusIsNotText() -> Bool {
        guard let role = focusedRole() else { return false }
        if role == "AXScrollArea" {
            return NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder"
        }
        return Self.nonTextRoles.contains(role)
    }

    /// Выделенный текст через AX: "" — выделения точно нет, nil — приложение его не отдаёт.
    func selectedTextAX() -> String? {
        guard let element = focusedElement() else { return nil }
        var selRaw: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &selRaw) == .success else { return nil }
        return selRaw as? String
    }

    /// Выделение через Cmd+C — только в текстовом поле: в списках Finder копируются имена
    /// файлов, редакторы без выделения копируют строку целиком, а клиенты удалёнки шлют
    /// Ctrl+C в гостя. Многострочное не берём. Буфер обмена возвращаем сразу.
    func copySelectionInTextField() -> String? { gated { copySelectionInTextFieldImpl() } }
    private func copySelectionInTextFieldImpl() -> String? {
        guard !isConverting, let element = focusedElement() else { return nil }
        var roleRaw: AnyObject?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRaw)
        let textRoles: Set<String> = [kAXTextFieldRole as String, kAXTextAreaRole as String, kAXComboBoxRole as String, "AXSearchField"]
        guard let role = roleRaw as? String, textRoles.contains(role) else { return nil }
        let pasteboard = NSPasteboard.general
        cancelClipboardRestore()
        if savedClipboardItems == nil { savedClipboardItems = snapshotPasteboard(pasteboard) }
        isConverting = true
        defer { restoreClipboardNow(); isConverting = false }
        guard let text = tryCopy(pasteboard), !text.contains(where: { $0.isNewline }) else { return nil }
        return text
    }

    /// issue #24 (терминал): конвертирует всю набранную строку по БУФЕРУ нажатий — backspace на
    /// длину строки + перепечатка сконвертированного. Без OS-выделения (работает в терминалах и
    /// для иврита). Только для свежей непрерывной строки (буфер сбрасывается на пунктуации/Enter/
    /// сдвиге курсора → вызывающий откатывается на последнее слово). Реконверт — через lastOriginal.
    func convertLineBuffer(_ lineKeys: [TypedKey]) -> Bool {
        guard !isConverting, !lineKeys.isEmpty else { return false }
        guard let original = DynamicKeyMapping.lineString(from: lineKeys), !original.isEmpty else { return false }
        let s = SettingsManager.shared
        let converted = s.convertByText ? DynamicKeyMapping.convertBidirectional(original)
                      : s.smartConversion ? SmartConvert.selection(original)
                      : DynamicKeyMapping.convert(original)
        guard converted != original else { return false }   // строка уже верная — no-op
        isConverting = true
        lastWasBuffer = true
        lastUndoSwitchesLayout = true   // ревью I3: откат конверсии меняет раскладку
        lastOriginal = original
        lastConverted = converted
        let bsCount = original.count
        rslog("line convert (terminal buffer): \(original.count)→\(converted.count) chars")
        injectQueue.async { [weak self] in
            guard let self else { return }
            self.backspace(bsCount)
            usleep(8_000)   // короткий зазор стирание→вставка: порядок и так гарантирован очередью HID
            self.insertText(converted)
            Task { @MainActor in self.isConverting = false }
        }
        return true
    }

    // MARK: - issue #29: смена регистра (как Alt+Break в Punto)

    private var caseWord: String?   // слово/строка, по которой сейчас циклим регистр (буферный путь)
    private var caseIndex = 0
    private var caseOnScreen = ""   // ТЕКУЩИЙ экранный текст цикла — его длину и стираем (не original.count:
                                    // регистр не всегда сохраняет длину, напр. немецкое ß→SS, скептик #29)

    /// Общий движок цикла регистра по буферу (слово или строка). original — как набрано. Стирает
    /// реальную экранную длину и пропускает варианты, не дающие видимого изменения (односимвольные
    /// слова, каузлес-скрипты вроде иврита → просто no-op вместо мигания). Возвращает true при инжекте.
    private func cycleCaseByBuffer(_ original: String) -> Bool {
        if original != caseWord {
            caseWord = original
            caseIndex = TextConverter.caseVariant(original, 0) == original ? 1 : 0
            caseOnScreen = original                       // на экране — набранный оригинал
        } else {
            caseIndex = (caseIndex + 1) % 3
        }
        // Пропускаем варианты, совпадающие с тем, что уже на экране (иначе мёртвый тап / миганиe).
        var idx = caseIndex, changed = TextConverter.caseVariant(original, idx), tries = 0
        while changed == caseOnScreen && tries < 3 {
            idx = (idx + 1) % 3; changed = TextConverter.caseVariant(original, idx); tries += 1
        }
        guard changed != caseOnScreen else { return false }   // все варианты равны (иврит и т.п.) → пропуск
        caseIndex = idx
        let bs = caseOnScreen.count                           // стираем РЕАЛЬНУЮ экранную длину
        caseOnScreen = changed
        isConverting = true
        rslog("case: buffer \(original.count) chars → variant \(idx), bs \(bs)")
        injectQueue.async { [weak self] in
            guard let self else { return }
            self.backspace(bs)
            usleep(20_000)
            self.insertText(changed)
            Task { @MainActor in self.isConverting = false }
        }
        return true
    }

    /// Вариант регистра по индексу цикла: 0 — ВЕРХНИЙ, 1 — нижний, 2 — С заглавной.
    private static func caseVariant(_ s: String, _ i: Int) -> String {
        switch ((i % 3) + 3) % 3 {
        case 0:  return s.uppercased()
        case 1:  return s.lowercased()
        default: return capitalizedVariant(s)
        }
    }

    /// Одно слово — с заглавной буквы. Несколько слов — как в предложении: заглавные только
    /// в начале текста и после . ! ? … (#38).
    nonisolated static func capitalizedVariant(_ s: String) -> String {
        guard s.contains(where: { $0.isWhitespace }) else { return s.capitalized }
        var out = ""
        var capitalizeNext = true
        var afterStop = false          // знак конца предложения считается только перед пробелом: «т.е.»
        for ch in s.lowercased() {
            if capitalizeNext, ch.isLetter {
                out += ch.uppercased()
                capitalizeNext = false
                afterStop = false
                continue
            }
            out.append(ch)
            if ch.isNewline || (afterStop && ch.isWhitespace) {
                capitalizeNext = true
                afterStop = false
            } else if ".!?…".contains(ch) {
                afterStop = true
            } else if ch.isLetter || ch.isNumber {
                capitalizeNext = false
                afterStop = false
            }
        }
        return out
    }

    /// Сменить регистр последнего набранного слова (буфер) или выделения (clipboard). Раскладку
    /// НЕ трогает. По повторным нажатиям на то же слово циклит ВЕРХНИЙ → нижний → Заглавный.
    func changeCase(wordKeys: [TypedKey]) -> Bool {
        guard !isConverting else { return false }
        if !wordKeys.isEmpty { return changeCaseWord(wordKeys) }
        return changeCaseSelection()
    }

    private func changeCaseWord(_ keys: [TypedKey]) -> Bool {
        guard let pair = DynamicKeyMapping.convertKeys(keys),
              !pair.original.isEmpty, pair.original.contains(where: { $0.isLetter }) else { return false }
        return cycleCaseByBuffer(pair.original)
    }

    private func changeCaseSelection() -> Bool { gated { changeCaseSelectionImpl() } }
    private func changeCaseSelectionImpl() -> Bool {
        caseWord = nil   // выделение сбрасывает буферный цикл
        let pasteboard = NSPasteboard.general
        cancelClipboardRestore()
        if savedClipboardItems == nil { savedClipboardItems = snapshotPasteboard(pasteboard) }
        isConverting = true
        var ok = false
        defer { if !ok { restoreClipboardNow() }; isConverting = false }

        guard let text = readSelection(pasteboard), !text.isEmpty,
              text.contains(where: { $0.isLetter }) else { return false }
        let changed = TextConverter.nextCaseFromCurrent(text)
        guard changed != text else { return false }
        pasteText(changed, pasteboard: pasteboard)
        // Скептик #29: НЕ выставляем reconvert-состояние (lastConverted/lastConvertedCount) — смена
        // регистра не должна попадать в путь реконверта (см. clearState() в onCaseHotkey).
        ok = true
        scheduleClipboardRestore()
        return true
    }

    /// Для выделения (без состояния): следующий регистр из текущего — нижний→ВЕРХНИЙ→Заглавный→нижний.
    private static func nextCaseFromCurrent(_ s: String) -> String {
        let letters = s.filter { $0.isLetter }
        if letters.allSatisfy({ $0.isLowercase }) { return s.uppercased() }
        if letters.allSatisfy({ $0.isUppercase }) {
            let cap = capitalizedVariant(s)
            return cap == s ? s.lowercased() : cap   // односимвольные слова: с заглавной == s → идём в нижний
        }
        return s.lowercased()
    }

    /// issue #29: смена регистра ВСЕЙ строки (когда включён «Convert whole line»). Обычные
    /// приложения — тем же AX-гейтом выделения строки, что и convertLine (#26). Повторные тапы
    /// циклят регистр: changeCaseSelection перечитывает текущую строку → nextCaseFromCurrent.
    func changeCaseLine() -> Bool { gated { changeCaseLineImpl() } }
    private func changeCaseLineImpl() -> Bool {
        guard !isConverting else { return false }
        guard isFocusedElementEditable() else { rslog("changeCaseLine: non-editable — bail"); return false }
        simKey(keyCode: KC.left, flags: [.maskShift, .maskCommand]); usleep(60_000)
        if !focusedSelectionIsEmpty() {
            let ok = changeCaseSelection()
            if !ok { simKey(keyCode: KC.right, flags: []) }
            return ok
        }
        simKey(keyCode: KC.right, flags: [.maskShift, .maskCommand]); usleep(60_000)   // RTL: начало строки справа
        if !focusedSelectionIsEmpty() {
            let ok = changeCaseSelection()
            if !ok { simKey(keyCode: KC.left, flags: []) }
            return ok
        }
        return false
    }

    /// issue #29 (терминал): смена регистра всей строки по БУФЕРУ нажатий (нет OS-выделения).
    /// Циклит регистр как changeCaseWord, ключ — строка целиком (буфер живёт между тапами).
    func changeCaseLineBuffer(_ lineKeys: [TypedKey]) -> Bool {
        guard !isConverting, !lineKeys.isEmpty,
              let original = DynamicKeyMapping.lineString(from: lineKeys),
              !original.isEmpty, original.contains(where: { $0.isLetter }) else { return false }
        return cycleCaseByBuffer(original)
    }

    /// issue #16: конверсия в Spotlight. Обычный путь оставляет лишнюю букву, потому что
    /// Spotlight «съедает» первый Backspace серого автодополнения — счётчик нажатий (и даже
    /// стирание по РЕАЛЬНОЙ длине) расходится с полем. AX-элемент Spotlight к тому же флейкует.
    /// Надёжный путь БЕЗ Backspace и БЕЗ AX: выделить всё поле (Cmd+A), прочитать реальный
    /// текст через буфер (Cmd+C), сконвертировать и вставить поверх выделения (Cmd+A+Cmd+V) —
    /// selection-replace не задействует Backspace вовсе (проверено живым захватом 2026-08-01:
    /// «ghbdtn»→«привет» без лишних букв). Конвертит ВСЮ строку поиска (для однострочного поля
    /// Spotlight это ожидаемо). Реверсивно: повторный вызов конвертит назад. Буфер обмена
    /// сохраняется/восстанавливается. false → вызывающий падает на обычный путь.
    @MainActor
    func convertSpotlight() -> Bool { gated { convertSpotlightImpl() } }
    private func convertSpotlightImpl() -> Bool {
        guard !isConverting else { return false }
        isConverting = true
        lastWasBuffer = false
        lastUndoSwitchesLayout = true   // ревью I3: откат конверсии меняет раскладку
        let pasteboard = NSPasteboard.general
        cancelClipboardRestore()
        // issue #16 (skeptic): НЕ пере-снимаем буфер, если восстановление уже отложено —
        // иначе реконверт за <2с снял бы уже КОНВЕРТИРОВАННЫЙ текст и потерял оригинал
        // пользователя навсегда. savedClipboardItems непусто ровно пока висит отложенный
        // restore (нилится в его work-item), так что это надёжный признак «есть что вернуть».
        if savedClipboardItems == nil {
            savedClipboardItems = snapshotPasteboard(pasteboard)
        }
        var conversionSucceeded = false
        defer {
            if !conversionSucceeded { restoreClipboardNow() }
            isConverting = false
        }

        // 1. Выделить всё поле и прочитать реальный текст (Cmd+A → Cmd+C).
        simKey(keyCode: KC.letterA, flags: .maskCommand)
        usleep(30_000)
        guard let text = tryCopy(pasteboard), !text.isEmpty else {
            rslog("spotlight convert: read failed")
            simKey(keyCode: KC.right, flags: [])   // снять выделение
            return false
        }

        // 2. Конверсия (char-level, авто-направление).
        let converted = TextConverter.normalizedForInsert(DynamicKeyMapping.convert(text))
        guard converted != text else {
            rslog("spotlight convert: no-op — bail")
            simKey(keyCode: KC.right, flags: [])
            return false
        }

        // 3. Заменить выделение вставкой (Cmd+A → Cmd+V) — без Backspace.
        simKey(keyCode: KC.letterA, flags: .maskCommand)
        usleep(30_000)
        pasteText(converted, pasteboard: pasteboard)

        rslog("spotlight convert: \(text.count)→\(converted.count) chars (Cmd+A + clipboard)")
        lastConvertedCount = converted.count
        lastBoundaryCount = 0
        lastClipboardRTL = TextConverter.containsRTL(text) || TextConverter.containsRTL(converted)
        conversionSucceeded = true
        scheduleClipboardRestore()
        return true
    }

    /// issue #16 (авто): замена последнего слова в Spotlight без Backspace. Автоконверсия
    /// решает по буферу верно, ломается лишь СТИРАНИЕ по счётчику (Spotlight ест Backspace
    /// серого автодополнения). Здесь выделяем слово по ГРАНИЦЕ (Shift+Option+Left — не по
    /// счётчику, поэтому расхождение не бьёт) и печатаем `converted` поверх выделения. Курсор
    /// стоит после слова + `boundaryCount` пробелов; уходим за пробелы, выделяем слово,
    /// заменяем, возвращаем курсор. Clipboard не нужен (печать поверх выделения, без Cmd+V).
    @MainActor
    func convertSpotlightWord(converted: String, boundaryCount: Int) -> Bool {
        guard !isConverting, !converted.isEmpty else { return false }
        isConverting = true
        lastWasBuffer = false   // реконверт авто-слова в Spotlight не поддерживаем
        lastUndoSwitchesLayout = true   // ревью I3: откат конверсии меняет раскладку
        rslog("spotlight auto: word-select replace (bc=\(boundaryCount))")
        injectQueue.async { [weak self] in
            guard let self else { return }
            for _ in 0..<boundaryCount { self.simKey(keyCode: KC.left, flags: []) }   // за пробелы к концу слова
            usleep(15_000)
            self.simKey(keyCode: KC.left, flags: [.maskShift, .maskAlternate])        // выделить слово (по границе)
            usleep(15_000)
            self.insertText(converted)                                                // печать поверх выделения = замена
            usleep(15_000)
            for _ in 0..<boundaryCount { self.simKey(keyCode: KC.right, flags: []) }   // вернуть курсор за пробелы
            Task { @MainActor in self.isConverting = false }
        }
        return true
    }

    /// Повторная конвертация (второй триггер) — на тот движок, которым делали последнюю.
    func reconvert() -> Bool {
        guard !isConverting else { return false }
        if lastWasBuffer {
            guard !lastConverted.isEmpty else { return false }
            isConverting = true
            rslog("buffer reconvert")
            let bsCount = lastConverted.count
            let insert = lastOriginal
            let tmp = lastOriginal; lastOriginal = lastConverted; lastConverted = tmp
            injectQueue.async { [weak self] in
                guard let self else { return }
                self.backspace(bsCount)
                usleep(20_000)
                self.insertText(insert)
                Task { @MainActor in self.isConverting = false }
            }
            return true
        }
        return reconvertViaClipboard()
    }

    /// Конвертация через буфер обмена (фолбэк: выделенный мышью текст и т.п.).
    /// Сначала проверяет выделение, потом пробует слово по счётчику.
    /// wholeLine — выделение сделали мы сами (режим «вся строка»), а не пользователь.
    func convertViaClipboard(wordLength: Int, prevWordLength: Int, boundaryCount: Int, wholeLine: Bool = false) -> Bool {
        gated { convertViaClipboardImpl(wordLength: wordLength, prevWordLength: prevWordLength, boundaryCount: boundaryCount, wholeLine: wholeLine) }
    }
    private func convertViaClipboardImpl(wordLength: Int, prevWordLength: Int, boundaryCount: Int, wholeLine: Bool) -> Bool {
        guard !isConverting else {
            rslog("convert: skipped — already converting")
            return false
        }
        isConverting = true
        lastWasBuffer = false
        lastUndoSwitchesLayout = true   // ревью I3: откат конверсии меняет раскладку
        defer { isConverting = false }

        if !isFocusedElementEditable() {
            rslog("convert: element may not be editable, trying anyway")
        }
        let pasteboard = NSPasteboard.general
        cancelClipboardRestore()
        // Скептик 3.2.0: не перезаписываем сохранённый буфер при повторной конверсии в окне
        // восстановления — иначе «оригиналом» стал бы промежуточный конвертированный текст.
        if savedClipboardItems == nil { savedClipboardItems = snapshotPasteboard(pasteboard) }

        var conversionSucceeded = false
        defer {
            // Любой ранний выход без успеха обязан вернуть буфер пользователю —
            // иначе clipboard остаётся пустым или с конвертированным текстом.
            if !conversionSucceeded { restoreClipboardNow() }
        }

        // --- Попытка 1: уже есть выделенный текст? ---
        if let text = readSelection(pasteboard) {
            rslog("convert: selection len=\(text.count)")
            // issue #22: A «по тексту» (тотальный флип) → B «умная» по-словная (по умолч.) →
            // классика (одностороннее по раскладке, если умная выключена).
            let s = SettingsManager.shared
            var converted = TextConverter.normalizedForInsert(
                s.convertByText ? DynamicKeyMapping.convertBidirectional(text)
                : s.smartConversion ? SmartConvert.selection(text)
                : DynamicKeyMapping.convert(text))
            // #46: «умная» не трогает верное слово, но одно слово человек выделил сам — переводим.
            if converted == text, !wholeLine, s.smartConversion, !s.convertByText,
               !text.trimmingCharacters(in: .whitespacesAndNewlines).contains(where: { $0.isWhitespace }) {
                converted = TextConverter.normalizedForInsert(DynamicKeyMapping.convertBidirectional(text))
            }
            // Конверсия не изменила текст (пара не разрешилась / комбинирующие знаки —
            // см. bail'ы в DynamicKeyMapping) — не гоняем вставку впустую.
            if converted == text {
                rslog("convert: no-op conversion — bail")
                return false
            }
            pasteText(converted, pasteboard: pasteboard)
            // Курсор остаётся в конце вставленного текста — не пере-выделяем,
            // чтобы следующий ввод не затёр результат. Для reconvert используется
            // унифицированный путь через selectBack(lastConvertedCount).
            lastConvertedCount = converted.count
            lastBoundaryCount = 0
            // issue #22: сохраняем пару до/после — реконверт восстанавливает ТОЧНО,
            // а не пере-конвертирует (умный/тотальный флип односторонней convert не
            // инвертируется, особенно смешанный результат).
            lastOriginal = text
            lastConverted = converted
            // RTL: реконверт этого результата шёл бы стрелочной селекцией, а стрелки
            // двигают каретку ВИЗУАЛЬНО — в RTL выделился бы не тот диапазон и
            // конверсия заменила бы чужой текст (ревью-находка). Помечаем, чтобы
            // reconvertViaClipboard отказался.
            lastClipboardRTL = TextConverter.containsRTL(text) || TextConverter.containsRTL(converted)
            conversionSucceeded = true
            scheduleClipboardRestore()
            return true
        }

        // RTL-пара: счётчиковый путь выделяет Shift+Left'ами, а в RTL «влево» —
        // логически вперёд: выделили бы не то и заменили чужой текст. Точность
        // важнее полноты — отказ (буферный движок ивриту не нужен только при
        // выделении мышью, а это Попытка 1 выше).
        if let l = LayoutSwitcher.currentAndOppositeLanguage(),
           LayoutDetector.isHebrew(l.current) || LayoutDetector.isHebrew(l.opposite) {
            rslog("convert: hebrew pair — count-based clipboard path unsafe, bail")
            return false
        }

        // --- Попытка 2: выделяем слово по счётчику ---
        let charCount: Int
        let usedBoundary: Int

        if wordLength > 0 {
            charCount = wordLength
            usedBoundary = 0
        } else if prevWordLength > 0 && boundaryCount > 0 {
            moveLeft(boundaryCount)
            charCount = prevWordLength
            usedBoundary = boundaryCount
        } else {
            rslog("convert: nothing to convert (wordLen=\(wordLength) prevLen=\(prevWordLength))")
            return false
        }

        rslog("convert: selecting \(charCount) chars (boundary=\(usedBoundary))")
        selectBack(charCount)
        usleep(50_000)

        guard let text = tryCopy(pasteboard) else {
            rslog("convert: copy failed")
            simKey(keyCode: KC.right, flags: []) // снять выделение
            moveRight(usedBoundary)
            return false
        }

        rslog("convert: word len=\(text.count)")
        // Счётчиковый путь — одно последнее слово; направление по раскладке (как раньше),
        // либо тотальный флип при тумблере «по тексту» (A). Умный путь — только для выделения.
        let converted = TextConverter.normalizedForInsert(
            SettingsManager.shared.convertByText
                ? DynamicKeyMapping.convertBidirectional(text)
                : DynamicKeyMapping.convert(text))
        pasteText(converted, pasteboard: pasteboard)

        moveRight(usedBoundary)

        lastConvertedCount = converted.count
        lastBoundaryCount = usedBoundary
        lastOriginal = text          // issue #22: точное восстановление в reconvert
        lastConverted = converted
        // Симметрично Попытке 1: актуализируем флаг, чтобы прошлое RTL-выделение
        // не блокировало реконверт свежей LTR-конверсии (залипший флаг).
        lastClipboardRTL = TextConverter.containsRTL(text) || TextConverter.containsRTL(converted)
        conversionSucceeded = true
        scheduleClipboardRestore()
        return true
    }

    /// Повторная конвертация через буфер обмена (фолбэк).
    private func reconvertViaClipboard() -> Bool { gated { reconvertViaClipboardImpl() } }
    private func reconvertViaClipboardImpl() -> Bool {
        guard !isConverting else {
            rslog("reconvert: skipped — already converting")
            return false
        }
        isConverting = true
        defer { isConverting = false }

        rslog("reconvert: lastCount=\(lastConvertedCount) boundary=\(lastBoundaryCount)")
        guard lastConvertedCount > 0 else { return false }
        // RTL-результат: стрелочная селекция в RTL выделит не тот диапазон (см. convert).
        guard !lastClipboardRTL else {
            rslog("reconvert: RTL selection — arrow-based path unsafe, bail")
            return false
        }

        let pasteboard = NSPasteboard.general
        // Отменяем отложенное восстановление clipboard — мы ещё работаем
        cancelClipboardRestore()
        // Скептик 3.2.0: если восстановление уже отработало (snapshot пуст), снимаем свежий —
        // иначе финальный scheduleClipboardRestore очистил бы буфер пользователя.
        if savedClipboardItems == nil { savedClipboardItems = snapshotPasteboard(pasteboard) }

        moveLeft(lastBoundaryCount)

        selectBack(lastConvertedCount)
        usleep(80_000)  // дать приложению обработать выделение

        guard let text = tryCopy(pasteboard) else {
            rslog("reconvert: copy failed, count=\(lastConvertedCount)")
            simKey(keyCode: KC.right, flags: [])
            moveRight(lastBoundaryCount)
            scheduleClipboardRestore()
            return false
        }

        // issue #22: если выделенное совпадает с прошлым результатом — ВОССТАНАВЛИВАЕМ
        // исходник точно (умный/тотальный флип односторонней convert не инвертируется).
        // Иначе (текст изменился) — безопасный фолбэк на обычную одностороннюю конверсию.
        let converted: String
        if text == lastConverted, !lastOriginal.isEmpty {
            converted = lastOriginal
            let tmp = lastOriginal; lastOriginal = lastConverted; lastConverted = tmp   // toggle
            rslog("reconvert: restored original (len=\(converted.count))")
        } else {
            converted = TextConverter.normalizedForInsert(DynamicKeyMapping.convert(text))
            rslog("reconvert: len=\(text.count) → converting (fallback)")
        }
        pasteText(converted, pasteboard: pasteboard)

        moveRight(lastBoundaryCount)

        lastConvertedCount = converted.count
        scheduleClipboardRestore()
        return true
    }

    func clearState() {
        lastConvertedCount = 0
        lastBoundaryCount = 0
        lastOriginal = ""
        lastConverted = ""
        lastWasBuffer = false
        lastClipboardRTL = false
        lastUndoSwitchesLayout = true
    }

    // MARK: - Private

    /// Стирает n символов (Backspace × n) — для движка перепечатки.
    /// Пауза минимальная: порядок доставки гарантирует системная очередь HID, а при
    /// прежних 3мс/клавишу стирание длинного слова растягивалось на кадры отрисовки —
    /// пользователь видел «стёрли-и-перепечатали» вместо мгновенной замены.
    nonisolated private func backspace(_ n: Int) {
        for _ in 0..<n {
            simKey(keyCode: KC.backspace, flags: [])
            usleep(500)
        }
    }

    /// Впечатывает строку напрямую (юникод-вставка), без буфера обмена. По символу на нажатие,
    /// как обычный набор: терминалы берут из нажатия только первый символ, а браузеры теряют
    /// многосимвольное нажатие после серии Backspace (#47). Расшифровка автозамены бывает до
    /// 500 знаков — она идёт кусками по 20 UTF-16, больше один CGEvent не несёт.
    nonisolated private func insertText(_ text: String) {
        guard let source = makeSource() else { return }
        let chunks = insertChunks(text, limit: text.utf16.count > 200 ? 20 : 1)
        for (i, chunk) in chunks.enumerated() {
            let utf16 = Array(chunk.utf16)
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else { return }
            utf16.withUnsafeBufferPointer { buf in
                down.keyboardSetUnicodeString(stringLength: buf.count, unicodeString: buf.baseAddress)
                up.keyboardSetUnicodeString(stringLength: buf.count, unicodeString: buf.baseAddress)
            }
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
            if i < chunks.count - 1 { usleep(1_000) }
        }
    }

    /// Вставляет текст через Cmd+V и ждёт завершения
    private func pasteText(_ text: String, pasteboard: NSPasteboard) {
        clipboardDirty = true
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        for type in Self.transientTypes { pasteboard.setData(Data(), forType: type) }
        simKey(keyCode: KC.letterV, flags: .maskCommand) // Cmd+V
        usleep(150_000) // 150мс — дать приложению вставить текст и обновить курсор
    }

    /// Отменяет отложенное восстановление clipboard
    private func cancelClipboardRestore() {
        clipboardRestoreWork?.cancel()
        clipboardRestoreWork = nil
    }

    /// Пометки nspasteboard.org: менеджеры буфера обмена не заносят такую запись в историю (#44).
    private static let transientTypes = [
        NSPasteboard.PasteboardType("org.nspasteboard.TransientType"),
        NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType"),
    ]

    /// Возвращает пользователю сохранённое содержимое буфера. Пометка нужна и здесь: это его же
    /// запись, в истории менеджера она уже есть.
    private func writeBackClipboard(_ saved: [NSPasteboardItem]) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if let first = saved.first {
            for type in Self.transientTypes { first.setData(Data(), forType: type) }
            pasteboard.writeObjects(saved)
        }
    }

    /// Немедленно возвращает буфер обмена пользователю (для путей-неудач).
    private func restoreClipboardNow() {
        cancelClipboardRestore()
        guard let saved = savedClipboardItems else { return }
        if clipboardDirty { writeBackClipboard(saved) }
        clipboardDirty = false
        savedClipboardItems = nil
    }

    /// Сбрасывает отложенное восстановление немедленно — вызывается перед
    /// завершением приложения, чтобы не потерять буфер в окне ожидания.
    func flushPendingClipboardRestore() {
        guard clipboardRestoreWork != nil else { return }
        restoreClipboardNow()
    }

    /// Планирует восстановление clipboard (если за это время придёт reconvert — отменится и
    /// перепланируется). Запас нужен потому, что приложение обрабатывает Cmd+V асинхронно:
    /// вернуть буфер раньше — и оно вставит старое содержимое. Клиенту удалёнки буфер
    /// доезжает по сети, ему запас больше.
    private func scheduleClipboardRestore() {
        cancelClipboardRestore()
        let saved = self.savedClipboardItems
        let work = DispatchWorkItem { [weak self] in
            self?.writeBackClipboard(saved ?? [])
            self?.clipboardDirty = false
            self?.savedClipboardItems = nil
            rslog("clipboard restored (\(saved?.count ?? 0) items)")
        }
        clipboardRestoreWork = work
        let frontID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let delay: TimeInterval = AutoSwitchPolicy.isRemoteDesktopClient(frontID) ? 2.0 : 0.7
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Делает глубокую копию всех pasteboard items (со всеми типами данных).
    /// Это нужно потому, что NSPasteboardItem становится невалидным после
    /// pasteboard.clearContents() — поэтому копируем data по каждому типу
    /// в новые NSPasteboardItem.
    /// Картинку macOS кладёт в буфер и PNG, и несжатым TIFF (скриншот 5K — 59 МБ): копия
    /// TIFF стоила +56 МБ памяти на одно нажатие. PNG без потерь, для возврата его хватает,
    /// поэтому TIFF при наличии PNG не копируем.
    private func snapshotPasteboard(_ pb: NSPasteboard) -> [NSPasteboardItem] {
        guard let items = pb.pasteboardItems else { return [] }
        return items.map { oldItem in
            let newItem = NSPasteboardItem()
            let hasPNG = oldItem.types.contains(.png)
            for type in oldItem.types where !(hasPNG && type == .tiff) {
                if let data = oldItem.data(forType: type) {
                    newItem.setData(data, forType: type)
                }
            }
            return newItem
        }
    }

    /// Текущее выделение: однострочное берём через AX, тогда промежуточного Cmd+C нет и
    /// менеджер буфера его не увидит (#44). AX не отдал или текст многострочный — Cmd+C
    /// (абзацы приложения отдают через AX по-разному).
    private func readSelection(_ pasteboard: NSPasteboard) -> String? {
        if let text = selectedTextAX(), !text.isEmpty, !text.contains(where: { $0.isNewline }) {
            return text
        }
        return tryCopy(pasteboard)
    }

    /// Копирует выделенный текст. Делает до 3 попыток (Cmd+C не всегда срабатывает с первого раза)
    private func tryCopy(_ pasteboard: NSPasteboard) -> String? {
        clipboardDirty = true
        for attempt in 0..<3 {
            // Очищаем буфер перед копированием — гарантирует что changeCount изменится
            pasteboard.clearContents()
            let oldCount = pasteboard.changeCount

            simKey(keyCode: KC.letterC, flags: .maskCommand) // Cmd+C
            usleep(attempt == 0 ? 80_000 : 120_000)

            if pasteboard.changeCount != oldCount,
               let text = pasteboard.string(forType: .string),
               !text.isEmpty {
                return text
            }
            usleep(50_000) // пауза перед retry
        }
        return nil
    }

    /// Выделяет N символов влево (Shift+Left × N)
    nonisolated private func selectBack(_ count: Int) {
        for _ in 0..<count {
            simKey(keyCode: KC.left, flags: .maskShift)
            usleep(1_000)
        }
    }

    /// Сдвигает курсор влево на N символов
    nonisolated private func moveLeft(_ count: Int) {
        for _ in 0..<count {
            simKey(keyCode: KC.left, flags: [])
            usleep(1_000)
        }
    }

    /// Сдвигает курсор вправо на N символов (восстановление границ-пробелов)
    nonisolated private func moveRight(_ count: Int) {
        for _ in 0..<count {
            simKey(keyCode: KC.right, flags: [])
            usleep(1_000)
        }
    }

    /// Симулирует нажатие клавиши с маркером (чтобы наш monitor игнорировал)
    nonisolated private func simKey(keyCode: UInt16, flags: CGEventFlags) {
        guard let source = makeSource() else { return }

        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        else { return }

        keyDown.flags = flags
        keyUp.flags = flags

        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }
}
