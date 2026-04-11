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
    private var isConverting = false

    /// Создаёт CGEventSource с маркером, чтобы KeyboardMonitor игнорировал наши события
    private func makeSource() -> CGEventSource? {
        let source = CGEventSource(stateID: .hidSystemState)
        source?.userData = kRuSwitcherEventMarker
        return source
    }

    /// Проверяет, что текущий фокусированный элемент — редактируемое текстовое поле
    private func isFocusedElementEditable() -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication else { return false }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)

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

    /// Конвертирует текст. Возвращает true при успехе.
    /// Сначала проверяет выделение, потом пробует слово по счётчику.
    func convert(wordLength: Int, prevWordLength: Int, boundaryCount: Int) -> Bool {
        guard !isConverting else {
            rslog("convert: skipped — already converting")
            return false
        }
        isConverting = true
        defer { isConverting = false }

        if !isFocusedElementEditable() {
            rslog("convert: element may not be editable, trying anyway")
        }
        let pasteboard = NSPasteboard.general
        cancelClipboardRestore()
        savedClipboardItems = snapshotPasteboard(pasteboard)

        // --- Попытка 1: уже есть выделенный текст? ---
        if let text = tryCopy(pasteboard) {
            rslog("convert: selection text='\(text)'")
            let converted = DynamicKeyMapping.convert(text)
            pasteText(converted, pasteboard: pasteboard)
            // Курсор остаётся в конце вставленного текста — не пере-выделяем,
            // чтобы следующий ввод не затёр результат. Для reconvert используется
            // унифицированный путь через selectBack(lastConvertedCount).
            lastConvertedCount = converted.count
            lastBoundaryCount = 0
            scheduleClipboardRestore()
            return true
        }

        // --- Попытка 2: выделяем слово по счётчику ---
        let charCount: Int
        let usedBoundary: Int

        if wordLength > 0 {
            charCount = wordLength
            usedBoundary = 0
        } else if prevWordLength > 0 && boundaryCount > 0 {
            for _ in 0..<boundaryCount {
                simKey(keyCode: 123, flags: []) // Left
                usleep(3_000)
            }
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
            simKey(keyCode: 124, flags: []) // Right — снять выделение
            for _ in 0..<usedBoundary {
                simKey(keyCode: 124, flags: [])
                usleep(3_000)
            }
            return false
        }

        rslog("convert: word='\(text)'")
        let converted = DynamicKeyMapping.convert(text)
        pasteText(converted, pasteboard: pasteboard)

        for _ in 0..<usedBoundary {
            simKey(keyCode: 124, flags: [])
            usleep(3_000)
        }

        lastConvertedCount = converted.count
        lastBoundaryCount = usedBoundary
        scheduleClipboardRestore()
        return true
    }

    /// Повторная конвертация (второй Alt)
    func reconvert() -> Bool {
        guard !isConverting else {
            rslog("reconvert: skipped — already converting")
            return false
        }
        isConverting = true
        defer { isConverting = false }

        rslog("reconvert: lastCount=\(lastConvertedCount) boundary=\(lastBoundaryCount)")
        guard lastConvertedCount > 0 else { return false }

        let pasteboard = NSPasteboard.general
        // Отменяем отложенное восстановление clipboard — мы ещё работаем
        cancelClipboardRestore()

        for _ in 0..<lastBoundaryCount {
            simKey(keyCode: 123, flags: [])
            usleep(3_000)
        }

        selectBack(lastConvertedCount)
        usleep(80_000)  // дать приложению обработать выделение

        guard let text = tryCopy(pasteboard) else {
            rslog("reconvert: copy failed, count=\(lastConvertedCount)")
            simKey(keyCode: 124, flags: [])
            for _ in 0..<lastBoundaryCount {
                simKey(keyCode: 124, flags: [])
                usleep(3_000)
            }
            scheduleClipboardRestore()
            return false
        }

        rslog("reconvert: '\(text)' → converting")
        let converted = DynamicKeyMapping.convert(text)
        pasteText(converted, pasteboard: pasteboard)

        for _ in 0..<lastBoundaryCount {
            simKey(keyCode: 124, flags: [])
            usleep(3_000)
        }

        lastConvertedCount = converted.count
        scheduleClipboardRestore()
        return true
    }

    func clearState() {
        lastConvertedCount = 0
        lastBoundaryCount = 0
    }

    // MARK: - Private

    /// Вставляет текст через Cmd+V и ждёт завершения
    private func pasteText(_ text: String, pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        simKey(keyCode: 9, flags: .maskCommand) // Cmd+V
        usleep(150_000) // 150мс — дать приложению вставить текст и обновить курсор
    }

    /// Отменяет отложенное восстановление clipboard
    private func cancelClipboardRestore() {
        clipboardRestoreWork?.cancel()
        clipboardRestoreWork = nil
    }

    /// Планирует восстановление clipboard через 2 секунды
    /// (если за это время придёт reconvert — отменится и перепланируется)
    private func scheduleClipboardRestore() {
        cancelClipboardRestore()
        let saved = self.savedClipboardItems
        let work = DispatchWorkItem { [weak self] in
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            if let saved, !saved.isEmpty {
                pasteboard.writeObjects(saved)
            }
            self?.savedClipboardItems = nil
            rslog("clipboard restored (\(saved?.count ?? 0) items)")
        }
        clipboardRestoreWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: work)
    }

    /// Делает глубокую копию всех pasteboard items (со всеми типами данных).
    /// Это нужно потому, что NSPasteboardItem становится невалидным после
    /// pasteboard.clearContents() — поэтому копируем data по каждому типу
    /// в новые NSPasteboardItem.
    private func snapshotPasteboard(_ pb: NSPasteboard) -> [NSPasteboardItem] {
        guard let items = pb.pasteboardItems else { return [] }
        return items.map { oldItem in
            let newItem = NSPasteboardItem()
            for type in oldItem.types {
                if let data = oldItem.data(forType: type) {
                    newItem.setData(data, forType: type)
                }
            }
            return newItem
        }
    }

    /// Копирует выделенный текст. Делает до 3 попыток (Cmd+C не всегда срабатывает с первого раза)
    private func tryCopy(_ pasteboard: NSPasteboard) -> String? {
        for attempt in 0..<3 {
            // Очищаем буфер перед копированием — гарантирует что changeCount изменится
            pasteboard.clearContents()
            let oldCount = pasteboard.changeCount

            simKey(keyCode: 8, flags: .maskCommand) // Cmd+C
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
    private func selectBack(_ count: Int) {
        guard let source = makeSource() else { return }
        for _ in 0..<count {
            guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 123, keyDown: true),
                  let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 123, keyDown: false)
            else { continue }
            keyDown.flags = .maskShift
            keyUp.flags = .maskShift
            keyDown.post(tap: .cghidEventTap)
            keyUp.post(tap: .cghidEventTap)
            usleep(3_000)
        }
    }

    /// Симулирует нажатие клавиши с маркером (чтобы наш monitor игнорировал)
    private func simKey(keyCode: UInt16, flags: CGEventFlags) {
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
