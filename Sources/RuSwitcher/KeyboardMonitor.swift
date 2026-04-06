import CoreGraphics
import Foundation

/// Маркер для симулированных событий — KeyboardMonitor их игнорирует
let kRuSwitcherEventMarker: Int64 = 0x52555300

func rslog(_ msg: String) {
    // Thread-safe: читаем UserDefaults напрямую (без MainActor)
    guard UserDefaults.standard.bool(forKey: "com.ruswitcher.debugLog") else { return }

    let line = "\(Date()): \(msg)\n"
    let logDir = NSHomeDirectory() + "/Library/Logs/RuSwitcher"
    let path = logDir + "/ruswitcher.log"

    // Создаём директорию если нет
    if !FileManager.default.fileExists(atPath: logDir) {
        try? FileManager.default.createDirectory(atPath: logDir, withIntermediateDirectories: true)
    }

    if let handle = FileHandle(forWritingAtPath: path) {
        handle.seekToEndOfFile()
        // Ротация: если > 5MB — обрезаем
        if handle.offsetInFile > 5_000_000 {
            handle.truncateFile(atOffset: 0)
            handle.write("--- Log rotated ---\n".data(using: .utf8)!)
        }
        handle.write(line.data(using: .utf8)!)
        handle.closeFile()
    } else {
        FileManager.default.createFile(atPath: path, contents: line.data(using: .utf8))
    }
}

final class KeyboardMonitor: @unchecked Sendable {
    fileprivate var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    /// Длина текущего набираемого слова
    private(set) var currentWordLength = 0
    /// Длина слова до последнего пробела
    private(set) var wordBeforeBoundaryLength = 0
    /// Сколько пробелов после слова (только пробелы, не enter/стрелки)
    private(set) var boundaryCount = 0
    /// Были ли реальные нажатия после последней конвертации?
    private(set) var keysTypedSinceConversion = true

    private var onAltTap: (() -> Void)?
    private var onAltReconvert: (() -> Void)?

    // Детект одиночного тапа Alt
    private var altPressedAlone = false
    private var altPressTime: Date?

    func start(
        onAltTap: @escaping () -> Void,
        onAltReconvert: @escaping () -> Void
    ) -> Bool {
        self.onAltTap = onAltTap
        self.onAltReconvert = onAltReconvert

        let precheck = CGPreflightListenEventAccess()
        rslog("Preflight check = \(precheck)")
        if !precheck {
            rslog("Requesting access...")
            CGRequestListenEventAccess()
        }

        rslog("Attempting to create event tap...")
        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .tailAppendEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: keyboardCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            rslog("FAILED to create event tap - no permission")
            return false
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        rslog("Event tap created and enabled successfully")
        return true
    }

    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
    }

    func markConverted() {
        currentWordLength = 0
        wordBeforeBoundaryLength = 0
        boundaryCount = 0
        keysTypedSinceConversion = false
    }

    private func fullReset() {
        currentWordLength = 0
        wordBeforeBoundaryLength = 0
        boundaryCount = 0
    }

    // MARK: - Event Handling

    fileprivate func handleKeyDown(keyCode: UInt16, flags: CGEventFlags) {
        // Alt не сбрасывает altPressedAlone (это делается только для НЕ-модификаторных клавиш)
        altPressedAlone = false
        keysTypedSinceConversion = true

        // Cmd/Ctrl/Alt модификаторы — не считаем
        let modifiers = flags.intersection([.maskCommand, .maskControl, .maskAlternate])
        if !modifiers.isEmpty { return }

        // Пробел (49) — единственная граница через которую можно вернуться
        if keyCode == 49 {
            if currentWordLength > 0 {
                wordBeforeBoundaryLength = currentWordLength
                boundaryCount = 1
            } else {
                boundaryCount += 1
            }
            currentWordLength = 0
            return
        }

        // Enter (36), Tab (48) — полный сброс, через строку не ходим
        if keyCode == 36 || keyCode == 48 {
            fullReset()
            return
        }

        // Стрелки (123=Left, 124=Right, 125=Down, 126=Up) — полный сброс
        if keyCode >= 123 && keyCode <= 126 {
            fullReset()
            return
        }

        // Backspace (51)
        if keyCode == 51 {
            if currentWordLength > 0 {
                currentWordLength -= 1
            } else {
                // Удаляем за пределами текущего слова — неизвестное состояние
                fullReset()
            }
            return
        }

        // Клавиша из нашей таблицы маппинга — это "буква"
        if KeyMapping.keycodeToEN[keyCode] != nil {
            currentWordLength += 1
            // Начали новое слово — предыдущее теряем
            wordBeforeBoundaryLength = 0
            boundaryCount = 0
        } else {
            // Esc, F-клавиши, и т.д. — полный сброс
            fullReset()
        }
    }

    fileprivate func handleFlagsChanged(flags: CGEventFlags) {
        let altDown = flags.contains(.maskAlternate)

        if altDown {
            altPressedAlone = true
            altPressTime = Date()
        } else if altPressedAlone, let pressTime = altPressTime {
            let elapsed = Date().timeIntervalSince(pressTime)
            rslog("alt: elapsed=\(String(format: "%.3f", elapsed)) wordLen=\(currentWordLength) prevLen=\(wordBeforeBoundaryLength) boundary=\(boundaryCount) keysSince=\(keysTypedSinceConversion)")

            if elapsed < 0.4 {
                if !keysTypedSinceConversion {
                    // Повторный Alt после конвертации — reconvert
                    rslog("alt: RECONVERT")
                    DispatchQueue.main.async { [weak self] in
                        self?.onAltReconvert?()
                    }
                } else {
                    // Всегда вызываем convert — он сам проверит выделение и счётчики
                    rslog("alt: CONVERT")
                    DispatchQueue.main.async { [weak self] in
                        self?.onAltTap?()
                    }
                }
            }

            altPressedAlone = false
            altPressTime = nil
        }
    }
}

// MARK: - C Callback

private func keyboardCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let userInfo {
            let monitor = Unmanaged<KeyboardMonitor>.fromOpaque(userInfo).takeUnretainedValue()
            if let tap = monitor.eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
        }
        return Unmanaged.passRetained(event)
    }

    // Игнорируем собственные симулированные события по маркеру
    if event.getIntegerValueField(.eventSourceUserData) == kRuSwitcherEventMarker {
        return Unmanaged.passRetained(event)
    }

    guard let userInfo else {
        return Unmanaged.passRetained(event)
    }

    let monitor = Unmanaged<KeyboardMonitor>.fromOpaque(userInfo).takeUnretainedValue()

    if type == .keyDown {
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        monitor.handleKeyDown(keyCode: keyCode, flags: event.flags)
    } else if type == .flagsChanged {
        monitor.handleFlagsChanged(flags: event.flags)
    }

    return Unmanaged.passRetained(event)
}
