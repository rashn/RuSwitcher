import Foundation

/// Локализация интерфейса на 11 языков (вкомпилированные строки)
enum L10n {
    // MARK: - Меню
    static var menuAutoSwitch: String { s("menu.autoSwitch") }
    static var menuCheckPermissions: String { s("menu.checkPermissions") }
    static var menuSettings: String { s("menu.settings") }
    static var menuCheckUpdates: String { s("menu.checkUpdates") }
    static var menuDonate: String { s("menu.donate") }
    static var menuQuit: String { s("menu.quit") }

    // MARK: - Визард разрешений
    static var wizardPermissionsResetTitle: String { s("wizard.permissionsReset.title") }
    static var wizardPermissionsResetText: String { s("wizard.permissionsReset.text") }
    static var wizardAccessibilityTitle: String { s("wizard.accessibility.title") }
    static var wizardAccessibilityText: String { s("wizard.accessibility.text") }
    static var wizardInputMonitoringTitle: String { s("wizard.inputMonitoring.title") }
    static var wizardInputMonitoringText: String { s("wizard.inputMonitoring.text") }
    static var wizardOpenSettings: String { s("wizard.openSettings") }
    static var wizardLater: String { s("wizard.later") }
    static var wizardLaunchAtLoginTitle: String { s("wizard.launchAtLogin.title") }
    static var wizardLaunchAtLoginText: String { s("wizard.launchAtLogin.text") }
    static var wizardYes: String { s("wizard.yes") }
    static var wizardNo: String { s("wizard.no") }

    // MARK: - Настройки
    static var settingsTitle: String { s("settings.title") }
    static var settingsTabGeneral: String { s("settings.tab.general") }
    static var settingsTabAbout: String { s("settings.tab.about") }
    static var settingsTabAdvanced: String { s("settings.tab.advanced") }
    static var settingsAutoSwitch: String { s("settings.autoSwitch") }
    static var settingsLaunchAtLogin: String { s("settings.launchAtLogin") }
    static var settingsCheckUpdates: String { s("settings.checkUpdates") }
    static var settingsCheckUpdatesHint: String { s("settings.checkUpdates.hint") }
    static var settingsLayout1: String { s("settings.layout1") }
    static var settingsLayout2: String { s("settings.layout2") }
    static var settingsAutoDetect: String { s("settings.autoDetect") }
    static var settingsVersion: String { s("settings.version") }
    static var settingsDonate: String { s("settings.donate") }
    static var settingsContact: String { s("settings.contact") }
    static var settingsDebugLog: String { s("settings.debugLog") }
    static var settingsShowLog: String { s("settings.showLog") }
    static var settingsSendLog: String { s("settings.sendLog") }
    static var settingsHotkey: String { s("settings.hotkey") }
    static var settingsStarOnGithub: String { s("settings.starOnGithub") }
    static var menuStarOnGithub: String { s("menu.starOnGithub") }
    static var settingsLanguage: String { s("settings.language") }
    static var settingsLanguageAuto: String { s("settings.languageAuto") }

    static var settingsPerAppLayout: String { s("settings.perAppLayout") }

    // MARK: - Обновления
    static var updateAvailable: String { s("update.available") }
    static var updateNewVersion: String { s("update.newVersion") }
    static var updateDownload: String { s("update.download") }
    static var updateInstallRestart: String { s("update.installRestart") }
    static var updateSkip: String { s("update.skip") }
    static var updateLater: String { s("update.later") }
    static var updateUpToDate: String { s("update.upToDate") }
    static var updateLatestInstalled: String { s("update.latestInstalled") }
    static var updateCheckFailed: String { s("update.checkFailed") }
    static var updateCheckFailedDetail: String { s("update.checkFailedDetail") }
    static var updateInstallFailed: String { s("update.installFailed") }
    static var updateVerifyFailed: String { s("update.verifyFailed") }
    static var updateDownloadFailed: String { s("update.downloadFailed") }

    // MARK: - Language names (для выпадающего списка)

    /// Названия языков на их родном языке
    static let languageNames: [(code: String, name: String)] = [
        ("en", "English"),
        ("ru", "Русский"),
        ("uk", "Українська"),
        ("be", "Беларуская"),
        ("de", "Deutsch"),
        ("fr", "Français"),
        ("es", "Español"),
        ("pt", "Português"),
        ("pl", "Polski"),
        ("zh", "中文"),
        ("ja", "日本語"),
        ("ko", "한국어"),
    ]

    // MARK: - Private

    nonisolated(unsafe) private static var currentLang: String = detectLanguage()

    static let supportedLanguages = Set(["en", "ru", "de", "fr", "es", "pt", "zh", "ja", "ko", "uk", "pl", "be"])

    private static func detectLanguage() -> String {
        // Проверяем принудительный язык из настроек
        let forced = UserDefaults.standard.string(forKey: "com.ruswitcher.interfaceLanguage") ?? ""
        if !forced.isEmpty && supportedLanguages.contains(forced) {
            return forced
        }
        // Авто-определение по системе
        let preferred = Locale.preferredLanguages.first ?? "en"
        let code = String(preferred.prefix(2))
        return supportedLanguages.contains(code) ? code : "en"
    }

    /// Перезагрузить язык (вызывается при смене в настройках)
    static func reloadLanguage() {
        currentLang = detectLanguage()
    }

    private static func s(_ key: String) -> String {
        strings[currentLang]?[key] ?? strings["en"]![key] ?? key
    }

    // MARK: - Все строки

    private static let strings: [String: [String: String]] = [
        // ========== ENGLISH ==========
        "en": [
            "menu.autoSwitch": "Auto-switch",
            "menu.checkPermissions": "Check Permissions…",
            "menu.settings": "Settings…",
            "menu.checkUpdates": "Check for Updates…",
            "menu.donate": "Support Development ❤️",
            "menu.starOnGithub": "⭐ Star on GitHub",
            "menu.quit": "Quit",

            "wizard.permissionsReset.title": "Permissions Reset After Update",
            "wizard.permissionsReset.text": "macOS has reset permissions because the app was updated.\n\nRuSwitcher will remove old entries and request permissions again.\nYou just need to flip the toggles.",
            "wizard.accessibility.title": "Step 1 of 2: Accessibility",
            "wizard.accessibility.text": "RuSwitcher needs Accessibility permission.\n\nSettings will open — add RuSwitcher.\nThe app will detect it automatically.",
            "wizard.inputMonitoring.title": "Step 2 of 2: Input Monitoring",
            "wizard.inputMonitoring.text": "Now Input Monitoring permission is needed.\n\n⚠️ macOS will require an app restart after adding.\nRuSwitcher will restart automatically.",
            "wizard.openSettings": "Open Settings",
            "wizard.later": "Later",
            "wizard.launchAtLogin.title": "Launch at Login",
            "wizard.launchAtLogin.text": "Would you like RuSwitcher to start automatically when you log in?\n\nYou can change this later in Settings.",
            "wizard.yes": "Yes",
            "wizard.no": "No",

            "settings.title": "RuSwitcher — Settings",
            "settings.tab.general": "General",
            "settings.tab.about": "About",
            "settings.tab.advanced": "Advanced",
            "settings.autoSwitch": "Auto-switch layout",
            "settings.launchAtLogin": "Launch at login",
            "settings.checkUpdates": "Check for updates automatically",
            "settings.checkUpdates.hint": "Connects to GitHub on each launch to look for new versions.",
            "settings.layout1": "Layout 1:",
            "settings.layout2": "Layout 2:",
            "settings.autoDetect": "Auto-detect",
            "settings.version": "Lightweight alternative to PuntoSwitcher",
            "settings.donate": "Support Development ❤️",
            "settings.contact": "Contact Developer",
            "settings.debugLog": "Debug logging",
            "settings.showLog": "Show Log File",
            "settings.sendLog": "Send Log",
            "settings.hotkey": "⌥ Alt (tap) — convert last word\nAlso works on selected text\nDouble Alt — reverse conversion",
            "settings.starOnGithub": "⭐ Star on GitHub — help the project grow!",
            "settings.language": "Interface language:",
            "settings.languageAuto": "System default",
            "settings.perAppLayout": "Remember layout per application",

            "update.available": "Update Available",
            "update.newVersion": "New version:",
            "update.download": "Download",
            "update.installRestart": "Install & Restart",
            "update.skip": "Skip",
            "update.later": "Later",
            "update.upToDate": "Up to Date",
            "update.latestInstalled": "You have the latest version installed.",
            "update.checkFailed": "Update Check Failed",
            "update.checkFailedDetail": "Could not connect to the update server. Please check your internet connection.",
            "update.installFailed": "Installation Failed",
            "update.verifyFailed": "Download verification failed. The file may be corrupted.",
            "update.downloadFailed": "Could not download the update. Please check your internet connection.",
        ],

        // ========== РУССКИЙ ==========
        "ru": [
            "menu.autoSwitch": "Автопереключение",
            "menu.checkPermissions": "Проверить разрешения…",
            "menu.settings": "Настройки…",
            "menu.checkUpdates": "Проверить обновления…",
            "menu.donate": "Поддержать разработку ❤️",
            "menu.starOnGithub": "⭐ Звезда на GitHub",
            "menu.quit": "Выход",

            "wizard.permissionsReset.title": "Разрешения сброшены после обновления",
            "wizard.permissionsReset.text": "macOS сбросил разрешения из-за обновления программы.\n\nRuSwitcher удалит старые записи и запросит разрешения заново.\nВам нужно только включить тумблеры.",
            "wizard.accessibility.title": "Шаг 1 из 2: Универсальный доступ",
            "wizard.accessibility.text": "RuSwitcher нужно разрешение Accessibility.\n\nОткроются настройки — добавьте RuSwitcher.\nПрограмма определит автоматически.",
            "wizard.inputMonitoring.title": "Шаг 2 из 2: Мониторинг ввода",
            "wizard.inputMonitoring.text": "Теперь нужно разрешение Input Monitoring.\n\n⚠️ macOS потребует перезапуск приложения.\nRuSwitcher перезапустится автоматически.",
            "wizard.openSettings": "Открыть настройки",
            "wizard.later": "Позже",
            "wizard.launchAtLogin.title": "Автозагрузка",
            "wizard.launchAtLogin.text": "Запускать RuSwitcher автоматически при входе в систему?\n\nЭто можно изменить позже в Настройках.",
            "wizard.yes": "Да",
            "wizard.no": "Нет",

            "settings.title": "RuSwitcher — Настройки",
            "settings.tab.general": "Основные",
            "settings.tab.about": "О программе",
            "settings.tab.advanced": "Расширенные",
            "settings.autoSwitch": "Автопереключение раскладки",
            "settings.launchAtLogin": "Запускать при входе",
            "settings.checkUpdates": "Автоматически проверять обновления",
            "settings.checkUpdates.hint": "При каждом запуске приложение обращается к GitHub за информацией о новой версии.",
            "settings.layout1": "Раскладка 1:",
            "settings.layout2": "Раскладка 2:",
            "settings.autoDetect": "Автоопределение",
            "settings.version": "Лёгкая альтернатива PuntoSwitcher",
            "settings.donate": "Поддержать разработку ❤️",
            "settings.contact": "Связаться с разработчиком",
            "settings.debugLog": "Режим отладки",
            "settings.showLog": "Показать файл лога",
            "settings.sendLog": "Отправить лог",
            "settings.hotkey": "⌥ Alt (тап) — конвертировать последнее слово\nРаботает на выделенном тексте\nПовторный Alt — обратная конвертация",
            "settings.starOnGithub": "⭐ Поставить звезду на GitHub — помогите проекту!",
            "settings.language": "Язык интерфейса:",
            "settings.languageAuto": "Системный",
            "settings.perAppLayout": "Запоминать раскладку для каждого приложения",

            "update.available": "Доступно обновление",
            "update.newVersion": "Новая версия:",
            "update.download": "Скачать",
            "update.installRestart": "Установить и перезапустить",
            "update.skip": "Пропустить",
            "update.later": "Позже",
            "update.upToDate": "Актуальная версия",
            "update.latestInstalled": "У вас установлена последняя версия.",
            "update.checkFailed": "Ошибка проверки",
            "update.checkFailedDetail": "Не удалось подключиться к серверу обновлений.",
            "update.installFailed": "Ошибка установки",
            "update.verifyFailed": "Проверка загруженного файла не пройдена. Файл может быть повреждён.",
            "update.downloadFailed": "Не удалось скачать обновление. Проверьте подключение к интернету.",
        ],

        // ========== DEUTSCH ==========
        "de": [
            "menu.autoSwitch": "Auto-Umschaltung",
            "menu.checkPermissions": "Berechtigungen prüfen…",
            "menu.settings": "Einstellungen…",
            "menu.checkUpdates": "Nach Updates suchen…",
            "menu.donate": "Entwicklung unterstützen ❤️",
            "menu.starOnGithub": "⭐ Stern auf GitHub",
            "menu.quit": "Beenden",
            "wizard.accessibility.title": "Schritt 1 von 2: Bedienungshilfen",
            "wizard.accessibility.text": "RuSwitcher benötigt die Berechtigung für Bedienungshilfen.\n\nDie Einstellungen werden geöffnet — fügen Sie RuSwitcher hinzu.",
            "wizard.inputMonitoring.title": "Schritt 2 von 2: Eingabeüberwachung",
            "wizard.inputMonitoring.text": "Jetzt wird die Berechtigung für Eingabeüberwachung benötigt.\n\n⚠️ macOS erfordert einen Neustart der App.",
            "wizard.openSettings": "Einstellungen öffnen",
            "wizard.later": "Später",
            "wizard.launchAtLogin.title": "Beim Anmelden starten",
            "wizard.launchAtLogin.text": "Möchten Sie RuSwitcher beim Anmelden automatisch starten?\n\nDies können Sie später in den Einstellungen ändern.",
            "wizard.yes": "Ja",
            "wizard.no": "Nein",
            "settings.title": "RuSwitcher — Einstellungen",
            "settings.tab.general": "Allgemein",
            "settings.tab.about": "Über",
            "settings.tab.advanced": "Erweitert",
            "settings.autoSwitch": "Layout automatisch umschalten",
            "settings.launchAtLogin": "Beim Anmelden starten",
            "settings.checkUpdates": "Automatisch nach Updates suchen",
            "settings.checkUpdates.hint": "Verbindet sich bei jedem Start mit GitHub, um nach neuen Versionen zu suchen.",
            "settings.layout1": "Layout 1:",
            "settings.layout2": "Layout 2:",
            "settings.autoDetect": "Automatisch",
            "settings.version": "Leichte Alternative zu PuntoSwitcher",
            "settings.donate": "Entwicklung unterstützen ❤️",
            "settings.contact": "Entwickler kontaktieren",
            "settings.debugLog": "Debug-Protokollierung",
            "settings.showLog": "Protokolldatei anzeigen",
            "settings.sendLog": "Protokoll senden",
            "settings.hotkey": "⌥ Alt (Tipp) — letztes Wort konvertieren\nFunktioniert auch mit markiertem Text\nDoppeltes Alt — Rückkonvertierung",
            "settings.starOnGithub": "⭐ Stern auf GitHub — helfen Sie dem Projekt!",
            "settings.language": "Sprache der Oberfläche:",
            "settings.languageAuto": "Systemstandard",
            "settings.perAppLayout": "Layout pro Anwendung merken",
            "wizard.permissionsReset.title": "Berechtigungen nach Update zurückgesetzt",
            "wizard.permissionsReset.text": "macOS hat die Berechtigungen nach dem App-Update zurückgesetzt.\n\nRuSwitcher entfernt alte Einträge und fordert Berechtigungen erneut an.\nSie müssen nur die Schalter umlegen.",
            "update.available": "Update verfügbar",
            "update.newVersion": "Neue Version:",
            "update.download": "Herunterladen",
            "update.installRestart": "Installieren & Neustarten",
            "update.skip": "Überspringen",
            "update.later": "Später",
            "update.upToDate": "Aktuell",
            "update.latestInstalled": "Sie haben die neueste Version installiert.",
            "update.checkFailed": "Update-Prüfung fehlgeschlagen",
            "update.checkFailedDetail": "Verbindung zum Update-Server nicht möglich.",
            "update.installFailed": "Installation fehlgeschlagen",
            "update.verifyFailed": "Download-Überprüfung fehlgeschlagen. Die Datei könnte beschädigt sein.",
            "update.downloadFailed": "Update konnte nicht heruntergeladen werden.",
        ],

        // ========== FRANÇAIS ==========
        "fr": [
            "menu.autoSwitch": "Basculement auto",
            "menu.checkPermissions": "Vérifier les autorisations…",
            "menu.settings": "Préférences…",
            "menu.checkUpdates": "Rechercher les mises à jour…",
            "menu.donate": "Soutenir le développement ❤️",
            "menu.starOnGithub": "⭐ Étoile sur GitHub",
            "menu.quit": "Quitter",
            "wizard.accessibility.title": "Étape 1 sur 2 : Accessibilité",
            "wizard.accessibility.text": "RuSwitcher a besoin de l'autorisation Accessibilité.\n\nLes réglages vont s'ouvrir — ajoutez RuSwitcher.",
            "wizard.inputMonitoring.title": "Étape 2 sur 2 : Surveillance de l'entrée",
            "wizard.inputMonitoring.text": "L'autorisation de surveillance de l'entrée est maintenant nécessaire.\n\n⚠️ macOS demandera un redémarrage de l'app.",
            "wizard.openSettings": "Ouvrir les réglages",
            "wizard.later": "Plus tard",
            "wizard.launchAtLogin.title": "Lancer au démarrage",
            "wizard.launchAtLogin.text": "Voulez-vous que RuSwitcher démarre automatiquement à l'ouverture de session ?\n\nVous pourrez modifier ce réglage plus tard dans les Préférences.",
            "wizard.yes": "Oui",
            "wizard.no": "Non",
            "settings.title": "RuSwitcher — Préférences",
            "settings.tab.general": "Général",
            "settings.tab.about": "À propos",
            "settings.tab.advanced": "Avancé",
            "settings.autoSwitch": "Basculer automatiquement la disposition",
            "settings.launchAtLogin": "Lancer au démarrage",
            "settings.checkUpdates": "Vérifier les mises à jour automatiquement",
            "settings.checkUpdates.hint": "Se connecte à GitHub à chaque lancement pour rechercher de nouvelles versions.",
            "settings.layout1": "Disposition 1 :",
            "settings.layout2": "Disposition 2 :",
            "settings.autoDetect": "Détection auto",
            "settings.version": "Alternative légère à PuntoSwitcher",
            "settings.donate": "Soutenir le développement ❤️",
            "settings.contact": "Contacter le développeur",
            "settings.debugLog": "Journal de débogage",
            "settings.showLog": "Afficher le journal",
            "settings.sendLog": "Envoyer le journal",
            "settings.hotkey": "⌥ Alt (tap) — convertir le dernier mot\nFonctionne aussi sur le texte sélectionné\nDouble Alt — conversion inverse",
            "settings.starOnGithub": "⭐ Étoile sur GitHub — aidez le projet !",
            "settings.language": "Langue de l'interface :",
            "settings.languageAuto": "Système par défaut",
            "settings.perAppLayout": "Mémoriser la disposition par application",
            "wizard.permissionsReset.title": "Autorisations réinitialisées après mise à jour",
            "wizard.permissionsReset.text": "macOS a réinitialisé les autorisations suite à la mise à jour.\n\nRuSwitcher supprimera les anciennes entrées et redemandera les autorisations.\nVous n'avez qu'à activer les boutons.",
            "update.available": "Mise à jour disponible",
            "update.newVersion": "Nouvelle version :",
            "update.download": "Télécharger",
            "update.installRestart": "Installer et redémarrer",
            "update.skip": "Ignorer",
            "update.later": "Plus tard",
            "update.upToDate": "À jour",
            "update.latestInstalled": "Vous avez la dernière version installée.",
            "update.checkFailed": "Échec de la vérification",
            "update.checkFailedDetail": "Impossible de se connecter au serveur de mise à jour.",
            "update.installFailed": "Échec de l'installation",
            "update.verifyFailed": "La vérification du téléchargement a échoué. Le fichier est peut-être corrompu.",
            "update.downloadFailed": "Impossible de télécharger la mise à jour.",
        ],

        // ========== ESPAÑOL ==========
        "es": [
            "menu.autoSwitch": "Cambio automático",
            "menu.checkPermissions": "Verificar permisos…",
            "menu.settings": "Ajustes…",
            "menu.checkUpdates": "Buscar actualizaciones…",
            "menu.donate": "Apoyar el desarrollo ❤️",
            "menu.starOnGithub": "⭐ Estrella en GitHub",
            "menu.quit": "Salir",
            "wizard.accessibility.title": "Paso 1 de 2: Accesibilidad",
            "wizard.accessibility.text": "RuSwitcher necesita permiso de Accesibilidad.\n\nSe abrirán los ajustes — añada RuSwitcher.",
            "wizard.inputMonitoring.title": "Paso 2 de 2: Monitoreo de entrada",
            "wizard.inputMonitoring.text": "Ahora se necesita el permiso de monitoreo de entrada.\n\n⚠️ macOS requerirá reiniciar la app.",
            "wizard.openSettings": "Abrir ajustes",
            "wizard.later": "Más tarde",
            "wizard.launchAtLogin.title": "Iniciar al arrancar",
            "wizard.launchAtLogin.text": "¿Desea que RuSwitcher se inicie automáticamente al iniciar sesión?\n\nPuede cambiar esto más tarde en Ajustes.",
            "wizard.yes": "Sí",
            "wizard.no": "No",
            "settings.title": "RuSwitcher — Ajustes",
            "settings.tab.general": "General",
            "settings.tab.about": "Acerca de",
            "settings.tab.advanced": "Avanzado",
            "settings.autoSwitch": "Cambiar disposición automáticamente",
            "settings.launchAtLogin": "Iniciar al arrancar",
            "settings.checkUpdates": "Buscar actualizaciones automáticamente",
            "settings.checkUpdates.hint": "Se conecta a GitHub en cada inicio para buscar nuevas versiones.",
            "settings.layout1": "Disposición 1:",
            "settings.layout2": "Disposición 2:",
            "settings.autoDetect": "Detección automática",
            "settings.version": "Alternativa ligera a PuntoSwitcher",
            "settings.donate": "Apoyar el desarrollo ❤️",
            "settings.contact": "Contactar al desarrollador",
            "settings.debugLog": "Registro de depuración",
            "settings.showLog": "Mostrar archivo de registro",
            "settings.sendLog": "Enviar registro",
            "settings.hotkey": "⌥ Alt (toque) — convertir última palabra\nFunciona con texto seleccionado\nDoble Alt — conversión inversa",
            "settings.starOnGithub": "⭐ Estrella en GitHub — ¡ayuda al proyecto!",
            "settings.language": "Idioma de la interfaz:",
            "settings.languageAuto": "Predeterminado del sistema",
            "settings.perAppLayout": "Recordar disposición por aplicación",
            "wizard.permissionsReset.title": "Permisos restablecidos tras actualización",
            "wizard.permissionsReset.text": "macOS ha restablecido los permisos tras la actualización.\n\nRuSwitcher eliminará las entradas antiguas y solicitará permisos de nuevo.\nSolo necesita activar los interruptores.",
            "update.available": "Actualización disponible",
            "update.newVersion": "Nueva versión:",
            "update.download": "Descargar",
            "update.installRestart": "Instalar y reiniciar",
            "update.skip": "Omitir",
            "update.later": "Más tarde",
            "update.upToDate": "Actualizado",
            "update.latestInstalled": "Tiene instalada la última versión.",
            "update.checkFailed": "Error de verificación",
            "update.checkFailedDetail": "No se pudo conectar al servidor de actualizaciones.",
            "update.installFailed": "Error de instalación",
            "update.verifyFailed": "La verificación de la descarga falló. El archivo puede estar dañado.",
            "update.downloadFailed": "No se pudo descargar la actualización.",
        ],

        // ========== PORTUGUÊS ==========
        "pt": [
            "menu.autoSwitch": "Troca automática",
            "menu.checkPermissions": "Verificar permissões…",
            "menu.settings": "Configurações…",
            "menu.checkUpdates": "Verificar atualizações…",
            "menu.donate": "Apoiar o desenvolvimento ❤️",
            "menu.starOnGithub": "⭐ Estrela no GitHub",
            "menu.quit": "Sair",
            "wizard.openSettings": "Abrir configurações",
            "wizard.later": "Mais tarde",
            "settings.title": "RuSwitcher — Configurações",
            "settings.tab.general": "Geral",
            "settings.tab.about": "Sobre",
            "settings.tab.advanced": "Avançado",
            "settings.autoSwitch": "Trocar layout automaticamente",
            "settings.launchAtLogin": "Iniciar no login",
            "settings.checkUpdates": "Verificar atualizações automaticamente",
            "settings.checkUpdates.hint": "Conecta-se ao GitHub a cada inicialização para procurar novas versões.",
            "settings.autoDetect": "Detecção automática",
            "settings.donate": "Apoiar o desenvolvimento ❤️",
            "settings.contact": "Contatar o desenvolvedor",
            "settings.starOnGithub": "⭐ Estrela no GitHub — ajude o projeto!",
            "settings.language": "Idioma da interface:",
            "settings.languageAuto": "Padrão do sistema",
            "settings.perAppLayout": "Lembrar layout por aplicativo",
            "update.download": "Baixar",
            "update.installRestart": "Instalar e reiniciar",
            "update.skip": "Pular",
            "update.later": "Mais tarde",
        ],

        // ========== 中文 ==========
        "zh": [
            "menu.autoSwitch": "自动切换",
            "menu.checkPermissions": "检查权限…",
            "menu.settings": "设置…",
            "menu.checkUpdates": "检查更新…",
            "menu.donate": "支持开发 ❤️",
            "menu.starOnGithub": "⭐ 在 GitHub 上点星",
            "menu.quit": "退出",
            "wizard.openSettings": "打开设置",
            "wizard.later": "稍后",
            "settings.title": "RuSwitcher — 设置",
            "settings.tab.general": "通用",
            "settings.tab.about": "关于",
            "settings.tab.advanced": "高级",
            "settings.autoSwitch": "自动切换布局",
            "settings.launchAtLogin": "登录时启动",
            "settings.checkUpdates": "自动检查更新",
            "settings.checkUpdates.hint": "每次启动时连接 GitHub 查找新版本。",
            "settings.autoDetect": "自动检测",
            "settings.donate": "支持开发 ❤️",
            "settings.contact": "联系开发者",
            "settings.starOnGithub": "⭐ 在 GitHub 上点星 — 帮助项目成长！",
            "settings.language": "界面语言：",
            "settings.languageAuto": "跟随系统",
            "settings.perAppLayout": "按应用记住布局",
            "update.download": "下载",
            "update.installRestart": "安装并重启",
            "update.skip": "跳过",
            "update.later": "稍后",
        ],

        // ========== 日本語 ==========
        "ja": [
            "menu.autoSwitch": "自動切替",
            "menu.checkPermissions": "権限を確認…",
            "menu.settings": "設定…",
            "menu.checkUpdates": "アップデートを確認…",
            "menu.donate": "開発を支援 ❤️",
            "menu.starOnGithub": "⭐ GitHub でスターする",
            "menu.quit": "終了",
            "wizard.openSettings": "設定を開く",
            "wizard.later": "後で",
            "settings.title": "RuSwitcher — 設定",
            "settings.tab.general": "一般",
            "settings.tab.about": "このアプリについて",
            "settings.tab.advanced": "詳細",
            "settings.autoSwitch": "レイアウトの自動切替",
            "settings.launchAtLogin": "ログイン時に起動",
            "settings.checkUpdates": "自動的にアップデートを確認",
            "settings.checkUpdates.hint": "起動時に GitHub へ接続して新しいバージョンを確認します。",
            "settings.autoDetect": "自動検出",
            "settings.donate": "開発を支援 ❤️",
            "settings.contact": "開発者に連絡",
            "settings.starOnGithub": "⭐ GitHub でスター — プロジェクトを応援！",
            "settings.language": "インターフェース言語：",
            "settings.languageAuto": "システムデフォルト",
            "settings.perAppLayout": "アプリごとにレイアウトを記憶",
            "update.download": "ダウンロード",
            "update.installRestart": "インストールして再起動",
            "update.skip": "スキップ",
            "update.later": "後で",
        ],

        // ========== 한국어 ==========
        "ko": [
            "menu.autoSwitch": "자동 전환",
            "menu.checkPermissions": "권한 확인…",
            "menu.settings": "설정…",
            "menu.checkUpdates": "업데이트 확인…",
            "menu.donate": "개발 지원 ❤️",
            "menu.starOnGithub": "⭐ GitHub에서 스타하기",
            "menu.quit": "종료",
            "wizard.openSettings": "설정 열기",
            "wizard.later": "나중에",
            "settings.title": "RuSwitcher — 설정",
            "settings.tab.general": "일반",
            "settings.tab.about": "정보",
            "settings.tab.advanced": "고급",
            "settings.autoSwitch": "자동 레이아웃 전환",
            "settings.launchAtLogin": "로그인 시 실행",
            "settings.checkUpdates": "자동으로 업데이트 확인",
            "settings.checkUpdates.hint": "실행할 때마다 GitHub에 연결하여 새 버전을 확인합니다.",
            "settings.autoDetect": "자동 감지",
            "settings.donate": "개발 지원 ❤️",
            "settings.contact": "개발자 연락",
            "settings.starOnGithub": "⭐ GitHub에서 스타 — 프로젝트를 도와주세요!",
            "settings.language": "인터페이스 언어:",
            "settings.languageAuto": "시스템 기본값",
            "settings.perAppLayout": "앱별 레이아웃 기억",
            "update.download": "다운로드",
            "update.installRestart": "설치 후 재시작",
            "update.skip": "건너뛰기",
            "update.later": "나중에",
        ],

        // ========== УКРАЇНСЬКА ==========
        "uk": [
            "menu.autoSwitch": "Автоперемикання",
            "menu.checkPermissions": "Перевірити дозволи…",
            "menu.settings": "Налаштування…",
            "menu.checkUpdates": "Перевірити оновлення…",
            "menu.donate": "Підтримати розробку ❤️",
            "menu.starOnGithub": "⭐ Зірка на GitHub",
            "menu.quit": "Вихід",

            "wizard.permissionsReset.title": "Дозволи скинуті після оновлення",
            "wizard.permissionsReset.text": "macOS скинув дозволи через оновлення програми.\n\nRuSwitcher видалить старі записи і запросить дозволи знову.\nВам потрібно лише увімкнути перемикачі.",
            "wizard.accessibility.title": "Крок 1 з 2: Доступність",
            "wizard.accessibility.text": "RuSwitcher потребує дозвіл Accessibility.\n\nВідкриються налаштування — додайте RuSwitcher.\nПрограма визначить автоматично.",
            "wizard.inputMonitoring.title": "Крок 2 з 2: Моніторинг введення",
            "wizard.inputMonitoring.text": "Тепер потрібен дозвіл Input Monitoring.\n\n⚠️ macOS вимагатиме перезапуск програми.\nRuSwitcher перезапуститься автоматично.",
            "wizard.openSettings": "Відкрити налаштування",
            "wizard.later": "Пізніше",
            "wizard.launchAtLogin.title": "Автозавантаження",
            "wizard.launchAtLogin.text": "Запускати RuSwitcher автоматично при вході в систему?\n\nЦе можна змінити пізніше в Налаштуваннях.",
            "wizard.yes": "Так",
            "wizard.no": "Ні",

            "settings.title": "RuSwitcher — Налаштування",
            "settings.tab.general": "Загальні",
            "settings.tab.about": "Про програму",
            "settings.tab.advanced": "Додатково",
            "settings.autoSwitch": "Автоматично перемикати розкладку",
            "settings.launchAtLogin": "Запускати при вході",
            "settings.checkUpdates": "Автоматично перевіряти оновлення",
            "settings.checkUpdates.hint": "При кожному запуску застосунок звертається до GitHub за інформацією про нову версію.",
            "settings.layout1": "Розкладка 1:",
            "settings.layout2": "Розкладка 2:",
            "settings.autoDetect": "Автовизначення",
            "settings.version": "Легка альтернатива PuntoSwitcher",
            "settings.donate": "Підтримати розробку ❤️",
            "settings.contact": "Зв'язатися з розробником",
            "settings.debugLog": "Режим налагодження",
            "settings.showLog": "Показати файл логу",
            "settings.sendLog": "Надіслати лог",
            "settings.hotkey": "⌥ Alt (тап) — конвертувати останнє слово\nПрацює на виділеному тексті\nПовторний Alt — зворотна конвертація",
            "settings.starOnGithub": "⭐ Зірка на GitHub — допоможіть проєкту!",
            "settings.language": "Мова інтерфейсу:",
            "settings.languageAuto": "Системна",
            "settings.perAppLayout": "Запам'ятовувати розкладку для кожного застосунку",

            "update.available": "Доступне оновлення",
            "update.newVersion": "Нова версія:",
            "update.download": "Завантажити",
            "update.installRestart": "Встановити та перезапустити",
            "update.skip": "Пропустити",
            "update.later": "Пізніше",
            "update.upToDate": "Актуальна версія",
            "update.latestInstalled": "У вас встановлено останню версію.",
            "update.checkFailed": "Помилка перевірки",
            "update.checkFailedDetail": "Не вдалося з'єднатися з сервером оновлень.",
            "update.installFailed": "Помилка встановлення",
            "update.verifyFailed": "Перевірка завантаженого файлу не пройдена. Файл може бути пошкоджений.",
            "update.downloadFailed": "Не вдалося завантажити оновлення.",
        ],

        // ========== БЕЛАРУСКАЯ ==========
        "be": [
            "menu.autoSwitch": "Аўтаперамыканне",
            "menu.checkPermissions": "Праверыць дазволы…",
            "menu.settings": "Налады…",
            "menu.checkUpdates": "Праверыць абнаўленні…",
            "menu.donate": "Падтрымаць распрацоўку ❤️",
            "menu.starOnGithub": "⭐ Зорка на GitHub",
            "menu.quit": "Выхад",

            "wizard.permissionsReset.title": "Дазволы скінуты пасля абнаўлення",
            "wizard.permissionsReset.text": "macOS скінуў дазволы з-за абнаўлення праграмы.\n\nRuSwitcher выдаліць старыя запісы і запытае дазволы нанова.\nВам трэба толькі ўключыць пераключальнікі.",
            "wizard.accessibility.title": "Крок 1 з 2: Даступнасць",
            "wizard.accessibility.text": "RuSwitcher патрабуе дазвол Accessibility.\n\nАдкрыюцца налады — дадайце RuSwitcher.\nПраграма вызначыць аўтаматычна.",
            "wizard.inputMonitoring.title": "Крок 2 з 2: Маніторынг уводу",
            "wizard.inputMonitoring.text": "Цяпер патрэбен дазвол Input Monitoring.\n\n⚠️ macOS запатрабуе перазапуск праграмы.\nRuSwitcher перазапусціцца аўтаматычна.",
            "wizard.openSettings": "Адкрыць налады",
            "wizard.later": "Пазней",
            "wizard.launchAtLogin.title": "Аўтазагрузка",
            "wizard.launchAtLogin.text": "Запускаць RuSwitcher аўтаматычна пры ўваходзе ў сістэму?\n\nГэта можна змяніць пазней у Наладах.",
            "wizard.yes": "Так",
            "wizard.no": "Не",

            "settings.title": "RuSwitcher — Налады",
            "settings.tab.general": "Агульныя",
            "settings.tab.about": "Пра праграму",
            "settings.tab.advanced": "Дадаткова",
            "settings.autoSwitch": "Аўтаматычна пераключаць раскладку",
            "settings.launchAtLogin": "Запускаць пры ўваходзе",
            "settings.checkUpdates": "Аўтаматычна правяраць абнаўленні",
            "settings.checkUpdates.hint": "Пры кожным запуску праграма звяртаецца да GitHub па інфармацыю аб новай версіі.",
            "settings.layout1": "Раскладка 1:",
            "settings.layout2": "Раскладка 2:",
            "settings.autoDetect": "Аўтавызначэнне",
            "settings.version": "Лёгкая альтэрнатыва PuntoSwitcher",
            "settings.donate": "Падтрымаць распрацоўку ❤️",
            "settings.contact": "Звязацца з распрацоўшчыкам",
            "settings.debugLog": "Рэжым адладкі",
            "settings.showLog": "Паказаць файл лога",
            "settings.sendLog": "Адправіць лог",
            "settings.hotkey": "⌥ Alt (тап) — канвертаваць апошняе слова\nПрацуе на вылучаным тэксце\nПаўторны Alt — зваротная канвертацыя",
            "settings.starOnGithub": "⭐ Зорка на GitHub — дапамажыце праекту!",
            "settings.language": "Мова інтэрфейсу:",
            "settings.languageAuto": "Сістэмная",
            "settings.perAppLayout": "Запамінаць раскладку для кожнай праграмы",

            "update.available": "Даступна абнаўленне",
            "update.newVersion": "Новая версія:",
            "update.download": "Спампаваць",
            "update.installRestart": "Усталяваць і перазапусціць",
            "update.skip": "Прапусціць",
            "update.later": "Пазней",
            "update.upToDate": "Актуальная версія",
            "update.latestInstalled": "У вас усталявана апошняя версія.",
            "update.checkFailed": "Памылка праверкі",
            "update.checkFailedDetail": "Не ўдалося злучыцца з серверам абнаўленняў.",
            "update.installFailed": "Памылка ўсталявання",
            "update.verifyFailed": "Праверка спампаванага файла не прайшла. Файл можа быць пашкоджаны.",
            "update.downloadFailed": "Не ўдалося спампаваць абнаўленне.",
        ],

        // ========== POLSKI ==========
        "pl": [
            "menu.autoSwitch": "Automatyczne przełączanie",
            "menu.checkPermissions": "Sprawdź uprawnienia…",
            "menu.settings": "Ustawienia…",
            "menu.checkUpdates": "Sprawdź aktualizacje…",
            "menu.donate": "Wesprzyj rozwój ❤️",
            "menu.starOnGithub": "⭐ Gwiazdka na GitHub",
            "menu.quit": "Zakończ",
            "wizard.openSettings": "Otwórz ustawienia",
            "wizard.later": "Później",
            "settings.title": "RuSwitcher — Ustawienia",
            "settings.tab.general": "Ogólne",
            "settings.tab.about": "O programie",
            "settings.tab.advanced": "Zaawansowane",
            "settings.autoSwitch": "Automatycznie przełączaj układ",
            "settings.launchAtLogin": "Uruchom przy logowaniu",
            "settings.checkUpdates": "Automatycznie sprawdzaj aktualizacje",
            "settings.checkUpdates.hint": "Łączy się z GitHub przy każdym uruchomieniu, aby sprawdzić nowe wersje.",
            "settings.autoDetect": "Automatyczne wykrywanie",
            "settings.donate": "Wesprzyj rozwój ❤️",
            "settings.contact": "Skontaktuj się z deweloperem",
            "settings.starOnGithub": "⭐ Gwiazdka na GitHub — pomóż projektowi!",
            "settings.language": "Język interfejsu:",
            "settings.languageAuto": "Domyślny systemowy",
            "settings.perAppLayout": "Zapamiętaj układ dla każdej aplikacji",
            "update.download": "Pobierz",
            "update.installRestart": "Zainstaluj i uruchom ponownie",
            "update.skip": "Pomiń",
            "update.later": "Później",
        ],
    ]
}
