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
    private var instantConvertCheckbox: NSButton?   // надстройка над авто-конверсией — гаснет вместе с ней
    private var remoteDesktopCheckbox: NSButton?    // #5: то же (опционален — за фичефлагом)
    private var layout1Popup: NSPopUpButton?
    private var layout2Popup: NSPopUpButton?
    private var languagePopup: NSPopUpButton?
    private var switchHotkeyPopup: NSPopUpButton?   // issue #20/#3: пере-populate при смене триггера
    private var caseHotkeyPopup: NSPopUpButton?     // issue #29
    private var exceptionEditors: [ExceptionListEditor] = []

    /// Callback для обновления меню
    var onAutoSwitchChanged: ((Bool) -> Void)?
    var onPerAppLayoutChanged: ((Bool) -> Void)?
    var onLanguageChanged: (() -> Void)?
    var onTriggerChanged: (() -> Void)?
    var onAutoConvertChanged: ((Bool) -> Void)?
    var onRemoteDesktopChanged: ((Bool) -> Void)?
    var onCaretFlagChanged: ((Bool) -> Void)?

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
        tabView.addTabViewItem(createAdvancedTab())     // «Расширенные» — сразу после «Основных»
        tabView.addTabViewItem(createExceptionsTab())
        tabView.addTabViewItem(createAboutTab())

        win.contentView = tabView
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
        instantConvertCheckbox?.isEnabled = enabled   // без авто-конверсии конверсия на лету не работает
    }
    func updateRemoteDesktopState(_ enabled: Bool) {
        remoteDesktopCheckbox?.state = enabled ? .on : .off
    }

    // MARK: - General Tab

    /// Прижимает контент вкладки к ВЕРХУ. NSTabView растягивает вид вкладки на всю высоту окна,
    /// а под-вью с абсолютными координатами (y от низа) иначе провисают к низу/центру короткой
    /// вкладки. Оборачиваем фиксированный контент в растягивающийся контейнер и пиним контент к
    /// верхнему краю (гибкий нижний отступ — .minYMargin).
    private func topAligned(_ content: NSView) -> NSView {
        let outer = NSView(frame: content.frame)
        outer.autoresizingMask = [.width, .height]
        outer.autoresizesSubviews = true
        content.autoresizingMask = [.minYMargin]
        outer.addSubview(content)
        return outer
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

        // Триггер конвертации
        let triggerLabel = NSTextField(labelWithString: L10n.settingsTrigger)
        triggerLabel.frame = NSRect(x: 20, y: y, width: 150, height: 22)
        view.addSubview(triggerLabel)

        let triggerPopup = NSPopUpButton(frame: NSRect(x: 175, y: y - 2, width: 255, height: 26))
        populateTriggerPopup(triggerPopup)
        triggerPopup.target = self
        triggerPopup.action = #selector(triggerChanged)
        view.addSubview(triggerPopup)
        y -= 34

        let rightOnlyCheckbox = NSButton(checkboxWithTitle: L10n.settingsTriggerRightOnly, target: self, action: #selector(triggerRightOnlyChanged))
        rightOnlyCheckbox.frame = NSRect(x: 40, y: y, width: 390, height: 22)
        rightOnlyCheckbox.state = SettingsManager.shared.triggerRightOnly ? .on : .off
        view.addSubview(rightOnlyCheckbox)
        y -= 26

        let doubleTapCheckbox = NSButton(checkboxWithTitle: L10n.settingsTriggerDoubleTap, target: self, action: #selector(triggerDoubleTapChanged))
        doubleTapCheckbox.frame = NSRect(x: 40, y: y, width: 390, height: 22)
        doubleTapCheckbox.state = SettingsManager.shared.triggerDoubleTap ? .on : .off
        view.addSubview(doubleTapCheckbox)
        y -= 30

        // issue #14: отдельный хоткей чистого переключения раскладки (без конверсии) —
        // в т.ч. Ctrl+Shift и другие модификаторные комбо, недоступные системным настройкам.
        let switchLabel = NSTextField(labelWithString: L10n.settingsSwitchHotkey)
        switchLabel.frame = NSRect(x: 20, y: y, width: 150, height: 22)
        view.addSubview(switchLabel)

        let switchPopup = NSPopUpButton(frame: NSRect(x: 175, y: y - 2, width: 255, height: 26))
        populateSwitchHotkeyPopup(switchPopup)
        switchPopup.target = self
        switchPopup.action = #selector(switchHotkeyChanged)
        view.addSubview(switchPopup)
        switchHotkeyPopup = switchPopup
        y -= 34   // как зазор popup→rightOnly у триггера (попап высотой 26 на y-2)

        // issue #14: только правая клавиша хоткея смены (зеркало rightOnly триггера).
        let switchRightOnlyCheckbox = NSButton(checkboxWithTitle: L10n.settingsTriggerRightOnly, target: self, action: #selector(switchRightOnlyChanged))
        switchRightOnlyCheckbox.frame = NSRect(x: 40, y: y, width: 390, height: 22)
        switchRightOnlyCheckbox.state = SettingsManager.shared.switchRightOnly ? .on : .off
        view.addSubview(switchRightOnlyCheckbox)
        y -= 26

        // issue #14: смена по двойному тапу выбранного хоткея (зеркало double-tap триггера).
        let switchDoubleTapCheckbox = NSButton(checkboxWithTitle: L10n.settingsTriggerDoubleTap, target: self, action: #selector(switchDoubleTapChanged))
        switchDoubleTapCheckbox.frame = NSRect(x: 40, y: y, width: 390, height: 22)
        switchDoubleTapCheckbox.state = SettingsManager.shared.switchDoubleTap ? .on : .off
        view.addSubview(switchDoubleTapCheckbox)
        y -= 34

        // issue #29: отдельный хоткей смены регистра (последнее слово / выделение), как Alt+Break
        // в Punto. Должен отличаться от триггера и от хоткея смены раскладки (движок игнорирует совпадения).
        let caseLabel = NSTextField(labelWithString: L10n.settingsCaseHotkey)
        caseLabel.frame = NSRect(x: 20, y: y, width: 150, height: 22)
        view.addSubview(caseLabel)

        let casePopup = NSPopUpButton(frame: NSRect(x: 175, y: y - 2, width: 255, height: 26))
        populateCaseHotkeyPopup(casePopup)
        casePopup.target = self
        casePopup.action = #selector(caseHotkeyChanged)
        view.addSubview(casePopup)
        caseHotkeyPopup = casePopup
        y -= 34

        let caseRightOnlyCheckbox = NSButton(checkboxWithTitle: L10n.settingsTriggerRightOnly, target: self, action: #selector(caseRightOnlyChanged))
        caseRightOnlyCheckbox.frame = NSRect(x: 40, y: y, width: 390, height: 22)
        caseRightOnlyCheckbox.state = SettingsManager.shared.caseRightOnly ? .on : .off
        view.addSubview(caseRightOnlyCheckbox)
        y -= 26

        let caseDoubleTapCheckbox = NSButton(checkboxWithTitle: L10n.settingsTriggerDoubleTap, target: self, action: #selector(caseDoubleTapChanged))
        caseDoubleTapCheckbox.frame = NSRect(x: 40, y: y, width: 390, height: 22)
        caseDoubleTapCheckbox.state = SettingsManager.shared.caseDoubleTap ? .on : .off
        view.addSubview(caseDoubleTapCheckbox)
        y -= 32

        let triggerHint = NSTextField(wrappingLabelWithString: L10n.settingsTriggerHint)
        triggerHint.frame = NSRect(x: 40, y: y - 22, width: 400, height: 36)
        triggerHint.font = .systemFont(ofSize: 11)
        triggerHint.textColor = .secondaryLabelColor
        view.addSubview(triggerHint)
        y -= 48

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

        // Описание хоткея
        let hotkeyLabel = NSTextField(wrappingLabelWithString: L10n.settingsHotkey)
        hotkeyLabel.frame = NSRect(x: 20, y: y - 40, width: 420, height: 55)
        hotkeyLabel.font = .systemFont(ofSize: 12)
        hotkeyLabel.textColor = .secondaryLabelColor
        view.addSubview(hotkeyLabel)

        item.view = topAligned(view)
        return item
    }

    // MARK: - Exceptions Tab

    private func createExceptionsTab() -> NSTabViewItem {
        let item = NSTabViewItem()
        item.label = L10n.settingsTabExceptions

        // Высота с запасом на чекбокс конверсии на лету: три секции исключений по 132 px
        // должны уместиться целиком, иначе нижняя уезжает за край вкладки.
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 676))
        var y: CGFloat = 662          // y — верх следующего элемента, идём сверху вниз
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

        // Конверсия на лету — надстройка над авто-конверсией, поэтому с отступом и гаснет вместе с ней
        let instant = NSButton(checkboxWithTitle: L10n.settingsInstantConvert, target: self, action: #selector(instantConvertChanged))
        instant.frame = NSRect(x: 40, y: y - 22, width: 400, height: 22)
        instant.state = SettingsManager.shared.instantConvert ? .on : .off
        instant.isEnabled = SettingsManager.shared.autoConvert
        view.addSubview(instant)
        instantConvertCheckbox = instant
        y -= 24
        let icHint = NSTextField(wrappingLabelWithString: L10n.settingsInstantConvertHint)
        icHint.frame = NSRect(x: 60, y: y - 44, width: 380, height: 44)
        icHint.font = .systemFont(ofSize: 11); icHint.textColor = .secondaryLabelColor
        view.addSubview(icHint)
        y -= 52

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

        item.view = topAligned(view)
        return item
    }

    // MARK: - About Tab

    private func createAboutTab() -> NSTabViewItem {
        let item = NSTabViewItem()
        item.label = L10n.settingsTabAbout

        let view = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 360))
        var y: CGFloat = 310

        // Название и версия
        let titleLabel = NSTextField(labelWithString: "RuSwitcher")
        titleLabel.font = .boldSystemFont(ofSize: 20)
        titleLabel.frame = NSRect(x: 20, y: y, width: 420, height: 28)
        view.addSubview(titleLabel)
        y -= 25

        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let devTag = Bundle.main.infoDictionary?["RSDevTag"] as? String ?? ""
        let versionLabel = NSTextField(labelWithString: "v\(version)\(devTag) — \(L10n.settingsVersion)")
        versionLabel.frame = NSRect(x: 20, y: y, width: 420, height: 20)
        versionLabel.font = .systemFont(ofSize: 12)
        versionLabel.textColor = .secondaryLabelColor
        view.addSubview(versionLabel)
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

        item.view = topAligned(view)
        return item
    }

    // MARK: - Advanced Tab

    private func createAdvancedTab() -> NSTabViewItem {
        let item = NSTabViewItem()
        item.label = L10n.settingsTabAdvanced

        let view = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 480))
        var y: CGFloat = 430

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
        y -= 47   // → 310, дальше idём по бегущему y

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

        item.view = topAligned(view)
        return item
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

    private func populateTriggerPopup(_ popup: NSPopUpButton) {
        popup.removeAllItems()
        // Имена клавиш не локализуем — это стандартные обозначения Apple.
        let items: [(key: String, title: String)] = [
            ("option", "Option ⌥ (Alt)"),
            ("command", "Command ⌘"),
            ("control", "Control ⌃"),
            ("shift", "Shift ⇧"),
            // Caps Lock убран: нативный перехват нестабилен (HID-дебаунс/тоггл) — см. техдолг.
        ]
        // issue #12: комбо двух модификаторов (привычный по Windows стиль Alt+Shift).
        let comboItems: [(key: String, title: String)] = [
            ("command+shift", "⌘ + ⇧  (Command + Shift)"),
            ("control+shift", "⌃ + ⇧  (Control + Shift)"),
            ("command+option", "⌘ + ⌥  (Command + Option)"),
            ("control+option", "⌃ + ⌥  (Control + Option)"),
        ]
        for it in items {
            popup.addItem(withTitle: it.title)
            popup.menu?.items.last?.representedObject = it.key as NSString
        }
        popup.menu?.addItem(.separator())
        for it in comboItems {
            popup.addItem(withTitle: it.title)
            popup.menu?.items.last?.representedObject = it.key as NSString
        }
        selectItem(in: popup, matching: SettingsManager.shared.triggerKey)
    }

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
    }

    @objc private func layout2Changed(_ sender: NSPopUpButton) {
        SettingsManager.shared.layout2ID = selectedLayoutID(from: sender)
        DynamicKeyMapping.clearCache()
    }

    @objc private func perAppLayoutChanged(_ sender: NSButton) {
        let enabled = sender.state == .on
        SettingsManager.shared.perAppLayout = enabled
        onPerAppLayoutChanged?(enabled)
    }

    @objc private func triggerChanged(_ sender: NSPopUpButton) {
        SettingsManager.shared.triggerKey = (sender.selectedItem?.representedObject as? String) ?? "option"
        onTriggerChanged?()
        // issue #3: «занят триггером» в списке хоткея смены зависит от текущего триггера —
        // пере-populate, иначе метка устареет и можно выбрать хоткей = триггеру (молча мёртвый).
        if let p = switchHotkeyPopup { populateSwitchHotkeyPopup(p) }
        if let p = caseHotkeyPopup { populateCaseHotkeyPopup(p) }   // issue #29: та же логика для хоткея регистра
    }

    /// issue #14: попап второго хоткея — «Выключен» + те же модификаторы/комбо (без Caps Lock).
    private func populateSwitchHotkeyPopup(_ popup: NSPopUpButton) {
        popup.removeAllItems()
        popup.addItem(withTitle: L10n.settingsSwitchHotkeyOff)
        popup.menu?.items.last?.representedObject = "" as NSString
        popup.menu?.addItem(.separator())
        let items: [(key: String, title: String)] = [
            ("option", "Option ⌥ (Alt)"),
            ("command", "Command ⌘"),
            ("control", "Control ⌃"),
            ("shift", "Shift ⇧"),
        ]
        let comboItems: [(key: String, title: String)] = [
            ("command+shift", "⌘ + ⇧  (Command + Shift)"),
            ("control+shift", "⌃ + ⇧  (Control + Shift)"),
            ("command+option", "⌘ + ⌥  (Command + Option)"),
            ("control+option", "⌃ + ⌥  (Control + Option)"),
        ]
        for it in items {
            popup.addItem(withTitle: it.title)
            popup.menu?.items.last?.representedObject = it.key as NSString
        }
        popup.menu?.addItem(.separator())
        for it in comboItems {
            popup.addItem(withTitle: it.title)
            popup.menu?.items.last?.representedObject = it.key as NSString
        }
        // Пункт, совпадающий с триггером конверсии, гасим: движок его всё равно
        // игнорирует (один тап не должен делать два действия) — не даём выбрать
        // «мёртвую» настройку без индикации (ревью-находка).
        popup.autoenablesItems = false
        let triggerKey = SettingsManager.shared.triggerKey
        for item in popup.menu?.items ?? [] where (item.representedObject as? String) == triggerKey {
            item.isEnabled = false
            // issue #20: не оставлять пункт немым серым — объяснить, что он занят триггером.
            item.title += L10n.settingsSwitchHotkeyBusy
            item.toolTip = L10n.settingsSwitchHotkeyBusy
        }
        let current = SettingsManager.shared.switchHotkey
        if let idx = popup.menu?.items.firstIndex(where: { ($0.representedObject as? String) == current }) {
            popup.selectItem(at: idx)
        } else {
            popup.selectItem(at: 0)
        }
    }

    @objc private func switchHotkeyChanged(_ sender: NSPopUpButton) {
        SettingsManager.shared.switchHotkey = (sender.selectedItem?.representedObject as? String) ?? ""
        onTriggerChanged?()   // reconfigure перечитает и switchConfig
        if let p = caseHotkeyPopup { populateCaseHotkeyPopup(p) }   // issue #29: хоткей регистра не должен совпасть со сменой раскладки
    }

    /// issue #29: список хоткеев смены регистра. Гасим совпадения с триггером И с хоткеем смены
    /// раскладки — движок их всё равно игнорирует (один тап = одно действие).
    private func populateCaseHotkeyPopup(_ popup: NSPopUpButton) {
        populateSwitchHotkeyPopup(popup)   // те же пункты
        popup.autoenablesItems = false
        let taken: Set<String> = [SettingsManager.shared.triggerKey, SettingsManager.shared.switchHotkey]
        for item in popup.menu?.items ?? [] {
            let key = (item.representedObject as? String) ?? ""
            if !key.isEmpty && taken.contains(key) {
                item.isEnabled = false
                if !item.title.hasSuffix(L10n.settingsSwitchHotkeyBusy) { item.title += L10n.settingsSwitchHotkeyBusy }
            }
        }
        let current = SettingsManager.shared.caseHotkey
        if let idx = popup.menu?.items.firstIndex(where: { ($0.representedObject as? String) == current }) {
            popup.selectItem(at: idx)
        } else {
            popup.selectItem(at: 0)
        }
    }

    @objc private func caseHotkeyChanged(_ sender: NSPopUpButton) {
        SettingsManager.shared.caseHotkey = (sender.selectedItem?.representedObject as? String) ?? ""
        onTriggerChanged?()
    }

    @objc private func caseDoubleTapChanged(_ sender: NSButton) {
        SettingsManager.shared.caseDoubleTap = sender.state == .on
        onTriggerChanged?()
    }

    @objc private func caseRightOnlyChanged(_ sender: NSButton) {
        SettingsManager.shared.caseRightOnly = sender.state == .on
        onTriggerChanged?()
    }

    @objc private func switchDoubleTapChanged(_ sender: NSButton) {
        SettingsManager.shared.switchDoubleTap = sender.state == .on
        onTriggerChanged?()
    }

    @objc private func switchRightOnlyChanged(_ sender: NSButton) {
        SettingsManager.shared.switchRightOnly = sender.state == .on
        onTriggerChanged?()
    }

    @objc private func triggerRightOnlyChanged(_ sender: NSButton) {
        SettingsManager.shared.triggerRightOnly = sender.state == .on
        onTriggerChanged?()
    }

    @objc private func triggerDoubleTapChanged(_ sender: NSButton) {
        SettingsManager.shared.triggerDoubleTap = sender.state == .on
        onTriggerChanged?()
    }

    @objc private func autoConvertChanged(_ sender: NSButton) {
        let enabled = sender.state == .on
        SettingsManager.shared.autoConvert = enabled
        instantConvertCheckbox?.isEnabled = enabled
        onAutoConvertChanged?(enabled)
    }

    @objc private func instantConvertChanged(_ sender: NSButton) {
        SettingsManager.shared.instantConvert = sender.state == .on
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
