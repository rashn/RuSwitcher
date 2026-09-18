import AppKit
import ApplicationServices

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let keyboardMonitor = KeyboardMonitor()
    private let textConverter = TextConverter()
    private let settingsController = SettingsWindowController()
    private let perAppLayoutManager = PerAppLayoutManager()
    private var permissionCheckTimer: Timer?
    private var iconRefreshTimer: Timer?
    private var updateCheckTimer: Timer?   // периодическая авто-проверка обновлений, пока приложение работает
    private var monitoringActive = false
    private var caretIndicator: CaretIndicator?   // issue #10: флаг у каретки (бета, по умолчанию OFF)
    private let secureNotice = SecureInputNotice()  // issue #27: подсказка о защ. вводе без кражи фокуса
    private var lastFlagShown: String?            // идентичность раскладки для детекта смены (не title!)
    private var badgeCache: [String: NSImage] = [:]  // монохромные плашки, чтобы не перерисовывать 2с-опросом

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        setupSettingsCallbacks()
        syncLoginItem()
        // «Запускались раньше?» снимаем ДО визарда: он через startMonitoring →
        // offerLaunchAtLoginIfNeeded выставляет launchAtLoginAsked уже на этом же
        // первом запуске, иначе «Что нового» ложно показалось бы на свежей установке.
        let ranBefore = SettingsManager.shared.launchAtLoginAsked
        runPermissionWizard()
        showWhatsNewIfNeeded(hasRunBefore: ranBefore)
        showBetaWhatsNewIfNeeded()   // отдельная витрина для бет (текст из бета-фида)
        UpdateChecker.checkOnLaunch()
        // Периодическая авто-проверка обновлений, пока приложение работает (не только на старте).
        // Тикает каждые 6ч; сам запрос к GitHub не чаще раза в сутки (троттл в UpdateChecker) и
        // уважает настройку «Автоматически проверять обновления» (её можно снять, чтобы отключить).
        updateCheckTimer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { _ in
            Task { @MainActor in UpdateChecker.checkPeriodic() }
        }
        // Прогрев NSSpellChecker: первый чек поднимает XPC AppleSpell (сотни мс на main) —
        // прогреваем в тихую паузу после старта, а не на первом пробеле пользователя.
        // Заодно разворачиваем таблицы буквосочетаний: разбор base64 дешёвый, но пусть он
        // случится тут, а не на первой букве, набранной пользователем.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            Task { @MainActor in
                Dict.warmUp()
                InstantDetector.warmUp()
                // Языковые паки для конверсии на лету: в бинаре данных нет, поэтому если фича
                // включена — досматриваем, что паки на месте и не устарели. Сверка с манифестом
                // троттлится сутками, так что обычный запуск в сеть не ходит.
                if SettingsManager.shared.instantConvert,
                   let langs = InstantTablesUpdater.languagesForCurrentPair() {
                    InstantTablesUpdater.ensurePacks(for: langs, force: false)
                }
            }
        }
    }

    private func setupSettingsCallbacks() {
        settingsController.onAutoSwitchChanged = { [weak self] _ in
            // Не адресуем пункт по индексу: с 2.5.0 item(at: 0) — строка версии, а со списком
            // раскладок индексы вообще динамические. Пересборка — как у соседних колбэков.
            self?.rebuildMenu()
        }
        settingsController.onPerAppLayoutChanged = { [weak self] enabled in
            guard let self else { return }
            if enabled {
                self.startPerAppLayout()
            } else {
                self.perAppLayoutManager.stop()
            }
        }
        settingsController.onLanguageChanged = { [weak self] in
            self?.rebuildMenu()
        }
        settingsController.onTriggerChanged = { [weak self] in
            self?.reconfigureTap()
        }
        settingsController.onAutoConvertChanged = { [weak self] _ in
            self?.rebuildMenu()  // синхронизировать галочку в меню
        }
        settingsController.onRemoteDesktopChanged = { [weak self] _ in
            self?.reconfigureTap()  // уровень tap зависит от режима
            self?.rebuildMenu()
        }
        settingsController.onCaretFlagChanged = { [weak self] _ in
            self?.rebuildMenu()          // синхронизировать галочку в меню
            self?.syncCaretIndicator()   // создать/снести индикатор + обновить гейт onUserInput
        }
    }

    // MARK: - Learn-from-undo (предложить добавить слово в never-convert)

    /// Последняя авто-конвертация: слово (как было набрано) + время. Если пользователь
    /// сразу откатывает ручным триггером — предлагаем занести слово в исключения.
    private var lastAutoConverted: (word: String, at: Date)?
    /// Анти-наг: за сессию про одно слово спрашиваем один раз.
    private var offeredExceptionWords: Set<String> = []

    /// Анти-наг для уведомления о защищённом вводе (не чаще раза в N секунд).
    private var lastSecureNoticeAt: Date?

    /// Ручной триггер нажат, но активен защищённый ввод (фокус в поле пароля — часто во
    /// вкладке браузера в фоне) → конверсия by design не трогает клавиши. Без подсказки это
    /// выглядит как «приложение сломалось» (реальный кейс: пользователь мял триггер и лез в
    /// ioreg). Показываем разовое (троттлённое) объяснение с лечением.
    private func notifySecureInputPaused() {
        guard SettingsManager.shared.secureInputNoticeEnabled else { return }
        if let last = lastSecureNoticeAt, Date().timeIntervalSince(last) < 180 { return }
        lastSecureNoticeAt = Date()
        let holder = AutoSwitchPolicy.secureInputHolderName() ?? L10n.securePausedUnknownApp
        // issue #27: неактивирующая плашка вместо NSAlert.runModal() — модалка активировала
        // приложение и уводила фокус из поля пароля (пользователь терял место в терминале).
        secureNotice.show(title: L10n.securePausedTitle,
                          body: String(format: L10n.securePausedBody, holder))
    }

    private func offerExceptionAfterUndo() {
        guard let last = lastAutoConverted, Date().timeIntervalSince(last.at) < 8 else { return }
        lastAutoConverted = nil
        let word = last.word
        let key = word.lowercased()
        guard !offeredExceptionWords.contains(key) else { return }
        offeredExceptionWords.insert(key)
        guard !SettingsManager.shared.deniedWordsSet.contains(key) else { return }

        let alert = NSAlert()
        alert.messageText = L10n.learnQuestion(word)
        alert.addButton(withTitle: L10n.learnAdd)
        alert.addButton(withTitle: L10n.learnNotNow)
        if alert.runModal() == .alertFirstButtonReturn {
            var list = SettingsManager.shared.deniedWords
            list.append(word)
            SettingsManager.shared.deniedWords = list
            rslog("learn: added word (len=\(word.count)) to never-convert")
        }
    }

    private func startPerAppLayout() {
        perAppLayoutManager.onLayoutRestored = { [weak self] in
            self?.keyboardMonitor.markConverted()
            self?.textConverter.clearState()
            self?.updateStatusIcon()
        }
        perAppLayoutManager.start()
    }

    // MARK: - Login Item Sync

    /// Синхронизирует состояние автозагрузки с системой при старте.
    /// Если галочка включена, но Login Item потерян (переустановка/обновление) — перерегистрирует.
    /// Если галочка выключена, но Login Item есть — снимает.
    private func syncLoginItem() {
        let settings = SettingsManager.shared
        let wanted = settings.launchAtLogin
        let status = settings.loginItemStatus

        rslog("Login item sync: wanted=\(wanted) status=\(status.rawValue)")

        if wanted && status != .enabled {
            // Галочка стоит, но Login Item не активен — перерегистрируем
            rslog("Re-registering login item...")
            settings.launchAtLogin = true  // setter вызовет doUpdateLoginItem
        } else if !wanted && status == .enabled {
            // Галочка снята, но Login Item активен — убираем
            rslog("Unregistering stale login item...")
            settings.launchAtLogin = false
        }
    }

    // MARK: - Permission Wizard

    private func runPermissionWizard(interactive: Bool = false) {
        let acc = AXIsProcessTrusted()
        let inp = CGPreflightListenEventAccess()
        rslog("Permissions: accessibility=\(acc) inputMonitoring=\(inp)")

        if acc && inp {
            // Запоминаем что разрешения были даны
            SettingsManager.shared.permissionsWereGranted = true
            if !monitoringActive { startMonitoring() }
            // Ручная проверка из меню должна давать видимый отклик.
            if interactive { showPermissionsOKAlert() }
            return
        }

        // Проверяем: разрешения были раньше, а теперь сброшены (обновление)
        if SettingsManager.shared.permissionsWereGranted {
            rslog("Permissions were previously granted — reset detected after update")
            SettingsManager.shared.permissionsWereGranted = false
            showPermissionsResetAlert()
            return
        }

        // Первый запуск — обычный визард
        if acc {
            showStep_InputMonitoring()
            return
        }

        showStep_Accessibility()
    }

    /// Подтверждение при ручной проверке, когда все разрешения уже выданы
    private func showPermissionsOKAlert() {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = L10n.permissionsOkTitle
        alert.informativeText = L10n.permissionsOkText
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    /// Уведомление о сбросе разрешений после обновления
    private func showPermissionsResetAlert() {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = L10n.wizardPermissionsResetTitle
        alert.informativeText = L10n.wizardPermissionsResetText
        alert.addButton(withTitle: "OK")
        alert.runModal()

        // Сбрасываем старые записи через tccutil
        resetPermissions()

        // Запрашиваем заново
        showStep_Accessibility()
    }

    /// Сбрасывает старые записи разрешений для нашего bundle ID
    private func resetPermissions() {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.ruswitcher.app"
        rslog("Resetting TCC entries for \(bundleID)")

        for service in ["Accessibility", "ListenEvent"] {
            let reset = Process()
            reset.launchPath = "/usr/bin/tccutil"
            reset.arguments = ["reset", service, bundleID]
            try? reset.run()
            reset.waitUntilExit()
        }

        rslog("TCC entries reset done")
    }

    private func showStep_Accessibility() {
        // AXIsProcessTrustedWithOptions с prompt=true показывает системный диалог
        // и добавляет программу в список Accessibility автоматически
        let options = ["AXTrustedCheckOptionPrompt" as CFString: true as CFBoolean] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)

        permissionCheckTimer?.invalidate()
        permissionCheckTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if AXIsProcessTrusted() {
                    rslog("Accessibility granted!")
                    self.permissionCheckTimer?.invalidate()
                    self.permissionCheckTimer = nil
                    self.showStep_InputMonitoring()
                }
            }
        }
    }

    private func showStep_InputMonitoring() {
        // CGRequestListenEventAccess() показывает системный диалог и добавляет
        // программу в список Input Monitoring автоматически
        let preflightOK = CGPreflightListenEventAccess()
        rslog("Preflight check = \(preflightOK)")

        if preflightOK {
            // Уже есть — сразу запускаем
            SettingsManager.shared.permissionsWereGranted = true
            startMonitoring()
            return
        }

        rslog("Requesting access...")
        CGRequestListenEventAccess()

        permissionCheckTimer?.invalidate()
        permissionCheckTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if CGPreflightListenEventAccess() {
                    rslog("Input Monitoring granted! Restarting...")
                    SettingsManager.shared.permissionsWereGranted = true
                    self.permissionCheckTimer?.invalidate()
                    self.permissionCheckTimer = nil
                    self.restartApp()
                }
            }
        }
    }

    private func restartApp() {
        rslog("Restarting from: \(Bundle.main.bundlePath)")
        AppRelauncher.relaunch()
    }

    // MARK: - Start Monitoring

    private func startMonitoring() {
        permissionCheckTimer?.invalidate()
        permissionCheckTimer = nil

        if !keyboardMonitor.start(
            onAltTap: { [weak self] in
                guard let self else { return }
                guard SettingsManager.shared.autoSwitchEnabled else { return }
                // Приватность: в защищённом поле (пароль) ничего не делаем — ставим ДО
                // remote-defer, чтобы поведение точно совпадало с handleAutoConvert.
                guard !AutoSwitchPolicy.secureInputActive else { rslog("trigger: bail secure-input"); self.notifySecureInputPaused(); return }
                if AutoSwitchPolicy.shouldDeferToRemoteClient {
                    // Удалёнка: текст конвертит офисный инстанс по реальным проброшенным символам
                    // (Fix №6). А здесь меняем СВОЮ раскладку — чтобы дальнейший ввод пошёл уже
                    // в правильной раскладке и не пришлось конвертить каждое слово.
                    LayoutSwitcher.switchToOpposite()
                    self.updateStatusIcon()
                    rslog("trigger: local layout switched, conversion handled by controlled instance")
                    return
                }
                // issue #16: в Spotlight обычный путь оставляет лишнюю букву (серое
                // автодополнение съедает Backspace). Особый путь: Cmd+A + буфер, без
                // Backspace. Гейт isActive() строгий (окно видимо + Spotlight держит поле),
                // поэтому здесь мы ТОЧНО в Spotlight — конвертим только своим путём и НЕ
                // проваливаемся в буфер/count-пути (они тут дают лишнюю букву), что бы
                // convertSpotlight ни вернул.
                if SpotlightAX.isActive() {
                    if self.textConverter.convertSpotlight() {
                        self.keyboardMonitor.markConverted()
                        LayoutSwitcher.switchToOpposite()
                        self.updateStatusIcon()
                        self.lastAutoConverted = nil
                    }
                    return
                }
                // issue #24: режим «вся строка».
                if SettingsManager.shared.convertWholeLine {
                    let frontID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
                    if AutoSwitchPolicy.isTerminalApp(frontID) {
                        // Терминал: нет OS-выделения → перепечатываем строку по буферу нажатий.
                        // НЕПУСТОЙ буфер (в т.ч. no-op на уже верной строке) завершаем ЗДЕСЬ и НЕ
                        // проваливаемся на последнее слово — иначе безусловный флип испортил бы
                        // верное слово, напр. «git log»→«git дщп» (скептик 3.2.0). На слово падаем
                        // только при ПУСТОМ/сброшенном буфере (пунктуация/Enter/сдвиг курсора).
                        if !self.keyboardMonitor.lineKeys.isEmpty {
                            if self.textConverter.convertLineBuffer(self.keyboardMonitor.lineKeys) {
                                self.keyboardMonitor.markConverted()
                                LayoutSwitcher.switchToOpposite()
                                self.updateStatusIcon()
                                self.lastAutoConverted = nil
                            }
                            return
                        }
                    } else {
                        // Обычные приложения: сами выделяем строку (Shift+Cmd+←) и конвертируем.
                        if self.textConverter.convertLine() {
                            self.keyboardMonitor.markConverted()
                            LayoutSwitcher.switchToOpposite()
                            self.updateStatusIcon()
                            self.lastAutoConverted = nil
                        }
                        return   // whole-line в обычной проге — всегда завершаем (не last-word)
                    }
                }
                let keys = self.keyboardMonitor.currentWordKeys
                let prevKeys = self.keyboardMonitor.prevWordKeys
                let bc = self.keyboardMonitor.boundaryCount
                if self.textConverter.convert(wordKeys: keys, prevWordKeys: prevKeys, boundaryCount: bc) {
                    self.keyboardMonitor.markConverted()
                    LayoutSwitcher.switchToOpposite()
                    self.updateStatusIcon()
                    self.lastAutoConverted = nil
                }
            },
            onAltReconvert: { [weak self] in
                guard let self else { return }
                guard SettingsManager.shared.autoSwitchEnabled else { return }
                guard !AutoSwitchPolicy.secureInputActive else { rslog("reconvert: bail secure-input"); self.notifySecureInputPaused(); return }
                if AutoSwitchPolicy.shouldDeferToRemoteClient {
                    // Удалёнка: текст конвертит офисный инстанс по реальным проброшенным символам
                    // (Fix №6). А здесь меняем СВОЮ раскладку — чтобы дальнейший ввод пошёл уже
                    // в правильной раскладке и не пришлось конвертить каждое слово.
                    LayoutSwitcher.switchToOpposite()
                    self.updateStatusIcon()
                    rslog("trigger: local layout switched, conversion handled by controlled instance")
                    return
                }
                // issue #16: в Spotlight реконверт — тот же путь (Cmd+A + буфер), он
                // реверсивен (конвертит текущее содержимое обратно). НЕ проваливаемся в
                // count-based reconvert() в Spotlight (skeptic: он вайпит буфер и селектит
                // по счётчику — ровно то, чего избегаем).
                if SpotlightAX.isActive() {
                    if self.textConverter.convertSpotlight() {
                        self.keyboardMonitor.markConverted()
                        LayoutSwitcher.switchToOpposite()
                        self.updateStatusIcon()
                    }
                    return
                }
                if self.textConverter.reconvert() {
                    self.keyboardMonitor.markConverted()
                    LayoutSwitcher.switchToOpposite()
                    self.updateStatusIcon()
                    self.offerExceptionAfterUndo()
                }
            }
        ) {
            rslog("Event tap failed - will retry in 5s")
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                self?.startMonitoring()
            }
            return
        }

        monitoringActive = true
        keyboardMonitor.onWordBoundary = { [weak self] in
            self?.handleAutoConvert()
        }
        keyboardMonitor.onTypingLetter = { [weak self] in
            self?.handleInstantConvert()
        }
        keyboardMonitor.onUserInput = { [weak self] in self?.caretIndicator?.userTyped() }  // issue #10
        // issue #14: хоткей чистого переключения раскладки (без конверсии). Буфер после
        // явной смены раскладки неактуален — тот же паттерн, что per-app restore и меню.
        keyboardMonitor.onSwitchHotkey = { [weak self] in
            guard let self, SettingsManager.shared.autoSwitchEnabled else { return }
            if AutoSwitchPolicy.shouldDeferToRemoteClient {
                // Удалёнка (фокус в клиенте Screen Sharing): переключаем только СВОЮ
                // раскладку, как defer-ветка триггера. markConverted/clearState тут лишние —
                // буфер наполняется через handleForwardedChar, а проброшенные модификаторы
                // сами переключат раскладку на контролируемой машине.
                LayoutSwitcher.switchToOpposite()
                self.updateStatusIcon()
                rslog("switch hotkey: local layout switched (remote client focused)")
                return
            }
            LayoutSwitcher.switchToOpposite()
            self.keyboardMonitor.markConverted()
            self.textConverter.clearState()
            self.updateStatusIcon()
        }
        // issue #29: хоткей смены регистра последнего слова / выделения. Раскладку не трогает,
        // в защищённом поле — пас (приватность), как у триггера.
        keyboardMonitor.onCaseHotkey = { [weak self] in
            guard let self else { return }
            guard !AutoSwitchPolicy.secureInputActive else { rslog("case: bail secure-input"); self.notifySecureInputPaused(); return }
            // Скептик #29: те же гейты, что у onAltTap/onSwitchHotkey. Удалёнка — текст правит
            // контролируемый инстанс (у нас нет своей раскладки для флипа, регистр просто пропускаем).
            if AutoSwitchPolicy.shouldDeferToRemoteClient { rslog("case: bail remote-defer"); return }
            // Spotlight: count-путь оставил бы лишнюю букву (issue #16), а AX там флейкует — не трогаем.
            if SpotlightAX.isActive() { rslog("case: bail spotlight"); return }
            // issue #29: смена регистра зеркалит триггер конверсии — уважает «Convert whole line»
            // (запрос kobygold). Терминал → по буферу строки; обычное приложение → AX-выделение строки.
            if SettingsManager.shared.convertWholeLine {
                let frontID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
                if AutoSwitchPolicy.isTerminalApp(frontID) {
                    if !self.keyboardMonitor.lineKeys.isEmpty {
                        if self.textConverter.changeCaseLineBuffer(self.keyboardMonitor.lineKeys) { self.textConverter.clearState() }
                        return   // непустой буфер строки — завершаем здесь (как onAltTap)
                    }
                    // пустой буфер → падаем на последнее слово ниже
                } else {
                    if self.textConverter.changeCaseLine() { self.textConverter.clearState() }
                    return   // обычное приложение, whole-line — всегда завершаем здесь
                }
            }
            // Скептик #29: НЕ markConverted() — буфер слова нужен, чтобы повторный тап циклил
            // регистр. Чистим reconvert-состояние, иначе следующий реконверт сработал бы по
            // устаревшим lastOriginal/lastConverted и испортил текст.
            let keys = self.keyboardMonitor.currentWordKeys
            if self.textConverter.changeCase(wordKeys: keys) {
                self.textConverter.clearState()
            }
        }
        updateStatusIcon()        // сначала выставляем флаг меню-бара, пока индикатора ещё нет
        syncCaretIndicator()      // затем создаём индикатор — без стартового ложного «попа»
        // Страховка к issue #9: системное уведомление о смене раскладки ненадёжно
        // (особенно через удалённый стол — на той машине оно часто не доходит), поэтому
        // флаг «застревает». Постоянный лёгкий опрос держит иконку в синхроне с системой.
        iconRefreshTimer?.invalidate()
        iconRefreshTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateStatusIcon() }
        }
        rslog("Monitoring started successfully")

        if SettingsManager.shared.perAppLayout {
            startPerAppLayout()
        }

        // Предлагаем автозагрузку и автозамену при первом запуске (по разу)
        offerLaunchAtLoginIfNeeded()
        offerAutoConvertIfNeeded()
    }

    /// Конверсия на лету: то же, что handleAutoConvert, но по НЕЗАКОНЧЕННОМУ слову — не ждём
    /// пробела, а решаем по статистике буквосочетаний (InstantDetector), обычно на 2-3-й букве.
    /// Гейты те же, что у авто-пути, плюс два своих: Spotlight (там стирание по счётчику ест
    /// лишнюю букву, issue #16) и удалёнка (латентность Screen Sharing делает посимвольный
    /// путь ненадёжным) — оба отдаём словарному пути на пробеле.
    private func handleInstantConvert() {
        // ПОРЯДОК ПРОВЕРОК ВАЖЕН: этот метод зовётся на КАЖДУЮ набранную букву, поэтому сперва
        // идёт только дешёвое — настройки из памяти, кэшированный маппинг клавиш и сам детектор
        // (чтение битов). Дорогие системные запросы — frontmostApplication (синхронный IPC),
        // secure-input, AX-проба Spotlight — стоят ПОСЛЕ вердикта: их цена платится раз в
        // несколько слов, а не 10 раз в секунду. Иначе фича сама стала бы источником фризов,
        // ради устранения которых затевался этот форк.
        guard SettingsManager.shared.autoSwitchEnabled,
              SettingsManager.shared.autoConvert,
              SettingsManager.shared.instantConvert,
              !SettingsManager.shared.remoteDesktopMode else { return }

        let keys = keyboardMonitor.currentWordKeys
        guard keys.count >= InstantDetector.minLength else { return }
        guard let pair = DynamicKeyMapping.convertKeys(keys) else { return }
        guard let langs = LayoutSwitcher.currentAndOppositeLanguage() else { return }

        let capsLock = keys.contains { $0.caps }
        guard InstantDetector.shouldSwitch(typed: pair.original, converted: pair.converted,
                                           currentLang: langs.current, otherLang: langs.opposite,
                                           capsLock: capsLock) else { return }

        // Детектор сказал «переключить» — вот теперь платим за политики и системные пробы.
        // never-convert проверяем ПО ПРЕФИКСУ: слово ещё набирается, и точное сравнение
        // пропустило бы запрет — «ghbdtn» конвертнулось бы на «ghb», не дойдя до себя.
        if AutoSwitchPolicy.isDeniedPrefix(pair.original, pair.converted) { return }
        guard !AutoSwitchPolicy.secureInputActive else { return }
        if AutoSwitchPolicy.isDeniedApp(NSWorkspace.shared.frontmostApplication?.bundleIdentifier) { return }
        if SpotlightAX.isActive() { return }

        rslog("instant: convert \(keys.count) keys \(langs.current)→\(langs.opposite)")  // слова не логируем (приватность)
        // Сначала пробуем починить хвост фразы: слова перед текущим могли проскочить, пока
        // язык фразы был неясен («dj gfitn» → «во пашет»). Если в голове чинить нечего,
        // метод отказывается, и делаем обычную однословную замену.
        let toCyrillic = SmartConvert.isCyrillic(lang: langs.opposite)
        let converted = textConverter.convertLineTail(lineKeys: keyboardMonitor.lineKeys,
                                                      tailLength: keys.count,
                                                      tailConverted: pair.converted,
                                                      toCyrillic: toCyrillic)
            || textConverter.convert(wordKeys: keys, prevWordKeys: [], boundaryCount: 0)
        if converted {
            keyboardMonitor.markConverted()
            LayoutSwitcher.switchToOpposite()
            updateStatusIcon()
            // lastAutoConverted намеренно НЕ ставим: он кормит предложение «запомнить слово в
            // исключения» после отката, а здесь слово ещё не дописано — в диалог уехал бы
            // огрызок вроде «ghb», да ещё и запретил бы по префиксу все слова на «при».
        }
    }

    /// Авто-конвертация на границе слова: детект неправильной раскладки → конверт + смена.
    /// Точность-first: при любой неуверенности ничего не делаем. Ручной триггер не трогаем.
    private func handleAutoConvert() {
        rslog("auto: fired")
        guard SettingsManager.shared.autoSwitchEnabled else { rslog("auto: bail master-off"); return }
        guard SettingsManager.shared.autoConvert else { rslog("auto: bail flag-off"); return }
        guard !AutoSwitchPolicy.secureInputActive else { rslog("auto: bail secure-input"); return }
        let frontID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        // Удалёнка: НЕ выходим сразу — прогоняем детектор по своему (чистому) буферу, и при
        // «не той раскладке» переключаем СВОЮ раскладку (конверсию делает инстанс на той стороне).
        let deferToRemote = SettingsManager.shared.remoteDesktopMode && AutoSwitchPolicy.isRemoteDesktopClient(frontID)
        if AutoSwitchPolicy.isDeniedApp(frontID) { rslog("auto: bail denied-app \(frontID ?? "?")"); return }
        if let captured = keyboardMonitor.prevWordBundleID, captured != frontID {
            rslog("auto: bail focus-changed"); return  // фокус уехал между пробелом и сейчас
        }

        let allKeys = keyboardMonitor.prevWordKeys
        let bc = keyboardMonitor.boundaryCount
        guard !allKeys.isEmpty else { rslog("auto: bail empty-keys"); return }  // курсор уехал — небезопасно
        guard let fullPair = DynamicKeyMapping.convertKeys(allKeys) else { rslog("auto: bail convertKeys-nil"); return }

        // issue #15: слово с прилипшей пунктуацией ("ghbdtn,") — отщепляем хвост, детектим
        // и конвертим ядро, хвост вернётся в поле литералом. Проверка счёта — инвариант
        // «1 клавиша = 1 символ» обоих путей convertKeys; при слиянии графем не отщепляем.
        var keys = allKeys
        var suffix = ""
        let split = LayoutDetector.splitTrailingPunctuation(fullPair.original)
        if !split.suffix.isEmpty, split.coreLength > 0, fullPair.original.count == allKeys.count {
            keys = Array(allKeys.prefix(split.coreLength))
            suffix = split.suffix
        }
        guard let pair = suffix.isEmpty ? fullPair : DynamicKeyMapping.convertKeys(keys) else {
            rslog("auto: bail convertKeys-nil"); return
        }
        if AutoSwitchPolicy.isDeniedWord(pair.original, pair.converted) { rslog("auto: bail denied-word"); return }

        // Язык для детектора. Для проброшенного через удалёнку текста (все символы — char)
        // направление определяем по СКРИПТУ набранного, а не по раскладке офисной машины:
        // на офисе раскладка может не соответствовать тому, что напечатали на контроллере,
        // и тогда decide ошибочно даёт keep (это и есть «авто в удалёнке не работает»).
        let langs: (current: String, opposite: String)
        if keys.allSatisfy({ $0.char != nil }) {
            let typedIsCyrillic = pair.original.unicodeScalars.contains { $0.value >= 0x0400 && $0.value <= 0x04FF }
            langs = typedIsCyrillic ? ("ru", "en") : ("en", "ru")
        } else if let l = LayoutSwitcher.currentAndOppositeLanguage() {
            langs = l
        } else {
            rslog("auto: bail langs-nil"); return
        }

        // Ревью-находка (#15): '.', ',', ';', ':' в EN — клавиши букв ю/б/ж/Ж в ЙЦУКЕН,
        // поэтому начало «хвоста» в целевой раскладке может оказаться буквами, а ядро +
        // эти буквы — словарным словом: «levf.» → «думаю», «levf.!» → «думаю!». Идём по
        // буквенному расширению ядра в полной конверсии и проверяем каждый префикс по
        // словарю: первое словарное расширение = неоднозначность («думаю» vs «дума.») →
        // точность важнее полноты, не делаем НИЧЕГО (ручной триггер конвертирует целиком).
        // Первая не-буква — стоп: дальше хвост пунктуация и в целевой раскладке,
        // двусмысленности нет. NSSpellChecker токенизирует («привет!» для него валиден),
        // поэтому проверять полную конверсию целиком нельзя — только буквенные префиксы.
        // Для пар с ивритом walk не нужен: направление «в иврит» авто-путём не конвертится
        // by design (см. иврит-ветку decide), а ивритский словарь принимает любые буквы —
        // walk дал бы бессмысленный bail на первом же шаге и мусорную строку в логе.
        if !suffix.isEmpty, !LayoutDetector.isHebrew(langs.opposite), Dict.isAvailable(langs.opposite) {
            let oth = String(langs.opposite.prefix(2))
            let fullConv = Array(fullPair.converted)
            var candidate = String(fullConv[..<split.coreLength])
            for ch in fullConv[split.coreLength...] {
                guard ch.isLetter else { break }
                candidate.append(ch)
                if Dict.isValidWord(candidate.lowercased(), lang: oth) {
                    rslog("auto: bail ambiguous-suffix")
                    return
                }
            }
        }

        let capsLock = keys.contains { $0.caps }
        let verdict = LayoutDetector.decide(typed: pair.original, converted: pair.converted,
                                            currentLang: langs.current, otherLang: langs.opposite,
                                            capsLock: capsLock)
        rslog("auto: len=\(pair.original.count) \(langs.current)/\(langs.opposite) verdict=\(verdict)")  // слова не логируем (приватность)
        guard verdict == .switchToConverted else { return }

        if deferToRemote {
            // Удалёнка: текст конвертит офисный инстанс по реальным проброшенным символам.
            // Здесь меняем СВОЮ раскладку — чтобы дальнейший ввод пошёл уже в правильной.
            LayoutSwitcher.switchToOpposite()
            updateStatusIcon()
            rslog("auto: local layout switched, conversion handled by controlled instance")
            return
        }

        // issue #16 (авто): в Spotlight стирание по счётчику оставляет лишнюю букву (серое
        // автодополнение ест Backspace). Решение по буферу уже принято верно — меняем только
        // способ замены: по-словное выделение (Shift+Option+Left) + печать поверх, без
        // Backspace. Суффикс-случай (#15) в Spotlight редок и фиддловат — его не трогаем.
        if SpotlightAX.isActive() {
            if suffix.isEmpty,
               textConverter.convertSpotlightWord(converted: pair.converted, boundaryCount: bc) {
                keyboardMonitor.markConverted()
                keyboardMonitor.allowNextWord()   // слово закончено пробелом — следующее судим заново
                LayoutSwitcher.switchToOpposite()
                updateStatusIcon()
                lastAutoConverted = (pair.original, Date())
            }
            return   // Spotlight: обычный count-путь неприменим
        }

        rslog("auto: convert \(keys.count) keys (+\(suffix.count) punct, +\(bc) sp)")
        if textConverter.convert(wordKeys: [], prevWordKeys: keys, boundaryCount: bc,
                                 passthroughSuffix: suffix) {
            keyboardMonitor.markConverted()
            keyboardMonitor.allowNextWord()   // слово закончено пробелом — следующее судим заново
            LayoutSwitcher.switchToOpposite()
            updateStatusIcon()
            lastAutoConverted = (pair.original, Date())
        }
    }

    /// Предлагает включить автозагрузку при первом запуске (один раз)
    private func offerLaunchAtLoginIfNeeded() {
        let settings = SettingsManager.shared
        guard !settings.launchAtLoginAsked else { return }
        settings.launchAtLoginAsked = true

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = L10n.wizardLaunchAtLoginTitle
        alert.informativeText = L10n.wizardLaunchAtLoginText
        alert.addButton(withTitle: L10n.wizardYes)
        alert.addButton(withTitle: L10n.wizardNo)

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            settings.launchAtLogin = true
            rslog("User enabled launch at login")
        } else {
            rslog("User declined launch at login")
        }
    }

    /// Предлагает включить автозамену при первом запуске (один раз). Фича OFF по умолчанию,
    /// поэтому без явного предложения пользователь о ней не узнает.
    private func offerAutoConvertIfNeeded() {
        let settings = SettingsManager.shared
        guard !settings.autoConvertOffered else { return }
        settings.autoConvertOffered = true

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = L10n.onboardAutoConvertTitle
        alert.informativeText = L10n.onboardAutoConvertText
        alert.addButton(withTitle: L10n.wizardYes)
        alert.addButton(withTitle: L10n.wizardNo)

        if alert.runModal() == .alertFirstButtonReturn {
            settings.autoConvert = true
            rebuildMenu()  // синхронизировать галочку «Автоматическая конверсия» в меню
            rslog("User enabled auto-convert at onboarding")
        } else {
            rslog("User declined auto-convert at onboarding")
        }
    }

    // MARK: - Status Item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        rebuildMenu()
        // issue #9: иконка должна отражать раскладку и при СИСТЕМНОЙ смене (стандартный/
        // переопределённый хоткей), а не только при нашей конверсии. Слушаем системное
        // распределённое уведомление о смене источника ввода.
        // suspensionBehavior: .deliverImmediately — иначе для фонового menu-bar-приложения
        // распределённое уведомление коалесцируется/откладывается (App Nap / suspend), и
        // иконка после переключения глобусом 🌐 меняется с задержкой до нескольких секунд
        // (ждёт пробуждения или 2-секундного опроса). deliverImmediately обновляет флаг сразу.
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(systemInputSourceChanged),
            name: NSNotification.Name("com.apple.Carbon.TISNotifySelectedKeyboardInputSourceChanged"),
            object: nil,
            suspensionBehavior: .deliverImmediately
        )
    }

    @objc private func systemInputSourceChanged() {
        updateStatusIcon()
        keyboardMonitor.soundArmed = true  // issue #7: следующая буква даст звук раскладки
        keyboardMonitor.resetLineBuffer()  // скептик 3.2.0: не декодировать строку старой раскладкой
    }

    /// Собирает меню статус-бара. Вызывается заново при смене языка интерфейса,
    /// иначе пункты меню остаются на старом языке.
    private func rebuildMenu() {
        let menu = NSMenu()

        // Строка версии (с dev-меткой для непубликуемых сборок) — чтобы было видно, какой билд.
        let ver = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let devTag = Bundle.main.infoDictionary?["RSDevTag"] as? String ?? ""
        let verItem = NSMenuItem(title: "RuSwitcher \(ver)\(devTag)", action: nil, keyEquivalent: "")
        verItem.isEnabled = false
        menu.addItem(verItem)
        menu.addItem(NSMenuItem.separator())

        // Список раскладок как в системном меню ввода: флаг + имя, галочка на текущей,
        // клик — переключение. Актуализируется в menuWillOpen при каждом открытии.
        for item in layoutMenuItems() { menu.addItem(item) }
        menu.addItem(NSMenuItem.separator())

        let autoItem = NSMenuItem(title: L10n.menuAutoSwitch, action: #selector(toggleAutoSwitch), keyEquivalent: "")
        autoItem.target = self
        autoItem.state = SettingsManager.shared.autoSwitchEnabled ? .on : .off
        menu.addItem(autoItem)

        let autoConvertItem = NSMenuItem(title: L10n.menuAutoConvert, action: #selector(toggleAutoConvert), keyEquivalent: "")
        autoConvertItem.target = self
        autoConvertItem.state = SettingsManager.shared.autoConvert ? .on : .off
        menu.addItem(autoConvertItem)

        let keySoundItem = NSMenuItem(title: L10n.menuKeySound, action: #selector(toggleKeySound), keyEquivalent: "")
        keySoundItem.target = self
        keySoundItem.state = SettingsManager.shared.keySound ? .on : .off
        menu.addItem(keySoundItem)

        let caretFlagItem = NSMenuItem(title: L10n.menuCaretFlag, action: #selector(toggleCaretFlag), keyEquivalent: "")
        caretFlagItem.target = self
        caretFlagItem.state = SettingsManager.shared.caretFlag ? .on : .off
        menu.addItem(caretFlagItem)

        // Единый стиль меню-бара (Sequoia): монохромная плашка вместо цветного флага.
        let monoIconItem = NSMenuItem(title: L10n.menuMonoIcon, action: #selector(toggleMonoIcon), keyEquivalent: "")
        monoIconItem.target = self
        monoIconItem.state = SettingsManager.shared.monochromeIcon ? .on : .off
        menu.addItem(monoIconItem)

        // Режим удалённого стола отложен в 2.5 — тумблер скрыт за флагом (для тестирования).
        if SettingsManager.shared.showRemoteDesktopBeta {
            let remoteDesktopItem = NSMenuItem(title: L10n.menuRemoteDesktop, action: #selector(toggleRemoteDesktop), keyEquivalent: "")
            remoteDesktopItem.target = self
            remoteDesktopItem.state = SettingsManager.shared.remoteDesktopMode ? .on : .off
            menu.addItem(remoteDesktopItem)
        }

        menu.addItem(NSMenuItem.separator())

        let permItem = NSMenuItem(title: L10n.menuCheckPermissions, action: #selector(recheckPermissions), keyEquivalent: "")
        permItem.target = self
        menu.addItem(permItem)

        let settingsItem = NSMenuItem(title: L10n.menuSettings, action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let updateItem = NSMenuItem(title: L10n.menuCheckUpdates, action: #selector(checkUpdates), keyEquivalent: "")
        updateItem.target = self
        menu.addItem(updateItem)

        menu.addItem(NSMenuItem.separator())

        let donateItem = NSMenuItem(title: L10n.menuDonate, action: #selector(openDonate), keyEquivalent: "")
        donateItem.target = self
        menu.addItem(donateItem)

        let starItem = NSMenuItem(title: L10n.menuStarOnGithub, action: #selector(openGitHub), keyEquivalent: "")
        starItem.target = self
        menu.addItem(starItem)

        let shareItem = NSMenuItem(title: L10n.menuShare, action: nil, keyEquivalent: "")
        shareItem.submenu = buildShareSubmenu()
        menu.addItem(shareItem)

        let contactItem = NSMenuItem(title: L10n.menuContactDeveloper, action: #selector(openContactEmail), keyEquivalent: "")
        contactItem.target = self
        contactItem.image = NSImage(systemSymbolName: "envelope", accessibilityDescription: nil)
        menu.addItem(contactItem)

        if !SettingsManager.telegramChatURL.isEmpty {
            let tgItem = NSMenuItem(title: L10n.menuTelegramSupport, action: #selector(openTelegramSupport), keyEquivalent: "")
            tgItem.target = self
            tgItem.image = NSImage(systemSymbolName: "paperplane", accessibilityDescription: nil)
            menu.addItem(tgItem)
        }

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: L10n.menuQuit, action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        menu.delegate = self
        statusItem.menu = menu
        rslog("Menu (re)built with \(menu.items.count) items")
    }

    // MARK: - Layout list in menu

    /// Метка пунктов-раскладок, чтобы находить и обновлять их группу в меню.
    private static let layoutItemTag = 741

    /// Пункты списка раскладок: «флаг + локализованное имя», галочка на текущей.
    private func layoutMenuItems() -> [NSMenuItem] {
        let currentID = LayoutSwitcher.currentLayoutID()
        return LayoutSwitcher.installedLayouts().map { source in
            let id = LayoutSwitcher.sourceID(source)
            let badge = LayoutSwitcher.languageCode(source).map(Self.flagBadge(forLanguage:))
            let title = [badge, LayoutSwitcher.sourceName(source)].compactMap { $0 }.joined(separator: " ")
            let item = NSMenuItem(title: title, action: #selector(selectLayout(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = id
            item.state = (id == currentID) ? .on : .off
            item.tag = Self.layoutItemTag
            return item
        }
    }

    /// Пересобирает группу раскладок при каждом открытии меню: состав и галочка должны
    /// отражать систему на момент клика (раскладки добавляют/удаляют в настройках ОС,
    /// а текущую меняют и мимо нас — системным хоткеем).
    func menuWillOpen(_ menu: NSMenu) {
        guard menu === statusItem.menu else { return }
        let insertAt = menu.items.firstIndex { $0.tag == Self.layoutItemTag } ?? 2
        for old in menu.items where old.tag == Self.layoutItemTag { menu.removeItem(old) }
        for (offset, item) in layoutMenuItems().enumerated() {
            menu.insertItem(item, at: insertAt + offset)
        }
    }

    @objc private func selectLayout(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              id != LayoutSwitcher.currentLayoutID() else { return }
        LayoutSwitcher.switchTo(layoutID: id)
        // Явная смена раскладки делает набранный буфер неактуальным — как при per-app restore.
        keyboardMonitor.markConverted()
        textConverter.clearState()
        updateStatusIcon()
    }

    func updateStatusIcon() {
        let flag = flagForCurrentLayout()
        // Каретку дёргаем ТОЛЬКО при реальной смене раскладки: updateStatusIcon зовётся ещё и
        // 2-секундным опросом-страховкой, иначе флаг у каретки выскакивал бы каждые 2с.
        // Сравниваем по флагу-идентичности, а не по title — в монохромном режиме title пуст.
        let changed = lastFlagShown != flag
        lastFlagShown = flag
        if SettingsManager.shared.monochromeIcon {
            statusItem.button?.title = ""
            statusItem.button?.image = badgeImage(for: currentBadgeLabel())
        } else {
            statusItem.button?.image = nil
            statusItem.button?.title = flag
        }
        if changed { caretIndicator?.layoutChanged() }
    }

    /// Подпись монохромной плашки — родная аббревиатура языка, как у системного индикатора.
    private func currentBadgeLabel() -> String {
        if let lang = LayoutSwitcher.currentLanguageCode()?.lowercased(), !lang.isEmpty {
            // 'iw' — устаревший код иврита: нормализуем, как и flagBadge.
            let code = LayoutDetector.isHebrew(lang) ? "he" : String(lang.prefix(2))
            let labels: [String: String] = [
                "ru": "РУ", "en": "EN", "uk": "УК", "be": "БЕ",
                "de": "DE", "fr": "FR", "es": "ES", "it": "IT",
                "pt": "PT", "pl": "PL", "ja": "あ", "zh": "拼", "ko": "한",
                "he": "עב",   // иврит (3.0)
                "el": "ΕΛ", "bg": "БГ", "hy": "ՀԱ", "ka": "ქა",
            ]
            return labels[code] ?? code.uppercased()
        }
        // Язык раскладки недоступен — мягкий фолбэк по ID (как у flagForCurrentLayout).
        let id = LayoutSwitcher.currentLayoutID().lowercased()
        return (id.contains("russian") || id.hasSuffix(".ru")) ? "РУ" : "EN"
    }

    /// Монохромная плашка в стиле системного индикатора раскладки Sequoia: скруглённый
    /// прямоугольник с «выбитыми» буквами. Template-image — система сама красит её под
    /// светлый/тёмный меню-бар и пользовательский тинт.
    private func badgeImage(for label: String) -> NSImage {
        if let cached = badgeCache[label] { return cached }
        let font = NSFont.systemFont(ofSize: 10, weight: .bold)
        let textSize = label.size(withAttributes: [.font: font])
        let size = NSSize(width: max(ceil(textSize.width) + 8, 20), height: 15)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 3.5, yRadius: 3.5).fill()
            // Буквы «выбиваются» из плашки (прозрачные), как у системного индикатора.
            NSGraphicsContext.current?.cgContext.setBlendMode(.destinationOut)
            label.draw(at: NSPoint(x: (rect.width - textSize.width) / 2,
                                   y: (rect.height - textSize.height) / 2),
                       withAttributes: [.font: font, .foregroundColor: NSColor.white])
            return true
        }
        image.isTemplate = true
        badgeCache[label] = image
        return image
    }

    /// Флаг текущей раскладки по коду языка (BCP-47), а не по подстроке в ID — иначе
    /// "Belarusian" ложно матчил "ru", а любая не-RU/EN пара показывалась как 🇺🇸.
    func flagForCurrentLayout() -> String {
        guard let lang = LayoutSwitcher.currentLanguageCode()?.lowercased(), !lang.isEmpty else {
            // Язык раскладки недоступен — мягкий фолбэк по ID.
            let id = LayoutSwitcher.currentLayoutID().lowercased()
            return (id.contains("russian") || id.hasSuffix(".ru")) ? "🇷🇺" : "🇺🇸"
        }
        return Self.flagBadge(forLanguage: lang)
    }

    /// Единый бейдж раскладки для иконки меню-бара и списка раскладок в меню:
    /// «🇷🇺» для известных языков, иначе код («EL»).
    private static func flagBadge(forLanguage lang: String) -> String {
        // Иврит может прийти устаревшим кодом 'iw' — движок его понимает (isHebrew),
        // индикация должна тоже, иначе в баре будет «IW» вместо 🇮🇱.
        let code = LayoutDetector.isHebrew(lang) ? "he" : String(lang.lowercased().prefix(2))
        let flags: [String: String] = [
            "ru": "🇷🇺", "en": "🇺🇸", "uk": "🇺🇦", "be": "🇧🇾",
            "de": "🇩🇪", "fr": "🇫🇷", "es": "🇪🇸", "it": "🇮🇹",
            "pt": "🇵🇹", "pl": "🇵🇱", "ja": "🇯🇵", "zh": "🇨🇳", "ko": "🇰🇷",
            "he": "🇮🇱",   // иврит (3.0). Арабский в 3.1 — глифом ع (флага нет), см. дизайн 3.0.
        ]
        return flags[code] ?? code.uppercased()
    }

    /// issue #10: создаёт/освобождает индикатор каретки по флагу настроек. Создаётся лениво,
    /// только когда фича включена И мониторинг запущен (нужны разрешения).
    private func syncCaretIndicator() {
        keyboardMonitor.caretFlagEnabled = SettingsManager.shared.caretFlag   // гейт диспатча onUserInput
        if SettingsManager.shared.caretFlag, monitoringActive {
            if caretIndicator == nil {
                let ci = CaretIndicator()
                ci.flagProvider = { [weak self] in self?.flagForCurrentLayout() ?? "" }
                caretIndicator = ci
            }
        } else {
            caretIndicator?.teardown()
            caretIndicator = nil
        }
    }

    // MARK: - Actions

    @objc private func toggleAutoSwitch(_ sender: NSMenuItem) {
        SettingsManager.shared.autoSwitchEnabled.toggle()
        let enabled = SettingsManager.shared.autoSwitchEnabled
        sender.state = enabled ? .on : .off
        settingsController.updateAutoSwitchState(enabled)
    }

    @objc private func toggleAutoConvert(_ sender: NSMenuItem) {
        SettingsManager.shared.autoConvert.toggle()
        sender.state = SettingsManager.shared.autoConvert ? .on : .off
        settingsController.updateAutoConvertState(SettingsManager.shared.autoConvert)   // #4
    }

    @objc private func toggleKeySound(_ sender: NSMenuItem) {
        SettingsManager.shared.keySound.toggle()
        sender.state = SettingsManager.shared.keySound ? .on : .off
    }

    @objc private func toggleCaretFlag(_ sender: NSMenuItem) {
        SettingsManager.shared.caretFlag.toggle()
        sender.state = SettingsManager.shared.caretFlag ? .on : .off
        settingsController.updateCaretFlagState(SettingsManager.shared.caretFlag)
        syncCaretIndicator()   // создать/снести индикатор и обновить гейт onUserInput
    }

    @objc private func toggleMonoIcon(_ sender: NSMenuItem) {
        SettingsManager.shared.monochromeIcon.toggle()
        sender.state = SettingsManager.shared.monochromeIcon ? .on : .off
        updateStatusIcon()   // перерисовать в новом стиле сразу
    }

    @objc private func toggleRemoteDesktop(_ sender: NSMenuItem) {
        SettingsManager.shared.remoteDesktopMode.toggle()
        sender.state = SettingsManager.shared.remoteDesktopMode ? .on : .off
        settingsController.updateRemoteDesktopState(SettingsManager.shared.remoteDesktopMode)   // #5
        reconfigureTap()  // уровень event tap зависит от режима
    }

    /// Пересоздаёт event tap и, если создание не удалось (например, session-tap отклонён),
    /// ретраит — иначе тумблер «вкл», а tap'а нет, и приложение молча не реагирует на триггер.
    private func reconfigureTap() {
        guard !keyboardMonitor.reconfigure() else { return }
        rslog("reconfigure failed (tap denied) — retry in 3s")
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            if self?.keyboardMonitor.reconfigure() == false { rslog("reconfigure retry failed") }
        }
    }

    @objc private func recheckPermissions() {
        runPermissionWizard(interactive: true)
    }

    @objc private func openSettings() {
        settingsController.showWindow()
    }

    @objc private func checkUpdates() {
        UpdateChecker.checkNow()
    }

    @objc private func openDonate() {
        if let url = URL(string: SettingsManager.shared.donateURL) {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func openGitHub() {
        if let url = URL(string: SettingsManager.githubURL) {
            NSWorkspace.shared.open(url)
        }
    }

    /// Окно «Что нового» — один раз после обновления, на языке приложения.
    /// НЕ показываем на свежей установке (там визард первого запуска): отличаем по
    /// launchAtLoginAsked — он выставляется на первом запуске, значит приложение уже
    /// работало ⇒ пустой lastWhatsNewVersion при hasRunBefore = обновление со старой версии.
    private func showWhatsNewIfNeeded(hasRunBefore: Bool) {
        let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        guard !current.isEmpty else { return }
        // Бета-версии (с буквой, напр. «3.2.0a») имеют ОТДЕЛЬНУЮ витрину
        // (showBetaWhatsNewIfNeeded) с текстом из бета-фида; локализованный whatsnew.body
        // под беты не обновляется (иначе тестер увидел бы устаревший текст).
        guard current.last?.isLetter != true else { return }
        let settings = SettingsManager.shared
        // Показываем только на РЕАЛЬНОМ повышении версии: current строго новее сохранённой
        // (numeric-сравнение, не строковое) — иначе даунгрейд 3.2→3.1 снова показал бы окно.
        guard current.compare(settings.lastWhatsNewVersion, options: .numeric) == .orderedDescending else { return }
        guard hasRunBefore else {                          // свежая установка: не показываем,
            settings.lastWhatsNewVersion = current         // но фиксируем версию (и на 2-м запуске молчим)
            return
        }
        // После обновления macOS мог сбросить права — идёт визард, мониторинг ещё не поднят.
        // Не наваливаем промо поверх запроса прав: откладываем до следующего запуска,
        // версию НЕ фиксируем (покажем, когда права выданы и мониторинг активен).
        guard monitoringActive else { return }
        settings.lastWhatsNewVersion = current             // фиксируем только когда реально показываем

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "\(L10n.whatsNewTitle) \(current)"
        alert.informativeText = L10n.whatsNewBody
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: L10n.whatsNewMore)
        if alert.runModal() == .alertSecondButtonReturn,
           let url = URL(string: "\(SettingsManager.githubURL)/releases/latest") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Отдельная витрина для БЕТ: текст изменений берётся из notes бета-фида
    /// (version-beta.json), а не из локализованного whatsnew.body — так его можно менять под
    /// каждую бету без пересборки и ×16-локализации. Только для подписчиков беты, один раз на
    /// версию. Текст двуязычный (RU+EN) — аудитория беты небольшая и приглашённая.
    private func showBetaWhatsNewIfNeeded() {
        let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        guard current.last?.isLetter == true else { return }         // только беты
        guard SettingsManager.shared.betaChannelEnabled else { return }  // только подписчики беты
        guard SettingsManager.shared.lastBetaNotesShown != current else { return }
        guard monitoringActive else { return }                        // не поверх запроса прав
        Task { @MainActor in
            guard let notes = await UpdateChecker.fetchBetaNotes(), !notes.isEmpty else { return }
            // перепроверяем после await (мог показаться параллельно / версия изменилась)
            guard SettingsManager.shared.lastBetaNotesShown != current else { return }
            SettingsManager.shared.lastBetaNotesShown = current
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = "\(L10n.whatsNewTitle) \(current) \(L10n.updateBeta)"
            alert.informativeText = notes
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: L10n.whatsNewMore)
            if alert.runModal() == .alertSecondButtonReturn,
               let url = URL(string: "\(SettingsManager.githubURL)/releases") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    /// Подменю «Поделиться» — прямые share-intent ссылки на площадки, актуальные для
    /// аудитории (Telegram/VK — главные для RU), + копирование. Нативный NSSharingServicePicker
    /// на macOS для этого слаб (нет соцсетей/мессенджеров), поэтому свои web-intent'ы.
    private func buildShareSubmenu() -> NSMenu {
        let link = SettingsManager.githubURL
        let text = L10n.shareMessage
        let menu = NSMenu()

        let copyItem = NSMenuItem(title: L10n.menuShareCopy, action: #selector(copyShareLink), keyEquivalent: "")
        copyItem.target = self
        copyItem.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)
        menu.addItem(copyItem)
        menu.addItem(NSMenuItem.separator())

        // (заголовок, icon-slug, base, параметры). icon: ключ ShareIcons или "sf:<symbol>".
        let targets: [(String, String, String, [(String, String)])] = [
            ("Telegram", "telegram", "https://t.me/share/url",                 [("url", link), ("text", text)]),
            ("VK",       "vk",       "https://vk.com/share.php",                [("url", link), ("title", text)]),
            ("X",        "x",        "https://twitter.com/intent/tweet",        [("text", text), ("url", link)]),
            ("WhatsApp", "whatsapp", "https://wa.me/",                          [("text", "\(text) \(link)")]),
            ("Facebook", "facebook", "https://www.facebook.com/sharer/sharer.php", [("u", link)]),
            ("Reddit",   "reddit",   "https://www.reddit.com/submit",           [("url", link), ("title", text)]),
            (L10n.menuShareEmail, "sf:envelope", "mailto:",                     [("subject", "RuSwitcher"), ("body", "\(text) \(link)")]),
        ]
        for (title, icon, base, params) in targets {
            guard let shareURL = Self.buildQueryURL(base, params) else { continue }
            let item = NSMenuItem(title: title, action: #selector(openShareLink(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = shareURL
            if icon.hasPrefix("sf:") {
                item.image = NSImage(systemSymbolName: String(icon.dropFirst(3)), accessibilityDescription: nil)
            } else {
                item.image = ShareIcons.image(icon)
            }
            menu.addItem(item)
        }
        return menu
    }

    /// Собирает URL с корректно закодированными query-параметрами (в т.ч. mailto).
    private static func buildQueryURL(_ base: String, _ params: [(String, String)]) -> String? {
        var comps = URLComponents(string: base)
        comps?.queryItems = params.map { URLQueryItem(name: $0.0, value: $0.1) }
        // URLComponents кодирует пробел как %20 (не '+'), а литеральный '+' в значении
        // оставляет как есть — но многие сервисы трактуют '+' как пробел. Поэтому
        // однозначно кодируем именно '+' → %2B (пробелы уже %20, их не трогаем).
        return comps?.url?.absoluteString.replacingOccurrences(of: "+", with: "%2B")
    }

    /// «Связаться с разработчиком»: открывает почту с предзаполненными темой и телом
    /// (версия + macOS + активные раскладки — для полезного баг-репорта). Пока адрес не задан
    /// (SettingsManager.contactEmail пуст) — фолбэк на GitHub Issues, чтобы кнопка не была мёртвой.
    @objc private func openContactEmail() {
        let ver = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        guard !SettingsManager.contactEmail.isEmpty else {
            if let url = URL(string: "\(SettingsManager.githubURL)/issues") { NSWorkspace.shared.open(url) }
            return
        }
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        let layouts = LayoutSwitcher.currentAndOppositeLanguage().map { "\($0.current)/\($0.opposite)" } ?? "?"
        let subject = "RuSwitcher \(ver) — \(L10n.contactSubject)"
        let body = "\n\n\n———\nRuSwitcher \(ver)\nmacOS \(os)\nLayouts: \(layouts)"
        if let s = Self.buildQueryURL("mailto:\(SettingsManager.contactEmail)",
                                      [("subject", subject), ("body", body)]),
           let url = URL(string: s) {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func openTelegramSupport() {
        if let url = URL(string: SettingsManager.telegramChatURL) { NSWorkspace.shared.open(url) }
    }

    @objc private func openShareLink(_ sender: NSMenuItem) {
        if let s = sender.representedObject as? String, let url = URL(string: s) {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func copyShareLink() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString("\(L10n.shareMessage) \(SettingsManager.githubURL)", forType: .string)
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Не теряем буфер обмена в 2-секундном окне отложенного восстановления
        // (актуально и при само-обновлении, которое завершает процесс).
        textConverter.flushPendingClipboardRestore()
    }

    @objc private func quit() {
        textConverter.flushPendingClipboardRestore()
        perAppLayoutManager.stop()
        keyboardMonitor.stop()
        NSApplication.shared.terminate(nil)
    }
}
