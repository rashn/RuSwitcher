import AppKit

/// issue #27: показывает разовое объяснение «RuSwitcher на паузе из-за защищённого ввода»
/// НЕ крадя фокус. Раньше это был `NSAlert.runModal()` — модалка активировала приложение и
/// уводила фокус из поля пароля (пользователь терял позицию в терминале и вводил пароль заново).
/// Теперь это неактивирующая плашка (как `CaretIndicator`): `.nonactivatingPanel` +
/// `orderFrontRegardless`, без `NSApp.activate` и без `makeKey…` — фокус остаётся в поле ввода.
/// Сама гаснет через несколько секунд; click-through, ничего не перехватывает.
@MainActor
final class SecureInputNotice {
    private let panel: NSPanel
    private let title: NSTextField
    private let body: NSTextField
    private var hideTimer: Timer?
    private let width: CGFloat = 380

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: 96),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.worksWhenModal = false
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)) + 1)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true                    // click-through — никогда не перехватываем
        panel.alphaValue = 0
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.isExcludedFromWindowsMenu = true

        let backdrop = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: width, height: 96))
        backdrop.material = .hudWindow
        backdrop.state = .active
        backdrop.blendingMode = .behindWindow
        backdrop.wantsLayer = true
        backdrop.layer?.cornerRadius = 12
        backdrop.layer?.masksToBounds = true
        panel.contentView = backdrop

        title = NSTextField(labelWithString: "")
        title.font = .boldSystemFont(ofSize: 13)
        title.textColor = .labelColor
        title.translatesAutoresizingMaskIntoConstraints = false

        body = NSTextField(wrappingLabelWithString: "")
        body.font = .systemFont(ofSize: 12)
        body.textColor = .secondaryLabelColor
        body.translatesAutoresizingMaskIntoConstraints = false
        body.preferredMaxLayoutWidth = width - 32

        let stack = NSStackView(views: [title, body])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        backdrop.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: backdrop.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: backdrop.bottomAnchor, constant: -14),
        ])
    }

    /// Показать плашку (не крадёт фокус). Длительность зависит от объёма текста.
    func show(title titleText: String, body bodyText: String) {
        title.stringValue = titleText
        body.stringValue = bodyText

        // Подгоняем высоту панели под содержимое, затем позиционируем сверху-по-центру экрана.
        panel.setContentSize(NSSize(width: width, height: 200))     // временно, чтобы layout развернулся
        panel.layoutIfNeeded()
        let fitH = panel.contentView?.fittingSize.height ?? 96
        let h = max(72, min(fitH, 220))
        panel.setContentSize(NSSize(width: width, height: h))
        positionTopCenter(height: h)

        panel.orderFrontRegardless()                                // показ БЕЗ активации приложения
        NSAnimationContext.runAnimationGroup { $0.duration = 0.14; panel.animator().alphaValue = 1 }

        let duration = min(9.0, 4.0 + Double(bodyText.count) / 45.0)  // дольше читать — дольше висит
        hideTimer?.invalidate()
        // .common — иначе таймер не сработает, пока main-runloop в eventTracking (открыто меню)
        // или modalPanel, и плашка зависла бы дольше срока (скептик #27).
        let t = Timer(timeInterval: duration, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.hide() }
        }
        RunLoop.main.add(t, forMode: .common)
        hideTimer = t
    }

    private func hide() {
        hideTimer?.invalidate(); hideTimer = nil
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.2; panel.animator().alphaValue = 0 },
                                             completionHandler: { [weak self] in self?.panel.orderOut(nil) })
    }

    private func positionTopCenter(height h: CGFloat) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) })
            ?? NSScreen.main ?? NSScreen.screens.first
        guard let vf = screen?.visibleFrame else { return }
        let x = vf.midX - width / 2
        let y = vf.maxY - h - 12                                     // прижато к верху под меню-баром
        panel.setFrameOrigin(NSPoint(x: x.rounded(), y: y.rounded()))
    }
}
