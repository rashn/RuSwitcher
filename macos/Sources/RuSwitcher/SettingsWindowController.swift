import AppKit
import Carbon

/// Окно настроек с вкладками
@MainActor
final class SettingsWindowController {
    private var window: NSWindow?
    private var autoSwitchCheckbox: NSButton?
    private var launchAtLoginCheckbox: NSButton?
    private var checkUpdatesCheckbox: NSButton?
    private var debugLogCheckbox: NSButton?
    private var caretFlagCheckbox: NSButton?
    private var autoConvertCheckbox: NSButton?      // #4: синк тумблера меню → окно настроек
    private var remoteDesktopCheckbox: NSButton?    // #5: то же (опционален — за фичефлагом)
    private var layout1Popup: NSPopUpButton?
    private var layout2Popup: NSPopUpButton?
    private var languagePopup: NSPopUpButton?
    private var hotkeyPopups: [HotkeySlot: NSPopUpButton] = [:]
    private var hotkeySidePopups: [HotkeySlot: NSPopUpButton] = [:]
    private var hotkeyDoubleChecks: [HotkeySlot: NSButton] = [:]
    private var hotkeyTitleLabels: [HotkeySlot: NSTextField] = [:]
    private var fnHintLabel: NSTextField?
    private var exceptionEditors: [ExceptionListEditor] = []
    private var abbreviationEditor: AbbreviationEditor?
    private var freqPacksCheckbox: NSButton?
    private var flagSizePopup: NSPopUpButton?
    private var freqPacksStatus: NSTextField?

    /// Callback для обновления меню
    var onAutoSwitchChanged: ((Bool) -> Void)?
    var onPerAppLayoutChanged: ((Bool) -> Void)?
    var onLanguageChanged: (() -> Void)?
    var onTriggerChanged: (() -> Void)?
    var onAutoConvertChanged: ((Bool) -> Void)?
    var onRemoteDesktopChanged: ((Bool) -> Void)?
    var onCaretFlagChanged: ((Bool) -> Void)?
    var onHideIconChanged: ((Bool) -> Void)?
    var onFlagSizeChanged: (() -> Void)?

    func showWindow() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 752),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        win.title = L10n.settingsTitle
        win.center()
        win.isReleasedWhenClosed = false

        let tabView = NSTabView(frame: win.contentView!.bounds)
        tabView.autoresizingMask = [.width, .height]

        tabView.addTabViewItem(createGeneralTab())
        tabView.addTabViewItem(createHotkeysTab())      // 3.5: все хоткеи на одной вкладке
        tabView.addTabViewItem(createAdvancedTab())     // «Расширенные» — сразу после «Основных»
        tabView.addTabViewItem(createExceptionsTab())
        tabView.addTabViewItem(createAboutTab())

        win.contentView = tabView
        // Вкладок пять, и на многих языках названия в 480 pt не влезали (#45).
        tabView.allowsTruncatedLabels = false
        let width = max(480, ceil(tabView.minimumSize.width) + 8)
        // Высота окна — по самой высокой вкладке (после fitToText вкладки разной высоты на разных
        // языках). Не выше экрана: на маленьком экране низ самой длинной вкладки уйдёт под край.
        let chrome = tabView.bounds.height - tabView.contentRect.height
        let tallest = tabView.tabViewItems.compactMap { $0.view?.subviews.first?.frame.height }.max() ?? 700
        var height = tallest + chrome
        if let screen = NSScreen.main { height = min(height, screen.visibleFrame.height - 60) }
        win.setContentSize(NSSize(width: width, height: height))
        win.center()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        window = win
    }

    /// Обновить состояние чекбокса автопереключения извне
    func updateAutoSwitchState(_ enabled: Bool) {
        autoSwitchCheckbox?.state = enabled ? .on : .off
    }

    /// Обновить чекбокс «флаг у курсора» извне (когда переключили из меню)
    func updateCaretFlagState(_ enabled: Bool) {
        caretFlagCheckbox?.state = enabled ? .on : .off
    }

    /// #4/#5: синхронизировать чекбоксы с переключением из меню-бара.
    func updateAutoConvertState(_ enabled: Bool) {
        autoConvertCheckbox?.state = enabled ? .on : .off
    }
    func updateRemoteDesktopState(_ enabled: Bool) {
        remoteDesktopCheckbox?.state = enabled ? .on : .off
    }

    // MARK: - General Tab

    /// Прижимает контент вкладки к ВЕРХУ. NSTabView растягивает вид вкладки на всю высоту окна,
    /// а под-вью с абсолютными координатами (y от низа) иначе провисают к низу/центру короткой
    /// вкладки. Оборачиваем фиксированный контент в растягивающийся контейнер и пиним контент к
    /// верхнему краю (гибкий нижний отступ — .minYMargin).
    /// 3.5.0b: вкладка выше maxHeight (у «Автоконверсии» с автозаменой ~1100 pt) — в прокрутку.
    /// Иначе окно растёт по самой высокой вкладке, упирается в экран ноутбука, и низ вкладки
    /// недостижим. Документ перевёрнутый — прокрутка открывается сверху.
    private func scrollableTopAligned(_ content: NSView, maxHeight: CGFloat) -> NSView {
        guard content.frame.height > maxHeight else { return topAligned(content) }
        let doc = FlippedView(frame: NSRect(origin: .zero, size: content.frame.size))
        content.frame.origin = .zero
        doc.addSubview(content)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: content.frame.width, height: maxHeight))
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.documentView = doc
        let outer = TabContentContainer(frame: scroll.frame)
        outer.fillsHeight = true
        outer.addSubview(scroll)
        return outer
    }

    private func topAligned(_ content: NSView) -> NSView {
        let outer = TabContentContainer(frame: content.frame)
        outer.addSubview(content)
        return outer
    }

    // MARK: - Подгонка вёрстки под длину текста

    /// Вкладки свёрстаны абсолютными фреймами, и длинные переводы обрезались: на 16 языках
    /// нашлось 113 мест (проверка: site/tools/make_shots.sh --audit). После сборки вкладки
    /// этот проход подгоняет её под фактический текст:
    ///  • строки «подпись + список» — общая колонка подписей по самой длинной; если список
    ///    при этом не влезает, подпись переносится на несколько строк;
    ///  • многострочные пояснения и длинные чекбоксы получают нужную высоту (чекбоксы переносятся);
    ///  • кнопки расширяются под текст, а ряд кнопок, который не влезает, встаёт в столбик;
    ///  • всё, что ниже выросшего элемента, сдвигается вниз, высота вкладки — по содержимому.
    private func fitToText(_ view: NSView) {
        let left: CGFloat = 20, right: CGFloat = 440, gap: CGFloat = 8
        let items = view.subviews.filter { !$0.isHidden }
        guard !items.isEmpty else { return }
        let topMargin = view.frame.height - (items.map { $0.frame.maxY }.max() ?? view.frame.height)

        // Строки — элементы, чьи рамки заметно пересекаются по вертикали (подпись и список рядом).
        func sameRow(_ a: NSRect, _ b: NSRect) -> Bool {
            min(a.maxY, b.maxY) - max(a.minY, b.minY) > 0.3 * min(a.height, b.height)
        }
        var rows: [[NSView]] = []
        for v in items.sorted(by: { $0.frame.maxY > $1.frame.maxY }) {
            if let i = rows.firstIndex(where: { $0.contains { sameRow($0.frame, v.frame) } }) {
                rows[i].append(v)
            } else {
                rows.append([v])
            }
        }
        rows.sort { ($0.map { $0.frame.maxY }.max() ?? 0) > ($1.map { $0.frame.maxY }.max() ?? 0) }

        var grow: [ObjectIdentifier: CGFloat] = [:]       // на сколько выросла высота (верх на месте)
        func setHeight(_ v: NSView, _ h: CGFloat) {
            let top = v.frame.maxY
            grow[ObjectIdentifier(v), default: 0] += h - v.frame.height
            v.frame = NSRect(x: v.frame.minX, y: top - h, width: v.frame.width, height: h)
        }
        func fitHeight(_ c: NSControl, width: CGFloat) -> CGFloat {
            ceil(c.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: 10_000)).height ?? c.frame.height)
        }
        func makeWrapping(_ c: NSControl) {
            c.cell?.wraps = true
            c.cell?.lineBreakMode = .byWordWrapping
            (c as? NSTextField)?.maximumNumberOfLines = 0
        }

        // 1. «Подпись + список»: одна колонка подписей на всю вкладку.
        var pairs: [(label: NSTextField, popup: NSPopUpButton)] = []
        for row in rows {
            let labels = row.compactMap { $0 as? NSTextField }.filter { !$0.isEditable && $0.cell?.wraps != true }
            let popups = row.compactMap { $0 as? NSPopUpButton }
            if labels.count == 1, popups.count == 1, labels[0].frame.minX < popups[0].frame.minX {
                pairs.append((labels[0], popups[0]))
            }
        }
        if !pairs.isEmpty {
            let popupNeed = min(pairs.map { ceil($0.popup.cell?.cellSize.width ?? 0) }.max() ?? 0, right - left - gap - 90)
            let labelNeed = pairs.map { ceil($0.label.cell?.cellSize.width ?? 0) + 2 }.max() ?? 0
            // Колонка не уже самого длинного слова: иначе слово рвётся по буквам («Դասավորությա / ն»).
            let longestWord = pairs.flatMap { p in
                p.label.stringValue.split(whereSeparator: \.isWhitespace).map { word in
                    ceil(NSAttributedString(string: String(word), attributes: [.font: p.label.font ?? NSFont.systemFont(ofSize: 13)]).size().width) + 4
                }
            }.max() ?? 0
            let column = min(labelNeed, max(90, right - left - gap - popupNeed))
            if column >= longestWord {
                for (label, popup) in pairs {
                    label.frame = NSRect(x: left, y: label.frame.minY, width: column, height: label.frame.height)
                    if ceil(label.cell?.cellSize.width ?? 0) + 2 > column {
                        makeWrapping(label)
                        setHeight(label, fitHeight(label, width: column))
                    }
                    let x = left + column + gap
                    popup.frame = NSRect(x: x, y: popup.frame.minY, width: right - x, height: popup.frame.height)
                }
            } else {
                // Подписи над списками, во всю ширину — одинаково для всей вкладки.
                for (label, popup) in pairs {
                    let top = max(label.frame.maxY, popup.frame.maxY)
                    let rowHeight = top - min(label.frame.minY, popup.frame.minY)
                    makeWrapping(label)
                    let lh = fitHeight(label, width: right - left)
                    label.frame = NSRect(x: left, y: top - lh, width: right - left, height: lh)
                    popup.frame = NSRect(x: left, y: label.frame.minY - 4 - popup.frame.height,
                                         width: right - left, height: popup.frame.height)
                    grow[ObjectIdentifier(popup), default: 0] += (lh + 4 + popup.frame.height) - rowHeight
                }
            }
        }

        // 2. Многострочные пояснения и чекбоксы (кнопки без рамки) — высота по тексту.
        for v in items {
            if let tf = v as? NSTextField, !tf.isEditable, tf.cell?.wraps == true {
                let h = fitHeight(tf, width: tf.frame.width)
                if h > tf.frame.height { setHeight(tf, h) }
            } else if let b = v as? NSButton, !(b is NSPopUpButton), !b.isBordered, !b.title.isEmpty,
                      ceil(b.cell?.cellSize.width ?? 0) > b.frame.width {
                makeWrapping(b)
                setHeight(b, max(b.frame.height, fitHeight(b, width: b.frame.width)))
            }
        }

        // 3. Кнопки с рамкой: ширина по тексту; ряд, который не влезает, — в столбик на всю ширину.
        for row in rows {
            let buttons = row.compactMap { $0 as? NSButton }.filter { !($0 is NSPopUpButton) && $0.isBordered }
                .sorted { $0.frame.minX < $1.frame.minX }
            guard !buttons.isEmpty else { continue }
            let need = buttons.map { ceil($0.cell?.cellSize.width ?? 0) + 2 }     // cellSize уже с полями кнопки
            guard zip(buttons, need).contains(where: { $0.frame.width < $1 }) else { continue }
            let start = buttons[0].frame.minX
            let rowGap: CGFloat = buttons.count > 1 ? buttons[1].frame.minX - buttons[0].frame.maxX : 10
            let gaps = rowGap * CGFloat(buttons.count - 1)
            // прежние ширины, где хватает; если ряд так не влезает — точно по тексту
            var widths = zip(buttons, need).map { max($0.frame.width, $1) }
            if start + widths.reduce(0, +) + gaps > right { widths = need }
            if start + widths.reduce(0, +) + gaps <= right {
                var x = start
                for (b, w) in zip(buttons, widths) {
                    b.frame = NSRect(x: x, y: b.frame.minY, width: w, height: b.frame.height)
                    x += w + rowGap
                }
            } else {
                // столбиком: первая кнопка на месте, остальные ниже; рост ряда — на первой кнопке
                let h = buttons[0].frame.height, step = h + 8
                for (i, b) in buttons.enumerated() {
                    b.frame = NSRect(x: start, y: buttons[0].frame.minY - CGFloat(i) * step, width: right - start, height: h)
                }
                grow[ObjectIdentifier(buttons[0]), default: 0] += step * CGFloat(buttons.count - 1)
            }
        }

        // 4. Сдвиг вниз всего, что ниже выросших элементов.
        var offset: CGFloat = 0
        for row in rows {
            var rowGrow: CGFloat = 0
            for v in row {
                v.frame.origin.y -= offset
                rowGrow = max(rowGrow, grow[ObjectIdentifier(v)] ?? 0)
            }
            offset += rowGrow
        }

        // 5. Высота вкладки — по содержимому: прежний отступ сверху, 16 снизу.
        let low = items.map { $0.frame.minY }.min() ?? 0
        let high = items.map { $0.frame.maxY }.max() ?? 0
        let height = topMargin + (high - low) + 16
        for v in items { v.frame.origin.y += 16 - low }
        view.frame = NSRect(x: view.frame.minX, y: view.frame.minY, width: view.frame.width, height: height)
    }

    private func createGeneralTab() -> NSTabViewItem {
        let item = NSTabViewItem()
        item.label = L10n.settingsTabGeneral

        let view = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 790))
        var y: CGFloat = 750

        // Автопереключение
        let autoSwitch = NSButton(checkboxWithTitle: L10n.settingsAutoSwitch, target: self, action: #selector(autoSwitchChanged))
        autoSwitch.frame = NSRect(x: 20, y: y, width: 420, height: 22)
        autoSwitch.state = SettingsManager.shared.autoSwitchEnabled ? .on : .off
        view.addSubview(autoSwitch)
        autoSwitchCheckbox = autoSwitch
        y -= 30

        // Запуск при логине
        let loginCheckbox = NSButton(checkboxWithTitle: L10n.settingsLaunchAtLogin, target: self, action: #selector(launchAtLoginChanged))
        loginCheckbox.frame = NSRect(x: 20, y: y, width: 420, height: 22)
        loginCheckbox.state = SettingsManager.shared.launchAtLogin ? .on : .off
        view.addSubview(loginCheckbox)
        launchAtLoginCheckbox = loginCheckbox
        y -= 30

        // Запоминание раскладки по приложению
        let perAppCheckbox = NSButton(checkboxWithTitle: L10n.settingsPerAppLayout, target: self, action: #selector(perAppLayoutChanged))
        perAppCheckbox.frame = NSRect(x: 20, y: y, width: 420, height: 22)
        perAppCheckbox.state = SettingsManager.shared.perAppLayout ? .on : .off
        view.addSubview(perAppCheckbox)
        y -= 30

        // Авто-проверка обновлений
        let updCheckbox = NSButton(checkboxWithTitle: L10n.settingsCheckUpdates,
                                   target: self, action: #selector(checkUpdatesEnabledChanged))
        updCheckbox.frame = NSRect(x: 20, y: y, width: 420, height: 22)
        updCheckbox.state = SettingsManager.shared.checkUpdatesEnabled ? .on : .off
        updCheckbox.toolTip = L10n.settingsCheckUpdatesHint
        view.addSubview(updCheckbox)
        checkUpdatesCheckbox = updCheckbox
        y -= 18

        let updHint = NSTextField(wrappingLabelWithString: L10n.settingsCheckUpdatesHint)
        updHint.frame = NSRect(x: 40, y: y - 18, width: 400, height: 32)
        updHint.font = .systemFont(ofSize: 11)
        updHint.textColor = .secondaryLabelColor
        view.addSubview(updHint)
        y -= 40

        // Язык интерфейса
        let langLabel = NSTextField(labelWithString: L10n.settingsLanguage)
        langLabel.frame = NSRect(x: 20, y: y, width: 130, height: 22)
        view.addSubview(langLabel)

        let langPopup = NSPopUpButton(frame: NSRect(x: 155, y: y - 2, width: 275, height: 26))
        populateLanguagePopup(langPopup)
        langPopup.target = self
        langPopup.action = #selector(languageChanged)
        view.addSubview(langPopup)
        languagePopup = langPopup
        y -= 40

        // Раскладка 1
        let label1 = NSTextField(labelWithString: L10n.settingsLayout1)
        label1.frame = NSRect(x: 20, y: y, width: 100, height: 22)
        view.addSubview(label1)

        let popup1 = NSPopUpButton(frame: NSRect(x: 130, y: y - 2, width: 300, height: 26))
        populateLayoutPopup(popup1, selectedID: SettingsManager.shared.layout1ID)
        popup1.target = self
        popup1.action = #selector(layout1Changed)
        view.addSubview(popup1)
        layout1Popup = popup1
        y -= 35

        // Раскладка 2
        let label2 = NSTextField(labelWithString: L10n.settingsLayout2)
        label2.frame = NSRect(x: 20, y: y, width: 100, height: 22)
        view.addSubview(label2)

        let popup2 = NSPopUpButton(frame: NSRect(x: 130, y: y - 2, width: 300, height: 26))
        populateLayoutPopup(popup2, selectedID: SettingsManager.shared.layout2ID)
        popup2.target = self
        popup2.action = #selector(layout2Changed)
        view.addSubview(popup2)
        layout2Popup = popup2
        y -= 50

        fitToText(view)
        item.view = topAligned(view)
        return item
    }

    // MARK: - Hotkeys Tab

    private static let modifierItems: [(key: String, title: String)] = [
        ("option", "Option ⌥ (Alt)"),
        ("command", "Command ⌘"),
        ("control", "Control ⌃"),
        ("shift", "Shift ⇧"),
        ("fn", "Fn 🌐 (Globe)"),   // #38
    ]
    // issue #12: комбо двух модификаторов (привычный по Windows стиль Alt+Shift).
    private static let comboItems: [(key: String, title: String)] = [
        ("option+shift", "⌥ + ⇧  (Option + Shift)"),   // discussion #32: виндовый дефолт
        ("command+shift", "⌘ + ⇧  (Command + Shift)"),
        ("control+shift", "⌃ + ⇧  (Control + Shift)"),
        ("command+option", "⌘ + ⌥  (Command + Option)"),
        ("control+option", "⌃ + ⌥  (Control + Option)"),
        ("fn+shift", "🌐 + ⇧  (Fn + Shift)"),
    ]

    /// Все хоткеи: триггер конверсии, смена раскладки (#14), регистр (#29), «всегда
    /// раскладка 1/2» (discussion #32), «в исключения». У каждого: клавиша, сторона
    /// (любая/левая/правая — для одиночного модификатора) и двойное нажатие.
    private func createHotkeysTab() -> NSTabViewItem {
        let item = NSTabViewItem()
        item.label = L10n.settingsTabHotkeys

        let view = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 900))
        var y: CGFloat = 860
        let groups: [(slot: HotkeySlot, title: String, hint: String?)] = [
            (.trigger, L10n.settingsTrigger, nil),
            (.switchLayout, L10n.settingsSwitchHotkey, nil),
            (.changeCase, L10n.settingsCaseHotkey, nil),
            (.layout1, L10n.settingsHotkeyLayout1, nil),
            (.layout2, L10n.settingsHotkeyLayout2, L10n.settingsHotkeyLayoutHint),
            (.addException, L10n.settingsHotkeyException, L10n.settingsHotkeyExceptionHint),
        ]
        for (index, group) in groups.enumerated() {
            let tag = HotkeySlot.allCases.firstIndex(of: group.slot) ?? 0
            let label = NSTextField(labelWithString: hotkeyTitle(group.slot, base: group.title))
            hotkeyTitleLabels[group.slot] = label
            label.frame = NSRect(x: 20, y: y, width: 150, height: 22)
            view.addSubview(label)
            let popup = NSPopUpButton(frame: NSRect(x: 175, y: y - 2, width: 255, height: 26))
            popup.tag = tag
            popup.target = self
            popup.action = #selector(hotkeyKeyChanged)
            view.addSubview(popup)
            hotkeyPopups[group.slot] = popup
            y -= 34

            let side = NSPopUpButton(frame: NSRect(x: 40, y: y - 2, width: 240, height: 26))
            for title in [L10n.settingsHotkeySideAny, L10n.settingsHotkeySideLeft, L10n.settingsHotkeySideRight] {
                side.addItem(withTitle: title)
            }
            side.tag = tag
            side.target = self
            side.action = #selector(hotkeySideChanged)
            view.addSubview(side)
            hotkeySidePopups[group.slot] = side
            let double = NSButton(checkboxWithTitle: L10n.settingsTriggerDoubleTap, target: self, action: #selector(hotkeyDoubleChanged))
            double.frame = NSRect(x: 290, y: y, width: 150, height: 22)
            double.tag = tag
            view.addSubview(double)
            hotkeyDoubleChecks[group.slot] = double
            y -= 30

            if let hint = group.hint {
                // Рамка строго под строкой выше и с зазором до следующей группы: fitToText
                // объединяет в строку элементы, чьи рамки пересекаются по вертикали.
                let h = NSTextField(wrappingLabelWithString: hint)
                h.frame = NSRect(x: 40, y: y + 14 - 46, width: 400, height: 46)
                h.font = .systemFont(ofSize: 11)
                h.textColor = .secondaryLabelColor
                view.addSubview(h)
                y -= 56
            }
            if index < groups.count - 1 { y -= 8 }
        }

        let triggerHint = NSTextField(wrappingLabelWithString: L10n.settingsTriggerHint + " " + L10n.settingsHotkey)
        triggerHint.frame = NSRect(x: 20, y: y - 44, width: 420, height: 44)
        triggerHint.font = .systemFont(ofSize: 11)
        triggerHint.textColor = .secondaryLabelColor
        view.addSubview(triggerHint)

        // #38: два ограничения Fn, которые от нас не зависят.
        let fnHint = NSTextField(wrappingLabelWithString: L10n.settingsHotkeyFnHint)
        fnHint.frame = NSRect(x: 20, y: y - 44 - 12 - 44, width: 420, height: 44)
        fnHint.font = .systemFont(ofSize: 11)
        fnHint.textColor = .secondaryLabelColor
        view.addSubview(fnHint)
        fnHintLabel = fnHint

        refreshHotkeyControls()
        refreshFnHint()
        fitToText(view)
        item.view = topAligned(view)
        return item
    }

    /// «Всегда раскладка 1 (английский)»: рядом с номером язык раскладки на языке интерфейса,
    /// чтобы не сверяться с «Основными» (просьба kobygold, discussion #32). Системное имя
    /// («ABC») про язык ничего не говорит, а иностранцу ещё и приходило по-русски.
    private func hotkeyTitle(_ slot: HotkeySlot, base: String) -> String {
        let n = slot == .layout1 ? 1 : (slot == .layout2 ? 2 : 0)
        guard n > 0, let name = Self.pairLayoutLabel(n) else { return base }
        return "\(base) (\(name))"
    }

    /// Язык раскладки N; если у пары один язык («Русская» и «Русская — ПК»), он раскладки не
    /// различит — тогда системное имя раскладки.
    private static func pairLayoutLabel(_ n: Int) -> String? {
        let langs = LayoutSwitcher.pairLanguages()
        if langs.count == 2, langs[0] != langs[1],
           let name = Locale(identifier: L10n.languageCode).localizedString(forLanguageCode: langs[n - 1]) {
            return name
        }
        return LayoutSwitcher.pairLayoutName(n)
    }

    /// Раскладку 1/2 сменили в «Основных» — подписи хоткеев должны показать новые имена.
    private func refreshLayoutHotkeyTitles() {
        hotkeyTitleLabels[.layout1]?.stringValue = hotkeyTitle(.layout1, base: L10n.settingsHotkeyLayout1)
        hotkeyTitleLabels[.layout2]?.stringValue = hotkeyTitle(.layout2, base: L10n.settingsHotkeyLayout2)
    }

    /// Состояние всех контролов хоткеев по настройкам. Пункты, занятые хоткеем выше по
    /// приоритету (с учётом стороны), гасятся с пометкой: движок их всё равно проигнорирует,
    /// одно нажатие не должно делать два действия (issue #20: не оставлять пункт немым серым).
    private func refreshHotkeyControls() {
        let settings = SettingsManager.shared
        for slot in HotkeySlot.allCases {
            guard let popup = hotkeyPopups[slot] else { continue }
            let current = settings.hotkey(slot)
            popup.removeAllItems()
            popup.autoenablesItems = false
            if slot != .trigger {
                popup.addItem(withTitle: L10n.settingsSwitchHotkeyOff)
                popup.menu?.items.last?.representedObject = "" as NSString
                popup.menu?.addItem(.separator())
            }
            func add(_ it: (key: String, title: String)) {
                popup.addItem(withTitle: it.title)
                guard let menuItem = popup.menu?.items.last else { return }
                menuItem.representedObject = it.key as NSString
                // Занят, только если у клавиши не осталось свободной стороны: при левом ⌘ у
                // раскладки 1 ⌘ для раскладки 2 доступен (сторона сама встанет на правую).
                if Self.freeSide(for: slot, key: it.key, preferred: current.side) == nil {
                    menuItem.isEnabled = false
                    menuItem.title += L10n.settingsSwitchHotkeyBusy
                    menuItem.toolTip = L10n.settingsSwitchHotkeyBusy
                }
            }
            Self.modifierItems.forEach(add)
            popup.menu?.addItem(.separator())
            Self.comboItems.forEach(add)
            let key = slot == .trigger && current.key.isEmpty ? "option" : current.key
            if let idx = popup.menu?.items.firstIndex(where: { ($0.representedObject as? String) == key }) {
                popup.selectItem(at: idx)
            } else {
                popup.selectItem(at: 0)
            }

            let side = hotkeySidePopups[slot]
            side?.selectItem(at: [HotkeySide.any, .left, .right].firstIndex(of: current.hasSides ? current.side : .any) ?? 0)
            side?.isEnabled = !current.key.isEmpty && current.hasSides
            hotkeyDoubleChecks[slot]?.state = current.doubleTap ? .on : .off
            hotkeyDoubleChecks[slot]?.isEnabled = !current.key.isEmpty
        }
    }

    /// Сторона, на которой клавиша свободна от хоткеев выше по приоритету (сначала желаемая).
    /// nil — занята целиком. У комбо стороны нет.
    private static func freeSide(for slot: HotkeySlot, key: String, preferred: HotkeySide) -> HotkeySide? {
        let settings = SettingsManager.shared
        let higher = HotkeySlot.allCases.prefix(while: { $0 != slot }).map { settings.hotkey($0) }
        let sides: [HotkeySide] = HotkeySetting(key: key, side: .any, doubleTap: false).hasSides ? [preferred, .any, .left, .right] : [.any]
        return sides.first { side in !higher.contains { HotkeySetting(key: key, side: side, doubleTap: false).overlaps($0) } }
    }

    /// Подсказка про Fn предупреждает (оранжевым), если Fn выбран, а у Глобуса в системе своё
    /// действие (AppleFnUsageType: 0 — «действие не требуется»): тогда macOS сработает тоже.
    private func refreshFnHint() {
        let settings = SettingsManager.shared
        let fnUsed = HotkeySlot.allCases.contains { settings.hotkey($0).key.hasPrefix("fn") }
        let globeAction = UserDefaults(suiteName: "com.apple.HIToolbox")?.object(forKey: "AppleFnUsageType") as? Int
        fnHintLabel?.textColor = fnUsed && globeAction != 0 ? .systemOrange : .secondaryLabelColor
    }

    private func updateHotkey(tag: Int, keyChanged: Bool = false, _ change: (inout HotkeySetting) -> Void) {
        guard HotkeySlot.allCases.indices.contains(tag) else { return }
        let slot = HotkeySlot.allCases[tag]
        var h = SettingsManager.shared.hotkey(slot)
        change(&h)
        if !h.hasSides { h.side = .any }   // у комбо и у Fn стороны нет
        // Новую клавишу ставим на свободную сторону, если выбранная занята (левый ⌘ уже у
        // раскладки 1 → ⌘ для раскладки 2 сам встаёт на правую).
        if keyChanged, !h.key.isEmpty, let side = Self.freeSide(for: slot, key: h.key, preferred: h.side) { h.side = side }
        SettingsManager.shared.setHotkey(slot, h)
        refreshHotkeyControls()
        refreshFnHint()
        onTriggerChanged?()               // reconfigure перечитает все хоткеи
    }

    @objc private func hotkeyKeyChanged(_ sender: NSPopUpButton) {
        let key = (sender.selectedItem?.representedObject as? String) ?? ""
        updateHotkey(tag: sender.tag, keyChanged: true) { $0.key = key }
    }

    @objc private func hotkeySideChanged(_ sender: NSPopUpButton) {
        let side = [HotkeySide.any, .left, .right][max(0, min(2, sender.indexOfSelectedItem))]
        updateHotkey(tag: sender.tag) { $0.side = side }
    }

    @objc private func hotkeyDoubleChanged(_ sender: NSButton) {
        let on = sender.state == .on
        updateHotkey(tag: sender.tag) { $0.doubleTap = on }
    }

    // MARK: - Exceptions Tab

    private func createExceptionsTab() -> NSTabViewItem {
        let item = NSTabViewItem()
        item.label = L10n.settingsTabExceptions

        let view = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 1000))
        var y: CGFloat = 986          // y — верх следующего элемента, идём сверху вниз (fitToText подгонит высоту)
        exceptionEditors.removeAll()

        // Авто-конвертация
        let autoConvert = NSButton(checkboxWithTitle: L10n.settingsAutoConvert, target: self, action: #selector(autoConvertChanged))
        autoConvert.frame = NSRect(x: 20, y: y - 22, width: 420, height: 22)
        autoConvert.state = SettingsManager.shared.autoConvert ? .on : .off
        view.addSubview(autoConvert)
        autoConvertCheckbox = autoConvert
        y -= 24
        let acHint = NSTextField(wrappingLabelWithString: L10n.settingsAutoConvertHint)
        acHint.frame = NSRect(x: 40, y: y - 32, width: 400, height: 32)
        acHint.font = .systemFont(ofSize: 11); acHint.textColor = .secondaryLabelColor
        view.addSubview(acHint)
        y -= 38

        // 3.5.0b: на каких клавишах срабатывает конвейер (автоконверсия, автозамена, правка)
        let s = SettingsManager.shared
        let keysLabel = NSTextField(labelWithString: L10n.settingsWordEndKeys)
        keysLabel.frame = NSRect(x: 20, y: y - 18, width: 420, height: 18)
        view.addSubview(keysLabel)
        y -= 22
        let keyBoxes: [(String, Bool)] = [(L10n.settingsWordEndSpace, s.wordEndOnSpace),
                                          (L10n.settingsWordEndEnter, s.wordEndOnEnter),
                                          (L10n.settingsWordEndTab, s.wordEndOnTab)]
        for (i, (title, on)) in keyBoxes.enumerated() {
            let cb = NSButton(checkboxWithTitle: title, target: self, action: #selector(wordEndKeyChanged))
            cb.frame = NSRect(x: 40 + CGFloat(i) * 130, y: y - 22, width: 120, height: 22)
            cb.state = on ? .on : .off
            cb.tag = i
            view.addSubview(cb)
        }
        y -= 24
        let keysHint = NSTextField(wrappingLabelWithString: L10n.settingsWordEndHint)
        keysHint.frame = NSRect(x: 40, y: y - 32, width: 400, height: 32)
        keysHint.font = .systemFont(ofSize: 11); keysHint.textColor = .secondaryLabelColor
        view.addSubview(keysHint)
        y -= 38

        // 3.5.0b: правка текста
        let twoCaps = NSButton(checkboxWithTitle: L10n.settingsFixTwoCaps, target: self, action: #selector(fixTwoCapsChanged))
        twoCaps.frame = NSRect(x: 20, y: y - 22, width: 420, height: 22)
        twoCaps.state = s.fixTwoCaps ? .on : .off
        view.addSubview(twoCaps)
        y -= 24
        let typos = NSButton(checkboxWithTitle: L10n.settingsFixTypos, target: self, action: #selector(fixTyposChanged))
        typos.frame = NSRect(x: 20, y: y - 22, width: 420, height: 22)
        typos.state = s.fixTypos ? .on : .off
        view.addSubview(typos)
        y -= 24
        let typosHint = NSTextField(wrappingLabelWithString: L10n.settingsFixTyposHint)
        typosHint.frame = NSRect(x: 40, y: y - 32, width: 400, height: 32)
        typosHint.font = .systemFont(ofSize: 11); typosHint.textColor = .secondaryLabelColor
        view.addSubview(typosHint)
        y -= 38

        // Скачиваемые частотные словари (3.5): нужны только автоконверсии, поэтому здесь.
        let packs = NSButton(checkboxWithTitle: L10n.settingsFreqPacks, target: self, action: #selector(freqPacksChanged))
        packs.frame = NSRect(x: 20, y: y - 22, width: 420, height: 22)
        view.addSubview(packs)
        freqPacksCheckbox = packs
        y -= 24
        let packsHint = NSTextField(wrappingLabelWithString: L10n.settingsFreqPacksHint)
        packsHint.frame = NSRect(x: 40, y: y - 44, width: 400, height: 44)
        packsHint.font = .systemFont(ofSize: 11); packsHint.textColor = .secondaryLabelColor
        view.addSubview(packsHint)
        y -= 46
        // Статус всегда занимает строку (пустая — просто пробел), чтобы вёрстка не прыгала.
        let packsStatus = NSTextField(labelWithString: " ")
        packsStatus.frame = NSRect(x: 40, y: y - 16, width: 400, height: 16)
        packsStatus.font = .systemFont(ofSize: 11)
        view.addSubview(packsStatus)
        freqPacksStatus = packsStatus
        y -= 24
        refreshFrequencyPacksState()

        // Флаг у курсора (issue #10)
        let caretFlag = NSButton(checkboxWithTitle: L10n.settingsCaretFlag, target: self, action: #selector(caretFlagChanged))
        caretFlag.frame = NSRect(x: 20, y: y - 22, width: 420, height: 22)
        caretFlag.state = SettingsManager.shared.caretFlag ? .on : .off
        view.addSubview(caretFlag)
        caretFlagCheckbox = caretFlag
        y -= 24
        let cfHint = NSTextField(wrappingLabelWithString: L10n.settingsCaretFlagHint)
        cfHint.frame = NSRect(x: 40, y: y - 44, width: 400, height: 44)
        cfHint.font = .systemFont(ofSize: 11); cfHint.textColor = .secondaryLabelColor
        view.addSubview(cfHint)
        y -= 52

        // Режим удалённого стола отложен в 2.5 — блок скрыт за флагом (для тестирования).
        if SettingsManager.shared.showRemoteDesktopBeta {
            let remote = NSButton(checkboxWithTitle: L10n.menuRemoteDesktop, target: self, action: #selector(remoteDesktopChanged))
            remote.frame = NSRect(x: 20, y: y - 22, width: 420, height: 22)
            remote.state = SettingsManager.shared.remoteDesktopMode ? .on : .off
            view.addSubview(remote)
            remoteDesktopCheckbox = remote
            y -= 24
            let rHint = NSTextField(wrappingLabelWithString: L10n.settingsRemoteDesktopHint)
            rHint.frame = NSRect(x: 40, y: y - 44, width: 400, height: 44)
            rHint.font = .systemFont(ofSize: 11); rHint.textColor = .secondaryLabelColor
            view.addSubview(rHint)
            y -= 52
        }

        // Секция: заголовок сверху, ниже — таблица с кнопками. Зазоры фиксированные,
        // поэтому раскладка одинаково корректна на всех языках (заголовки не переносятся).
        func addSection(_ title: String, _ editor: ExceptionListEditor) {
            let header = NSTextField(labelWithString: title)
            header.frame = NSRect(x: 20, y: y - 18, width: 420, height: 18)
            header.font = .boldSystemFont(ofSize: 11)
            header.lineBreakMode = .byTruncatingTail
            view.addSubview(header)
            let contH: CGFloat = 96
            let cont = editor.makeContainer(frame: NSRect(x: 20, y: y - 22 - contH, width: 420, height: contH))
            view.addSubview(cont)
            exceptionEditors.append(editor)
            y -= (22 + contH + 14)   // заголовок+зазор + таблица + зазор до следующей секции
        }

        addSection(L10n.settingsExceptionsApps, ExceptionListEditor(
            kind: .apps,
            get: { SettingsManager.shared.deniedApps },
            set: { SettingsManager.shared.deniedApps = $0 },
            isProtected: { AutoSwitchPolicy.protectedApps.contains($0) }))

        addSection(L10n.settingsExceptionsNever, ExceptionListEditor(
            kind: .words,
            get: { SettingsManager.shared.deniedWords },
            set: { SettingsManager.shared.deniedWords = $0 },
            addWordPrompt: L10n.settingsAddWordPrompt))

        addSection(L10n.settingsExceptionsAlways, ExceptionListEditor(
            kind: .words,
            get: { SettingsManager.shared.alwaysConvertWords },
            set: { SettingsManager.shared.alwaysConvertWords = $0 },
            addWordPrompt: L10n.settingsAddWordPrompt))

        // 3.5.0b: автозамена сокращений
        let abbrHeader = NSTextField(labelWithString: L10n.settingsAbbrHeader)
        abbrHeader.frame = NSRect(x: 20, y: y - 18, width: 420, height: 18)
        abbrHeader.font = .boldSystemFont(ofSize: 11)
        abbrHeader.lineBreakMode = .byTruncatingTail
        view.addSubview(abbrHeader)
        let abbrH: CGFloat = 120
        let abbrEditor = AbbreviationEditor(get: { SettingsManager.shared.abbreviations },
                                            set: { SettingsManager.shared.abbreviations = $0 })
        view.addSubview(abbrEditor.makeContainer(frame: NSRect(x: 20, y: y - 22 - abbrH, width: 420, height: abbrH)))
        abbreviationEditor = abbrEditor
        y -= (22 + abbrH + 6)
        let abbrHint = NSTextField(wrappingLabelWithString: L10n.settingsAbbrHint)
        abbrHint.frame = NSRect(x: 20, y: y - 32, width: 420, height: 32)
        abbrHint.font = .systemFont(ofSize: 11); abbrHint.textColor = .secondaryLabelColor
        view.addSubview(abbrHint)
        y -= 38

        fitToText(view)
        item.view = scrollableTopAligned(view, maxHeight: 760)
        return item
    }

    // MARK: - About Tab

    private func createAboutTab() -> NSTabViewItem {
        let item = NSTabViewItem()
        item.label = L10n.settingsTabAbout

        let view = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 360))
        var y: CGFloat = 310

        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.frame = NSRect(x: 16, y: 258, width: 84, height: 84)
        view.addSubview(icon)

        // Название и версия
        let titleLabel = NSTextField(labelWithString: "RuSwitcher")
        titleLabel.font = .boldSystemFont(ofSize: 20)
        titleLabel.frame = NSRect(x: 108, y: y, width: 332, height: 28)
        view.addSubview(titleLabel)
        y -= 25

        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let devTag = Bundle.main.infoDictionary?["RSDevTag"] as? String ?? ""
        let versionLabel = NSTextField(labelWithString: "v\(version)\(devTag) — \(L10n.settingsVersion)")
        versionLabel.frame = NSRect(x: 108, y: y, width: 332, height: 20)
        versionLabel.font = .systemFont(ofSize: 12)
        versionLabel.textColor = .secondaryLabelColor
        view.addSubview(versionLabel)
        y -= 22

        // Сайт — ссылкой под версией. Подпись — сам адрес: переводить нечего.
        let siteLink = NSButton(title: "ruswitcher.app", target: self, action: #selector(openWebsite))
        siteLink.isBordered = false
        siteLink.attributedTitle = NSAttributedString(string: "ruswitcher.app", attributes: [
            .foregroundColor: NSColor.linkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .font: NSFont.systemFont(ofSize: 12),
        ])
        siteLink.frame = NSRect(x: 97, y: y, width: 110, height: 18)   // у кнопки без рамки ~11 pt поля: текст ровно под заголовком
        view.addSubview(siteLink)
        y -= 40

        // Кнопка "Звезда на GitHub"
        let starBtn = NSButton(title: L10n.settingsStarOnGithub, target: self, action: #selector(openGitHub))
        starBtn.frame = NSRect(x: 20, y: y, width: 420, height: 32)
        starBtn.bezelStyle = .rounded
        view.addSubview(starBtn)
        y -= 40

        // Кнопка доната
        let donateBtn = NSButton(title: L10n.settingsDonate, target: self, action: #selector(openDonate))
        donateBtn.frame = NSRect(x: 20, y: y, width: 200, height: 32)
        donateBtn.bezelStyle = .rounded
        view.addSubview(donateBtn)

        // Кнопка контакта
        let contactBtn = NSButton(title: L10n.settingsContact, target: self, action: #selector(openContact))
        contactBtn.frame = NSRect(x: 230, y: y, width: 200, height: 32)
        contactBtn.bezelStyle = .rounded
        view.addSubview(contactBtn)
        y -= 40

        // Проверить обновления
        let updateBtn = NSButton(title: L10n.menuCheckUpdates, target: self, action: #selector(checkUpdates))
        updateBtn.frame = NSRect(x: 20, y: y, width: 200, height: 32)
        updateBtn.bezelStyle = .rounded
        view.addSubview(updateBtn)

        fitToText(view)
        item.view = topAligned(view)
        return item
    }

    // MARK: - Advanced Tab

    private func createAdvancedTab() -> NSTabViewItem {
        let item = NSTabViewItem()
        item.label = L10n.settingsTabAdvanced

        let view = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 595))
        var y: CGFloat = 545

        // Бета-версии (пред-релизы) — для тестировщиков; по умолчанию ВЫКЛ.
        let betaCheckbox = NSButton(checkboxWithTitle: L10n.settingsBetaChannel,
                                    target: self, action: #selector(betaChannelChanged))
        betaCheckbox.frame = NSRect(x: 20, y: y, width: 420, height: 22)
        betaCheckbox.state = SettingsManager.shared.betaChannelEnabled ? .on : .off
        betaCheckbox.toolTip = L10n.settingsBetaChannelHint
        view.addSubview(betaCheckbox)
        y -= 18

        let betaHint = NSTextField(wrappingLabelWithString: L10n.settingsBetaChannelHint)
        betaHint.frame = NSRect(x: 40, y: y - 18, width: 400, height: 32)
        betaHint.font = .systemFont(ofSize: 11)
        betaHint.textColor = .secondaryLabelColor
        view.addSubview(betaHint)
        y -= 47   // дальше идём по бегущему y

        // issue #22 (B): умная по-словная конверсия выделения. По умолчанию ВКЛ.
        let smartCheckbox = NSButton(checkboxWithTitle: L10n.settingsSmartConversion,
                                     target: self, action: #selector(smartConversionChanged))
        smartCheckbox.frame = NSRect(x: 20, y: y, width: 420, height: 22)
        smartCheckbox.state = SettingsManager.shared.smartConversion ? .on : .off
        smartCheckbox.toolTip = L10n.settingsSmartConversionHint
        view.addSubview(smartCheckbox)
        y -= 18

        let smartHint = NSTextField(wrappingLabelWithString: L10n.settingsSmartConversionHint)
        smartHint.frame = NSRect(x: 40, y: y - 18, width: 400, height: 32)
        smartHint.font = .systemFont(ofSize: 11)
        smartHint.textColor = .secondaryLabelColor
        view.addSubview(smartHint)
        y -= 47

        // issue #22 (A): ручной триггер конвертирует ПО ТЕКСТУ (тотальный флип обеих
        // письменностей). По умолчанию ВЫКЛ; перебивает умную конверсию.
        let byTextCheckbox = NSButton(checkboxWithTitle: L10n.settingsConvertByText,
                                      target: self, action: #selector(convertByTextChanged))
        byTextCheckbox.frame = NSRect(x: 20, y: y, width: 420, height: 22)
        byTextCheckbox.state = SettingsManager.shared.convertByText ? .on : .off
        byTextCheckbox.toolTip = L10n.settingsConvertByTextHint
        view.addSubview(byTextCheckbox)
        y -= 18

        let byTextHint = NSTextField(wrappingLabelWithString: L10n.settingsConvertByTextHint)
        byTextHint.frame = NSRect(x: 40, y: y - 18, width: 400, height: 32)
        byTextHint.font = .systemFont(ofSize: 11)
        byTextHint.textColor = .secondaryLabelColor
        view.addSubview(byTextHint)
        y -= 47

        // issue #24: триггер конвертирует всю строку (не только последнее слово). По умолч. ВЫКЛ.
        let wholeLineCheckbox = NSButton(checkboxWithTitle: L10n.settingsConvertWholeLine,
                                         target: self, action: #selector(convertWholeLineChanged))
        wholeLineCheckbox.frame = NSRect(x: 20, y: y, width: 420, height: 22)
        wholeLineCheckbox.state = SettingsManager.shared.convertWholeLine ? .on : .off
        wholeLineCheckbox.toolTip = L10n.settingsConvertWholeLineHint
        view.addSubview(wholeLineCheckbox)
        y -= 18

        let wholeLineHint = NSTextField(wrappingLabelWithString: L10n.settingsConvertWholeLineHint)
        wholeLineHint.frame = NSRect(x: 40, y: y - 18, width: 400, height: 32)
        wholeLineHint.font = .systemFont(ofSize: 11)
        wholeLineHint.textColor = .secondaryLabelColor
        view.addSubview(wholeLineHint)
        y -= 47

        // issue #27: показывать неактивирующую подсказку о защищённом вводе. По умолчанию ВКЛ.
        let secureNoticeCheckbox = NSButton(checkboxWithTitle: L10n.settingsSecureNotice,
                                            target: self, action: #selector(secureNoticeChanged))
        secureNoticeCheckbox.frame = NSRect(x: 20, y: y, width: 420, height: 22)
        secureNoticeCheckbox.state = SettingsManager.shared.secureInputNoticeEnabled ? .on : .off
        view.addSubview(secureNoticeCheckbox)
        y -= 32

        // Скрыть иконку из меню-бара (запрос пользователя). По умолчанию ВЫКЛ.
        // При включении — подтверждающий алерт с объяснением, как вернуть (reopen).
        let hideIconCheckbox = NSButton(checkboxWithTitle: L10n.settingsHideIcon,
                                        target: self, action: #selector(hideIconChanged(_:)))
        hideIconCheckbox.frame = NSRect(x: 20, y: y, width: 420, height: 22)
        hideIconCheckbox.state = SettingsManager.shared.hideMenuBarIcon ? .on : .off
        view.addSubview(hideIconCheckbox)
        y -= 18

        let hideIconHint = NSTextField(wrappingLabelWithString: L10n.settingsHideIconHint)
        hideIconHint.frame = NSRect(x: 40, y: y - 18, width: 400, height: 32)
        hideIconHint.font = .systemFont(ofSize: 11)
        hideIconHint.textColor = .secondaryLabelColor
        view.addSubview(hideIconHint)
        y -= 47

        // Размер флага в меню-баре (идея из форка landco-debug). Для монохромной плашки не нужен.
        let flagLabel = NSTextField(labelWithString: L10n.settingsFlagSize)
        flagLabel.frame = NSRect(x: 20, y: y, width: 150, height: 22)
        view.addSubview(flagLabel)
        let flagPopup = NSPopUpButton(frame: NSRect(x: 175, y: y - 2, width: 255, height: 26))
        for size in SettingsManager.flagSizes {
            flagPopup.addItem(withTitle: size == 0 ? L10n.settingsFlagSizeStandard : "\(size) pt")
            flagPopup.menu?.items.last?.tag = size
        }
        flagPopup.selectItem(withTag: SettingsManager.shared.flagSize)
        flagPopup.isEnabled = !SettingsManager.shared.monochromeIcon
        flagPopup.target = self
        flagPopup.action = #selector(flagSizeChanged)
        view.addSubview(flagPopup)
        flagSizePopup = flagPopup
        y -= 40

        // Debug log
        let debugCheckbox = NSButton(checkboxWithTitle: L10n.settingsDebugLog, target: self, action: #selector(debugLogChanged))
        debugCheckbox.frame = NSRect(x: 20, y: y, width: 420, height: 22)
        debugCheckbox.state = SettingsManager.shared.debugLogEnabled ? .on : .off
        view.addSubview(debugCheckbox)
        debugLogCheckbox = debugCheckbox
        y -= 35

        // Показать лог
        let showLogBtn = NSButton(title: L10n.settingsShowLog, target: self, action: #selector(showLogFile))
        showLogBtn.frame = NSRect(x: 20, y: y, width: 180, height: 32)
        showLogBtn.bezelStyle = .rounded
        view.addSubview(showLogBtn)

        // Отправить лог
        let sendLogBtn = NSButton(title: L10n.settingsSendLog, target: self, action: #selector(sendLogFile))
        sendLogBtn.frame = NSRect(x: 210, y: y, width: 180, height: 32)
        sendLogBtn.bezelStyle = .rounded
        view.addSubview(sendLogBtn)
        y -= 50

        // Путь к логу
        let logPath = logFilePath()
        let pathLabel = NSTextField(wrappingLabelWithString: logPath)
        pathLabel.frame = NSRect(x: 20, y: y - 20, width: 420, height: 40)
        pathLabel.font = .systemFont(ofSize: 10)
        pathLabel.textColor = .tertiaryLabelColor
        pathLabel.isSelectable = true
        view.addSubview(pathLabel)
        y -= 70

        // Завершить приложение. Обязателен при скрытой иконке: LSUIElement-приложение без
        // меню-бара не ловит Cmd-Q, и другого пути выйти при isVisible=false просто нет.
        let quitBtn = NSButton(title: L10n.settingsQuit, target: self, action: #selector(quitApp))
        quitBtn.frame = NSRect(x: 20, y: y, width: 200, height: 32)
        quitBtn.bezelStyle = .rounded
        view.addSubview(quitBtn)

        fitToText(view)
        item.view = topAligned(view)
        return item
    }

    @objc private func hideIconChanged(_ sender: NSButton) {
        let hide = sender.state == .on
        if hide {
            // Подтверждение с рецептом возврата — снимает страх «а как я его потом найду».
            let alert = NSAlert()
            alert.messageText = L10n.settingsHideIconAlertTitle
            alert.informativeText = L10n.settingsHideIconAlertText
            alert.alertStyle = .informational
            alert.addButton(withTitle: L10n.settingsHideIcon)
            alert.addButton(withTitle: L10n.commonCancel)
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() != .alertFirstButtonReturn {
                sender.state = .off
                return
            }
        }
        SettingsManager.shared.hideMenuBarIcon = hide
        onHideIconChanged?(hide)
    }

    /// Монохромную плашку переключают и из меню, а окно настроек живёт всю сессию.
    func refreshFlagSizeState() {
        flagSizePopup?.isEnabled = !SettingsManager.shared.monochromeIcon
    }

    @objc private func flagSizeChanged(_ sender: NSPopUpButton) {
        SettingsManager.shared.flagSize = sender.selectedItem?.tag ?? 0
        onFlagSizeChanged?()
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    // MARK: - Language Popup

    private func populateLanguagePopup(_ popup: NSPopUpButton) {
        popup.removeAllItems()
        popup.addItem(withTitle: "🌐 \(L10n.settingsLanguageAuto)")
        popup.menu?.items.last?.representedObject = "" as NSString

        for lang in L10n.languageNames {
            popup.addItem(withTitle: lang.name)
            popup.menu?.items.last?.representedObject = lang.code as NSString
        }

        selectItem(in: popup, matching: SettingsManager.shared.interfaceLanguage)
    }

    /// Выбирает в popup пункт, у которого representedObject == id (или первый при пустом id)
    private func selectItem(in popup: NSPopUpButton, matching id: String) {
        if id.isEmpty {
            popup.selectItem(at: 0)
            return
        }
        for (i, item) in popup.itemArray.enumerated() {
            if (item.representedObject as? String) == id {
                popup.selectItem(at: i)
                return
            }
        }
        popup.selectItem(at: 0)
    }

    // MARK: - Layout Popup

    private func populateLayoutPopup(_ popup: NSPopUpButton, selectedID: String) {
        popup.removeAllItems()
        popup.addItem(withTitle: L10n.settingsAutoDetect)
        popup.menu?.items.last?.representedObject = "" as NSString

        let layouts = LayoutSwitcher.installedLayouts()
        for layout in layouts {
            let id = LayoutSwitcher.sourceID(layout)
            let name = LayoutSwitcher.sourceName(layout)
            popup.addItem(withTitle: "\(name) (\(id.components(separatedBy: ".").last ?? id))")
            popup.menu?.items.last?.representedObject = id as NSString
        }

        selectItem(in: popup, matching: selectedID)
    }

    private func selectedLayoutID(from popup: NSPopUpButton) -> String {
        (popup.selectedItem?.representedObject as? String) ?? ""
    }

    // MARK: - Trigger Popup

    // MARK: - Actions

    @objc private func autoSwitchChanged(_ sender: NSButton) {
        let enabled = sender.state == .on
        SettingsManager.shared.autoSwitchEnabled = enabled
        onAutoSwitchChanged?(enabled)
    }

    @objc private func launchAtLoginChanged(_ sender: NSButton) {
        SettingsManager.shared.launchAtLogin = sender.state == .on
    }

    @objc private func checkUpdatesEnabledChanged(_ sender: NSButton) {
        SettingsManager.shared.checkUpdatesEnabled = sender.state == .on
    }

    @objc private func languageChanged(_ sender: NSPopUpButton) {
        let langCode = (sender.selectedItem?.representedObject as? String) ?? ""
        SettingsManager.shared.interfaceLanguage = langCode  // вызывает L10n.reloadLanguage()
        onLanguageChanged?()  // пересобрать меню статус-бара под новый язык
        // Пересоздаём окно для применения нового языка
        window?.close()
        window = nil
        showWindow()
    }

    @objc private func layout1Changed(_ sender: NSPopUpButton) {
        SettingsManager.shared.layout1ID = selectedLayoutID(from: sender)
        DynamicKeyMapping.clearCache()
        refreshLayoutHotkeyTitles()
    }

    @objc private func layout2Changed(_ sender: NSPopUpButton) {
        SettingsManager.shared.layout2ID = selectedLayoutID(from: sender)
        DynamicKeyMapping.clearCache()
        refreshLayoutHotkeyTitles()
    }

    @objc private func perAppLayoutChanged(_ sender: NSButton) {
        let enabled = sender.state == .on
        SettingsManager.shared.perAppLayout = enabled
        onPerAppLayoutChanged?(enabled)
    }

    @objc private func freqPacksChanged(_ sender: NSButton) {
        guard sender.state == .on else {
            FrequencyPacks.disable()
            refreshFrequencyPacksState()
            return
        }
        sender.isEnabled = false
        freqPacksStatus?.textColor = .secondaryLabelColor
        freqPacksStatus?.stringValue = L10n.settingsFreqPacksLoading
        Task { @MainActor in
            let outcome = await FrequencyPacks.enable()
            sender.isEnabled = true
            refreshFrequencyPacksState()
            switch outcome {
            case .installed, .cancelled: break
            case .noPacks: freqPacksStatus?.stringValue = L10n.settingsFreqPacksNone
            case .failed:
                freqPacksStatus?.textColor = .systemRed
                freqPacksStatus?.stringValue = L10n.settingsFreqPacksError
            }
        }
    }

    /// Списки исключений изменились снаружи (хоткей «в исключения», learn-from-undo).
    func reloadExceptionLists() {
        exceptionEditors.forEach { $0.reload() }
        abbreviationEditor?.reload()
    }

    /// Галочка и строка «Установлено: RU 50 000 · EN 30 000» по фактическому состоянию.
    func refreshFrequencyPacksState() {
        let on = SettingsManager.shared.frequencyPacks
        freqPacksCheckbox?.state = on ? .on : .off
        freqPacksStatus?.textColor = .secondaryLabelColor
        let installed = on ? FrequencyPacks.installed().filter { FrequencyPacks.pack(for: $0.lang) != nil } : []
        guard !installed.isEmpty else {
            freqPacksStatus?.stringValue = " "
            return
        }
        let fmt = NumberFormatter()
        fmt.numberStyle = .decimal
        let list = installed.map { "\($0.lang.uppercased()) \(fmt.string(from: NSNumber(value: $0.count)) ?? "\($0.count)")" }
        freqPacksStatus?.stringValue = String(format: L10n.settingsFreqPacksInstalled, list.joined(separator: " · "))
    }

    /// 3.5.0b: Пробел/Enter/Tab. Enter и Tab меняют режим event tap — перезапускаем его.
    @objc private func wordEndKeyChanged(_ sender: NSButton) {
        let on = sender.state == .on
        let s = SettingsManager.shared
        switch sender.tag {
        case 0: s.wordEndOnSpace = on
        case 1: s.wordEndOnEnter = on; onTriggerChanged?()
        default: s.wordEndOnTab = on; onTriggerChanged?()
        }
    }

    @objc private func fixTwoCapsChanged(_ sender: NSButton) {
        SettingsManager.shared.fixTwoCaps = sender.state == .on
    }

    @objc private func fixTyposChanged(_ sender: NSButton) {
        SettingsManager.shared.fixTypos = sender.state == .on
    }

    @objc private func autoConvertChanged(_ sender: NSButton) {
        let enabled = sender.state == .on
        SettingsManager.shared.autoConvert = enabled
        onAutoConvertChanged?(enabled)
    }

    @objc private func remoteDesktopChanged(_ sender: NSButton) {
        let enabled = sender.state == .on
        SettingsManager.shared.remoteDesktopMode = enabled
        onRemoteDesktopChanged?(enabled)
    }

    @objc private func caretFlagChanged(_ sender: NSButton) {
        let enabled = sender.state == .on
        SettingsManager.shared.caretFlag = enabled
        onCaretFlagChanged?(enabled)
    }

    @objc private func betaChannelChanged(_ sender: NSButton) {
        SettingsManager.shared.betaChannelEnabled = sender.state == .on
    }

    @objc private func smartConversionChanged(_ sender: NSButton) {
        SettingsManager.shared.smartConversion = sender.state == .on
    }

    @objc private func convertByTextChanged(_ sender: NSButton) {
        SettingsManager.shared.convertByText = sender.state == .on
    }

    @objc private func convertWholeLineChanged(_ sender: NSButton) {
        SettingsManager.shared.convertWholeLine = sender.state == .on
    }

    @objc private func secureNoticeChanged(_ sender: NSButton) {
        SettingsManager.shared.secureInputNoticeEnabled = sender.state == .on
    }

    @objc private func debugLogChanged(_ sender: NSButton) {
        SettingsManager.shared.debugLogEnabled = sender.state == .on
    }

    @objc private func openGitHub() {
        if let url = URL(string: SettingsManager.githubURL) {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func openWebsite() {
        if let url = SettingsManager.websiteLink(medium: "about") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func openDonate() {
        if let url = URL(string: SettingsManager.shared.donateURL) {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func openContact() {
        let email = SettingsManager.shared.contactEmail
        let subject = "RuSwitcher Feedback"
        if let url = URL(string: "mailto:\(email)?subject=\(subject.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? subject)") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func checkUpdates() {
        UpdateChecker.checkNow()
    }

    @objc private func showLogFile() {
        let path = logFilePath()
        if FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
        } else {
            let alert = NSAlert()
            alert.messageText = "Log file not found"
            alert.informativeText = "Enable debug logging first."
            alert.runModal()
        }
    }

    @objc private func sendLogFile() {
        let path = logFilePath()
        guard FileManager.default.fileExists(atPath: path) else {
            showLogFile() // покажет алерт
            return
        }

        let url = URL(fileURLWithPath: path)
        if let service = NSSharingService(named: .composeEmail) {
            service.perform(withItems: [
                "RuSwitcher debug log" as NSString,
                url
            ])
        } else {
            // Fallback: показать в Finder
            NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
        }
    }

    private func logFilePath() -> String {
        let logDir = NSHomeDirectory() + "/Library/Logs/RuSwitcher"
        return logDir + "/ruswitcher.log"
    }
}

/// Перевёрнутые координаты: документ прокрутки начинается сверху (3.5.0b).
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// Вид вкладки: блок фиксированной ширины по центру и у верхнего края. Окно бывает шире блока
/// (длинные названия вкладок), а NSTabView растягивает вид на всю высоту окна.
private final class TabContentContainer: NSView {
    var fillsHeight = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        autoresizingMask = [.width, .height]
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        guard let content = subviews.first else { return }
        let x = max(0, floor((bounds.width - content.frame.width) / 2))
        let height = fillsHeight ? bounds.height : content.frame.height
        content.frame = NSRect(x: x, y: bounds.height - height, width: content.frame.width, height: height)
    }
}
