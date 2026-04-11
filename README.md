# RuSwitcher

<p align="center">
  <img src="icon.png" width="128" alt="RuSwitcher icon">
</p>

<p align="center">
  <b>Lightweight keyboard layout switcher for macOS</b><br>
  Free and open-source alternative to PuntoSwitcher
</p>

<p align="center">
  <a href="https://github.com/rashn/RuSwitcher/releases/latest"><img src="https://img.shields.io/github/v/release/rashn/RuSwitcher?style=flat-square" alt="Release"></a>
  <a href="LICENSE"><img src="https://img.shields.io/github/license/rashn/RuSwitcher?style=flat-square" alt="License"></a>
  <img src="https://img.shields.io/badge/macOS-13%2B-blue?style=flat-square" alt="macOS 13+">
  <img src="https://img.shields.io/badge/Swift-6-orange?style=flat-square" alt="Swift 6">
</p>

<p align="center">
  <a href="#english">English</a> · <a href="#русский">Русский</a>
</p>

---

## English

Typed `ghbdtn` instead of `hello`? Just tap **⌥ Alt** and RuSwitcher converts the last word into the right layout. Works with any pair of installed keyboard layouts — Russian, Ukrainian, Belarusian, German, French, and more.

### How it works

| Action | Result |
|---|---|
| Type a word, tap **⌥ Alt** | Last typed word is converted |
| Tap **⌥ Alt** again | Reverse conversion (undo) |
| Select text, tap **⌥ Alt** | Selected text is converted |

### Features

- **Any two layouts** — configure any pair from your installed system layouts. No hardcoded tables.
- **Smart word detection** — converts the last typed word, including punctuation.
- **Selected text** — select any text and tap Alt to convert it in place.
- **Double Alt** — reverse conversion if you changed your mind.
- **12 interface languages** — English, Русский, Українська, Беларуская, Deutsch, Français, Español, Português, Polski, 中文, 日本語, 한국어.
- **Auto-start at login** — set and forget.
- **Minimal footprint** — no Electron, no web views, pure Swift + AppKit.
- **No telemetry** — your keystrokes stay on your Mac.

### Installation

**Homebrew (recommended)**

```bash
brew tap rashn/ruswitcher
brew install --cask ruswitcher
```

To upgrade later: `brew upgrade --cask ruswitcher`.

**Download DMG**

Grab the latest `.dmg` from [**Releases**](https://github.com/rashn/RuSwitcher/releases/latest), open it and drag RuSwitcher to Applications.

**Build from source**

```bash
git clone https://github.com/rashn/RuSwitcher.git
cd RuSwitcher
bash build_app.sh
cp -R RuSwitcher.app /Applications/
```

Requires macOS 13+ and Xcode Command Line Tools.

### Permissions

On first launch, RuSwitcher requests two macOS permissions:

1. **Accessibility** — to read and modify text in applications.
2. **Input Monitoring** — to detect keyboard events.

The app adds itself to the permission lists automatically — you only need to flip the toggles. The built-in permission wizard walks you through it step by step.

### Technical details

- `CGEventTap` (passive, listen-only) for keyboard monitoring.
- `UCKeyTranslate` (Carbon) for dynamic character mapping between any layout pair.
- `CGEventSource.userData` marker to filter the app's own simulated events.
- `AXUIElement` API for focused element detection.
- `SMAppService` for login item management.
- No hardcoded layout tables — works with any installed layouts.

### Settings

Access via the menu bar icon → **Settings** (⌘,).

- **General** — auto-switch, launch at login, interface language, layout pair.
- **About** — version, donate, contact, check updates.
- **Advanced** — debug logging, log management.

### Support the project

If you find RuSwitcher useful:

- [**Boosty**](https://boosty.to/ruswitcher) — donate
- **Star** this repo on GitHub

### License

[MIT](LICENSE) — free to use, modify, and distribute.

---

## Русский

Набрали `ghbdtn` вместо `привет`? Просто нажмите **⌥ Alt** — и RuSwitcher сконвертирует последнее слово в правильную раскладку. Работает с любой парой установленных раскладок — русская, украинская, белорусская, немецкая, французская и другие.

### Как работает

| Действие | Результат |
|---|---|
| Набрать слово, нажать **⌥ Alt** | Последнее слово сконвертировано |
| Нажать **⌥ Alt** повторно | Обратная конвертация (отмена) |
| Выделить текст, нажать **⌥ Alt** | Выделенный текст сконвертирован |

### Возможности

- **Любая пара раскладок** — настраивается любая пара из установленных в системе. Без захардкоженных таблиц.
- **Умное определение слова** — конвертирует последнее набранное слово, включая знаки препинания.
- **Выделенный текст** — выделите любой текст и нажмите Alt для конвертации на месте.
- **Повторный Alt** — обратная конвертация, если передумали.
- **12 языков интерфейса** — English, Русский, Українська, Беларуская, Deutsch, Français, Español, Português, Polski, 中文, 日本語, 한국어.
- **Автозапуск при входе** — настроил и забыл.
- **Минимальное потребление** — без Electron и веб-вьюх, чистый Swift + AppKit.
- **Без телеметрии** — ваши нажатия остаются на вашем Mac.

### Установка

**Homebrew (рекомендуется)**

```bash
brew tap rashn/ruswitcher
brew install --cask ruswitcher
```

Для обновления: `brew upgrade --cask ruswitcher`.

**Скачать DMG**

Скачайте последний `.dmg` со страницы [**Releases**](https://github.com/rashn/RuSwitcher/releases/latest), откройте и перетащите RuSwitcher в «Программы».

**Сборка из исходников**

```bash
git clone https://github.com/rashn/RuSwitcher.git
cd RuSwitcher
bash build_app.sh
cp -R RuSwitcher.app /Applications/
```

Требуется macOS 13+ и Xcode Command Line Tools.

### Разрешения

При первом запуске RuSwitcher запросит два системных разрешения macOS:

1. **Универсальный доступ (Accessibility)** — для чтения и изменения текста в приложениях.
2. **Мониторинг ввода (Input Monitoring)** — для отслеживания нажатий клавиш.

Программа автоматически добавляется в списки разрешений — вам нужно только включить тумблеры. Встроенный мастер разрешений проведёт по шагам.

### Технические детали

- `CGEventTap` (пассивный, только чтение) для мониторинга клавиатуры.
- `UCKeyTranslate` (Carbon) для динамического маппинга символов между любой парой раскладок.
- Маркер `CGEventSource.userData` для фильтрации собственных симулированных событий.
- `AXUIElement` API для определения сфокусированного элемента.
- `SMAppService` для управления автозапуском.
- Без захардкоженных таблиц — работает с любыми установленными раскладками.

### Настройки

Доступ через иконку в строке меню → **Настройки** (⌘,).

- **Общие** — автопереключение, автозапуск, язык интерфейса, пара раскладок.
- **О программе** — версия, донат, контакт, проверка обновлений.
- **Дополнительно** — режим отладки, управление логами.

### Поддержать проект

Если RuSwitcher вам полезен:

- [**Boosty**](https://boosty.to/ruswitcher) — донат
- **Star** на GitHub

### Лицензия

[MIT](LICENSE) — свободное использование, модификация и распространение.
