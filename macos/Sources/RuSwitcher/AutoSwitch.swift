import AppKit
import Carbon
import IOKit

/// Проверка слов по системному словарю (NSSpellChecker) — локально, без зависимостей,
/// без сети и без бандла данных. ~0.1мс на проверку, 40+ языков.
enum Dict {
    @MainActor private static let checker = NSSpellChecker.shared
    /// Кэш списка словарей: availableLanguages ходит в AppleSpell — не дёргаем на каждое слово.
    @MainActor private static var cachedLanguages: [String]?

    @MainActor static func isAvailable(_ lang: String) -> Bool {
        let two = String(lang.prefix(2))
        return FrequencyPacks.pack(for: two) != nil || languages().contains { String($0.prefix(2)) == two }
    }

    @MainActor private static func languages() -> [String] {
        if let cached = cachedLanguages { return cached }
        let langs = checker.availableLanguages
        cachedLanguages = langs
        return langs
    }

    /// Прогрев: первое обращение к NSSpellChecker поднимает XPC-процесс AppleSpell
    /// (сотни мс на main) — без прогрева этот фриз пришёлся бы на первый пробел
    /// пользователя после запуска. Вызывается отложенно из applicationDidFinishLaunching.
    @MainActor static func warmUp() {
        _ = languages()
        for lang in LayoutSwitcher.pairLanguages() { _ = FrequencyPacks.pack(for: lang) }   // ~10 мс на пак
        _ = isValidWord("тест", lang: "ru")
        _ = isValidWord("test", lang: "en")
    }

    /// Годится ли слово как результат конверсии: системный словарь или скачанный частотный
    /// пак (сленг, имена, новые слова). Пак только для этой стороны: в субтитрах есть мусор
    /// («nen», «зна», «истори»), и для набранного слова и разбора хвоста он дал бы ложные
    /// «это слово» — там строгий isValidWord. Короче трёх букв в паке слов нет.
    @MainActor static func isValidTarget(_ word: String, lang: String) -> Bool {
        if word.count >= 4, BrandWords.all.contains(word.lowercased()) { return true }   // #34
        if word.count >= 3, let pack = FrequencyPacks.pack(for: lang), pack.contains(word.lowercased()) {
            return true
        }
        return isValidWordOrName(word, lang: lang)
    }

    /// 3.5.0b: слово словаря или имя собственное. Системный словарь знает «Яндекс», «Авито»,
    /// «Петербург» только с заглавной, а сюда слово приходит в нижнем регистре. Только для
    /// стороны цели (isValidTarget и разбор хвоста в plan): набранное проверяется строгим
    /// isValidWord, ветка иврита этот путь не зовёт. Только целиком буквенные: NSSpellChecker
    /// режет «Ub,,c» на «Ub» и «c», и с заглавной такие куски проходят как имена (стенд:
    /// «гиббс», «клэр» ложно уходили в латиницу). Порог в 4 буквы подтверждён стендом
    /// (docs/tools/autobench/run_head.sh).
    @MainActor static func isValidWordOrName(_ word: String, lang: String) -> Bool {
        if isValidWord(word, lang: lang) { return true }
        return word.count >= 4 && word.allSatisfy({ $0.isLetter })
            && isValidWord(capitalizedFirst(word), lang: lang)
    }

    static func capitalizedFirst(_ w: String) -> String { w.prefix(1).uppercased() + w.dropFirst() }

    /// true — слово есть в системном словаре языка (орфография корректна).
    @MainActor static func isValidWord(_ word: String, lang: String) -> Bool {
        let range = checker.checkSpelling(of: word, startingAt: 0, language: lang,
                                          wrap: false, inSpellDocumentWithTag: 0, wordCount: nil)
        return range.location == NSNotFound
    }
}

enum LayoutVerdict { case switchToConverted, keep, undecided }

/// Решает, набрано ли слово в неправильной раскладке. Точность важнее полноты:
/// при любой неуверенности → .undecided (ничего не делаем). Ручной триггер остаётся.
enum LayoutDetector {
    @MainActor
    static func decide(typed: String, converted: String, currentLang: String, otherLang: String, capsLock: Bool) -> LayoutVerdict {
        // always-convert — ЯВНЫЙ override: матчим по СКОНВЕРТИРОВАННОЙ (целевой) форме.
        // В список кладётся целевое слово (напр. «жоппа»); так правильно набранное слово
        // не даёт пинг-понг. Жёсткие гейты (secure/denied-app/never) проверены ДО decide.
        if AutoSwitchPolicy.isAlwaysConvert(converted) { return .switchToConverted }

        // --- мягкие вето (дёшево, до словаря) ---
        // 1 буква — не трогаем никогда (неоднозначность запредельная). 2 буквы —
        // отдельная ветка ниже через частотный список (ShortWords), т.к. на такой длине
        // системный словарь ненадёжен; 3+ — обычный путь через NSSpellChecker.
        guard typed.count >= 2 else { return .undecided }
        // Обычный путь — набранное целиком буквенное. Плюс (issue #22, п.3) случай «буквы
        // на клавишах-пунктуации»: ё/х/ъ/ж/э/б/ю в ЙЦУКЕН живут на ` [ ] ; ' , . — тогда
        // typed содержит эти знаки, но КОНВЕРСИЯ целиком буквенная, и решает словарь ниже.
        // Хвостовые . , ; : уже отщеплены вызывающим (#15) + walk неоднозначности, поэтому
        // сюда доходит только начальная/срединная пунктуация («`krf»→ёлка, «rf;tncz»→
        // кажется) — там трактовки-как-знак-препинания нет, а «дел.»/«думаю» отсеяны выше.
        guard typed.allSatisfy({ $0.isLetter }) || converted.allSatisfy({ $0.isLetter }) else {
            return .undecided // цифры/URL/код/почта/эмодзи
        }
        // Под Caps Lock весь текст в ВЕРХНЕМ регистре — это НЕ акроним и НЕ camelCase,
        // поэтому эти два вето применяем только когда Caps Lock выключен.
        if !capsLock {
            if isAllCaps(typed) { return .undecided }                      // акронимы
            if looksLikeCodeIdentifier(typed) { return .undecided }        // camelCase / смешанные алфавиты
        }

        let cur = String(currentLang.prefix(2))
        let oth = String(otherLang.prefix(2))

        // --- Кросс-скрипт пары с ивритом (3.0) ---
        // Системный ивритский словарь macOS для детекта БЕСПОЛЕЗЕН: он принимает любой
        // набор букв как «валидное слово» (проверено эмпирически), двусторонняя проверка
        // на стороне иврита невозможна. Поэтому конвертим ТОЛЬКО при положительном
        // сигнале второй (не-ивритской) стороны — её собственным словарём:
        //   • набрано в иврит-раскладке, а конверсия — валидное слово второй раскладки
        //     → задумана она, конвертим;
        //   • набрано во второй раскладке и это её валидное слово → keep (не трогаем);
        //   • всё остальное (имена, бренды, опечатки, «задуман иврит») → .undecided:
        //     направление «в иврит» без словаря честно не решаемо — точность важнее
        //     полноты. Ручной триггер конвертирует любые пары всегда.
        // Второй словарь берём по ЯЗЫКУ ПАРЫ (ru/de/fr/…), не хардкодим en — иначе
        // пара русский+иврит конвертила бы каждое валидное русское слово в иврит
        // (ревью-находка июльского аудита).
        if isHebrew(cur) || isHebrew(oth) {
            guard typed.count >= 3 else { return .undecided }              // короткий частотный сигнал для иврита не строим
            let hebrewIsCurrent = isHebrew(cur)
            let sideLang = hebrewIsCurrent ? oth : cur
            guard !isHebrew(sideLang), Dict.isAvailable(sideLang) else { return .undecided }
            if hebrewIsCurrent {
                // Набрано частое ивритское слово: его образ в другой раскладке бывает настоящим
                // словом («בוא» → «cut», «מקבל» → «neck»), а проверить набранное системным
                // словарём нельзя (он принимает любые буквы). Такое слово не трогаем.
                if HebrewCommonWords.contains(typed) { return .keep }
                // NSSpellChecker токенизирует («привет!» для него валиден), а часть ивритских
                // букв живёт на пунктуационных клавишах — EN-образ КОРРЕКТНОГО иврита может
                // получиться «слово + пунктуация» и ложно пройти словарь (ревью-находка,
                // тот же класс, что «думаю vs дума.» в 2.7.0). Словарю отдаём только
                // целиком буквенный образ; иначе .undecided — ручной триггер работает.
                guard converted.allSatisfy({ $0.isLetter }) else { return .undecided }
                // Строгий системный словарь, не пак: второй проверки (набранного иврита) тут нет,
                // и мусор субтитров («thi», «gus») портил бы правильно набранный иврит.
                return Dict.isValidWord(converted.lowercased(), lang: sideLang)
                    ? .switchToConverted : .undecided
            }
            return Dict.isValidWord(typed.lowercased(), lang: sideLang) ? .keep : .undecided
        }

        // --- Короткие (2-буквенные) слова: позитивный частотный сигнал (3.1, issue #22) ---
        // NSSpellChecker на длине 2 принимает почти любой набор букв за «слово», поэтому
        // обычная двусторонняя проверка тут ненадёжна (ради этого и стоял гейт count>=3).
        // Вместо словаря — компактный список ЧАСТЫХ коротких слов (ShortWords), строго как
        // позитивный сигнал: конвертим 2 буквы ТОЛЬКО если конверсия — частое слово целевого
        // языка, а набранное — не частое слово текущего (симметрия как у иврит-ветки).
        // Коллизий «частое↔частое» нет (аудит образов раскладки). Пары с языком без списка
        // сюда не попадают → 2-буквенные, как и раньше, не трогаются.
        if typed.count == 2 {
            guard let othShort = ShortWords.common(oth) else { return .undecided }
            if let curShort = ShortWords.common(cur), curShort.contains(typed.lowercased()) {
                return .keep   // уже частое слово в текущей раскладке — не трогаем
            }
            return othShort.contains(converted.lowercased()) ? .switchToConverted : .undecided
        }

        // Словарь — без учёта регистра (Caps Lock не должен мешать определению слова).
        guard Dict.isAvailable(oth) else { return .undecided }
        guard Dict.isValidTarget(converted.lowercased(), lang: oth) else { return .keep }
        // NSSpellChecker токенизирует по любому не-букве: «k.lb» для него «k» + «lb», «dc§» —
        // «dc», и оба «валидны», поэтому «люди» и «всё» оставались набранными. Словом текущего
        // языка набранное считаем, только если это буквы (апостроф внутри допустим) с
        // возможной пунктуацией на конце: «he,» — англ. «he» с запятой, тут токенизация как
        // раз защищает от «руб».
        // Двухбуквенное тело с знаком («im.» → «шью» после разбора хвоста) словарь не
        // различает, поэтому ещё и частотный список коротких слов текущего языка.
        if Dict.isAvailable(cur), let body = wordBody(typed) {
            if Dict.isValidWord(typed.lowercased(), lang: cur) { return .keep }
            if body.count == 2, ShortWords.common(cur)?.contains(body.lowercased()) == true { return .keep }
        }
        return .switchToConverted
    }

    /// Тело слова без пунктуации на конце, если набранное похоже на слово (буквы, апостроф
    /// внутри допустим); иначе nil.
    static func wordBody(_ s: String) -> Substring? {
        let trailing: Set<Character> = [",", ".", "!", "?", ";", ":", ")"]
        var body = s[...]
        while let last = body.last, trailing.contains(last) { body = body.dropLast() }
        guard !body.isEmpty, body.allSatisfy({ $0.isLetter || $0 == "'" || $0 == "’" }) else { return nil }
        return body
    }

    /// Знаки, которые не бывают ни частью слова, ни концом фразы сразу после слова.
    /// В ЙЦУКЕН на этих клавишах ё, х, ъ (issue #35).
    static let neverInWord: Set<Character> = ["`", "[", "]"]

    enum TrailingResolution: Equatable {
        case ambiguous
        /// Сколько символов хвоста на самом деле буквы слова (0 = хвост целиком пунктуация).
        case extend(Int)
    }

    /// Хвост слова: где кончается слово, а где начинается пунктуация (issue #15 → #35).
    /// Клавиши . , ; ` [ ] в EN — это буквы ю б ж ё х ъ в ЙЦУКЕН, поэтому «levf.» — это
    /// «дума.» или «думаю». Перебираем разрезы: слово = ядро + k букв хвоста, остаток
    /// хвоста — литерал. Разрез правдоподобен, если слово за ним словарное (длиннее одной
    /// буквы: однобуквенные «и», «в», «о» словарь принимает всегда) и следующий набранный
    /// знак может закончить слово — ` [ ] не может. Один правдоподобный разрез → он и есть;
    /// два и больше («дума.» / «думаю») → неоднозначность, точность важнее полноты;
    /// ни одного → как раньше, ядро без хвоста (решает decide).
    static func resolveTrailing(typed: [Character], converted: [Character], coreLength: Int,
                                isValid: (String) -> Bool) -> TrailingResolution {
        var letters = 0
        while coreLength + letters < converted.count, converted[coreLength + letters].isLetter { letters += 1 }
        guard letters > 0 else { return .extend(0) }
        var plausible: [Int] = []
        for k in 0...letters {
            let end = coreLength + k
            if k < letters, neverInWord.contains(typed[end]) { continue }
            guard end >= 2, isValid(String(converted[..<end]).lowercased()) else { continue }
            plausible.append(k)
            if plausible.count > 1 { return .ambiguous }
        }
        return .extend(plausible.first ?? 0)
    }

    enum AutoPlan: Equatable {
        case convert(coreLength: Int)
        case skip(LayoutVerdict)
        case ambiguous
    }

    /// Решение автоконверсии по слову целиком: отщепить хвост (#15), разобрать его (#35),
    /// спросить decide. typed/converted — полное слово; canSplit — инвариант «1 клавиша =
    /// 1 символ» (при слиянии графем хвост не трогаем). coreLength в .convert — сколько
    /// символов конвертировать; остальное возвращается в поле литералом.
    /// suffixConvertible — хвост будет переведён сквозь пару (не так для текста, проброшенного
    /// удалёнкой: там он остаётся литералом), см. trailingCoreLength.
    @MainActor
    static func plan(typed: String, converted: String, canSplit: Bool,
                     currentLang: String, otherLang: String, capsLock: Bool,
                     suffixConvertible: Bool = true) -> AutoPlan {
        let t = Array(typed), c = Array(converted)
        var coreLength = t.count
        let core = trailingCoreLength(typed: typed, converted: converted, suffixConvertible: suffixConvertible)
        if canSplit, core < t.count, core > 0, c.count == t.count {
            coreLength = core
            // Для пар с ивритом разбор не нужен: направление «в иврит» авто-путём не
            // конвертится by design, а ивритский словарь принимает любые буквы.
            if !isHebrew(otherLang), Dict.isAvailable(otherLang) {
                let oth = String(otherLang.prefix(2))
                switch resolveTrailing(typed: t, converted: c, coreLength: coreLength,
                                       isValid: { Dict.isValidWord($0, lang: oth) }) {
                case .ambiguous: return .ambiguous
                case .extend(let k):
                    // 3.5.0b: ядро не слово, разреза строгий словарь не нашёл, а буквы целиком — имя
                    // («lilhl;» → «Джордж», «dbrnjhb.» → «Викторию»): конвертируем слово
                    // целиком. Иначе ушло бы одно ядро («джорд;»). В сам разбор имена не
                    // берём: «Котору», «Каку» с заглавной проходят, и «которую» стало бы
                    // неоднозначным (стенд).
                    var end = coreLength
                    while end < c.count, c[end].isLetter { end += 1 }
                    if k == 0, end > coreLength,
                       !Dict.isValidWord(String(c[..<coreLength]).lowercased(), lang: oth),
                       Dict.isValidWordOrName(String(c[..<end]).lowercased(), lang: oth) {
                        coreLength = end
                    } else {
                        coreLength += k
                    }
                }
            }
        }
        let verdict = decide(typed: String(t[..<coreLength]), converted: String(c[..<coreLength]),
                             currentLang: currentLang, otherLang: otherLang, capsLock: capsLock)
        return verdict == .switchToConverted ? .convert(coreLength: coreLength) : .skip(verdict)
    }

    /// issue #15: отщепляет прилипшую к концу слова пунктуацию ("ghbdtn," → ядро 6 + ",").
    /// Ядро детектится и конвертится как обычно, хвост возвращается в поле ЛИТЕРАЛОМ —
    /// конвертировать его по кейкодам нельзя: клавиша ',' в EN — это 'б' в RU, а
    /// запятая RU (Shift+6) в EN — '^'. Набор консервативный: цифры, дефис, @/#
    /// НЕ отщепляем — для URL/кода/почты вето детектора отрабатывает по делу.
    /// Кавычки ' и " исключены сознательно: смарт-пунктуация приложений подменяет их
    /// типографскими, а на dead-key раскладках (U.S. International) апостроф — dead key;
    /// оба случая ломают счёт/литеральность. «…»/«»/– недостижимы из буфера (Option-слой).
    /// ВАЖНО: '.', ',', ';', ':' в EN — клавиши букв ю/б/ж/Ж в ЙЦУКЕН, поэтому вызывающий
    /// ОБЯЗАН проверить полную конверсию по словарю (неоднозначность «думаю» vs «дума.»).
    /// Также ` [ ] — клавиши ё/х/ъ: отщепляем их с хвоста, чтобы тот же walk неоднозначности
    /// сработал симметрично (issue #22-скептик: иначе «ружьё»/«цех» шли бы мимо проверки).
    static func splitTrailingPunctuation(_ s: String) -> (coreLength: Int, suffix: String) {
        var core = s[...]
        while let last = core.last, trailingPunct.contains(last) { core = core.dropLast() }
        return (core.count, String(s.dropFirst(core.count)))
    }

    static let trailingPunct: Set<Character> = [",", ".", "!", "?", ";", ":", ")", "`", "[", "]"]

    /// Знаки конца фразы, которые переводим сквозь пару раскладок (#33, #41); тот же список
    /// ограничивает DynamicKeyMapping.punctApply.
    static let sentencePunctuation: Set<Character> = Set("?,.!;:…")

    /// Где кончается слово (#15, #41). С конца отщепляем знаки из trailingPunct и ещё символы,
    /// на месте которых в целевой раскладке стоит знак конца фразы. На «Русской — ПК» Shift+6
    /// («^» в английской) — двоеточие, на маковской «Русской» Shift+6 и Shift+7 («^», «&») —
    /// запятая и точка: без этого «ntcn^» целиком шло в детектор как слово со странным
    /// символом, и любое слово перед запятой или в конце фразы оставалось как есть. Второе
    /// правило — только когда хвост будет переведён (suffixConvertible), иначе вышло бы «тест^».
    /// Ту же длину ядра берёт проверка «Никогда не конвертировать».
    static func trailingCoreLength(typed: String, converted: String, suffixConvertible: Bool) -> Int {
        let t = Array(typed), c = Array(converted)
        guard suffixConvertible, c.count == t.count else { return splitTrailingPunctuation(typed).coreLength }
        var core = t.count
        while core > 0 {
            let ch = t[core - 1]
            // @ и # не трогаем, как и в trailingPunct: почта, теги (на испанской и болгарской
            // парах на их клавишах стоят «!» и «?»).
            let symbol = !ch.isLetter && !ch.isNumber && (ch.isPunctuation || ch.isSymbol) && ch != "@" && ch != "#"
            guard trailingPunct.contains(ch) || (symbol && sentencePunctuation.contains(c[core - 1])) else { break }
            core -= 1
        }
        return core
    }

    /// Язык — иврит (BCP-47 `he` или устаревший `iw`). 3.0: гейт кросс-скрипт-детекта.
    static func isHebrew(_ lang: String) -> Bool {
        let two = lang.lowercased().prefix(2)
        return two == "he" || two == "iw"
    }

    static func isAllCaps(_ s: String) -> Bool {
        s == s.uppercased() && s != s.lowercased()
    }

    /// Похоже на программный идентификатор: внутренняя заглавная (camelCase/PascalCase)
    /// или смешение латиницы и кириллицы в одном токене → почти всегда код, не слово.
    static func looksLikeCodeIdentifier(_ s: String) -> Bool {
        for (i, c) in s.enumerated() where i > 0 && c.isUppercase { return true }
        var hasLatin = false, hasCyrillic = false
        for u in s.unicodeScalars {
            switch u.value {
            case 0x41...0x5A, 0x61...0x7A: hasLatin = true
            case 0x0400...0x04FF: hasCyrillic = true
            default: break
            }
        }
        return hasLatin && hasCyrillic
    }
}

/// Политика безопасности авто-конвертации.
enum AutoSwitchPolicy {
    /// Активен ли защищённый ввод (поле пароля, Secure Keyboard Entry в терминале) —
    /// тогда авто-конвертацию НЕ делаем (приватность; пароль не трогаем).
    static var secureInputActive: Bool { IsSecureEventInputEnabled() }

    /// Имя приложения, удерживающего защищённый ввод (Word, Terminal, менеджер
    /// паролей, loginwindow при системном запросе пароля и т.п.), или nil если
    /// определить не удалось. Читаем PID из IORegistry (то же, что `ioreg`:
    /// IOConsoleUsers → kCGSSessionSecureInputPID) и резолвим в человекочитаемое имя.
    static func secureInputHolderName() -> String? {
        let entry = IORegistryEntryFromPath(kIOMainPortDefault, "IOService:/IOResources")
        guard entry != 0 else { return nil }
        defer { IOObjectRelease(entry) }
        guard let sessions = IORegistryEntryCreateCFProperty(
            entry, "IOConsoleUsers" as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue() as? [[String: Any]] else { return nil }
        for s in sessions {
            guard let raw = s["kCGSSessionSecureInputPID"] as? Int, raw != 0 else { continue }
            let pid = pid_t(raw)
            if let app = NSRunningApplication(processIdentifier: pid)?.localizedName, !app.isEmpty {
                return app
            }
            var buf = [CChar](repeating: 0, count: 4096)      // системные процессы (loginwindow) — не GUI-приложения
            let len = proc_pidpath(pid, &buf, 4096)
            if len > 0 {
                let bytes = buf.prefix(Int(len)).map { UInt8(bitPattern: $0) }
                let name = (String(decoding: bytes, as: UTF8.self) as NSString).lastPathComponent
                if !name.isEmpty { return name }
            }
            return nil
        }
        return nil
    }

    /// Дефолтный список приложений, где авто выключено: терминалы, IDE, менеджеры
    /// паролей. Возвращается, пока пользователь не отредактировал список
    /// (см. SettingsManager.deniedApps). Запись с суффиксом "*" — префикс (весь вендор).
    static let defaultDeniedApps: [String] = [
        "com.apple.Terminal", "com.googlecode.iterm2", "net.kovidgoyal.kitty",
        "io.alacritty", "com.github.wez.wezterm", "dev.warp.Warp-Stable", "co.zeit.hyper",
        "com.apple.dt.Xcode", "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders",
        "com.sublimetext.4", "com.todesktop.230313mzl4w4u92", "com.google.android.studio",
        "com.jetbrains.*",
        "com.1password.1password", "com.agilebits.onepassword7",
        "com.bitwarden.desktop", "org.keepassxc.keepassxc",
    ]

    /// Менеджеры паролей — несъёмные из списка в UI (безопасность).
    static let protectedApps: Set<String> = [
        "com.1password.1password", "com.agilebits.onepassword7",
        "com.bitwarden.desktop", "org.keepassxc.keepassxc",
    ]

    /// Терминалы: в них нет OS-выделения текста, поэтому «конвертация строки» (#24) через
    /// Shift+Cmd+← не выделяет строку, а в Terminal.app клавиши протекают мусором. Для них
    /// режим «вся строка» деградирует на буферный путь (последнее слово — он в терминалах
    /// работает, backspace+перепечатка). Список — терминалы из defaultDeniedApps.
    static let terminalApps: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "net.kovidgoyal.kitty",
        "io.alacritty", "com.github.wez.wezterm", "dev.warp.Warp-Stable", "co.zeit.hyper",
    ]
    static func isTerminalApp(_ bundleID: String?) -> Bool {
        guard let id = bundleID else { return false }
        return terminalApps.contains(id)
    }

    static let browsers: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.dev", "com.google.Chrome.canary",
        "org.chromium.Chromium", "com.apple.Safari", "com.apple.SafariTechnologyPreview",
        "org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition", "org.mozilla.nightly",
        "ru.yandex.desktop.yandex-browser", "com.microsoft.edgemac", "com.brave.Browser",
        "com.operasoftware.Opera", "com.vivaldi.Vivaldi", "company.thebrowser.Browser",
        "company.thebrowser.dia", "app.zen-browser.zen",
    ]
    static func isBrowser(_ bundleID: String?) -> Bool {
        guard let id = bundleID else { return false }
        return browsers.contains(id)
    }

    static func isDeniedApp(_ bundleID: String?) -> Bool {
        guard let id = bundleID else { return false }
        // Менеджеры паролей — жёсткий, не зависящий от пользовательского списка гейт:
        // их нельзя разблокировать ни через UI, ни через рассинхрон дефолтов.
        if protectedApps.contains(id) { return true }
        for entry in SettingsManager.shared.deniedApps {
            if entry.hasSuffix("*") {
                if id.hasPrefix(String(entry.dropLast())) { return true }
            } else if entry == id {
                return true
            }
        }
        return false
    }

    /// Слово в списке never-convert (обе стороны пары, без регистра).
    static func isDeniedWord(_ typed: String, _ converted: String) -> Bool {
        let set = SettingsManager.shared.deniedWordsSet
        guard !set.isEmpty else { return false }
        return set.contains(typed.lowercased()) || set.contains(converted.lowercased())
    }

    /// Слово в списке always-convert — матчим по СКОНВЕРТИРОВАННОЙ (целевой) форме.
    /// В список кладётся «целевое» слово (что должно получиться), а не мусор раскладки —
    /// иначе правильно набранное слово конвертилось бы обратно (пинг-понг).
    static func isAlwaysConvert(_ converted: String) -> Bool {
        let set = SettingsManager.shared.alwaysConvertWordsSet
        guard !set.isEmpty else { return false }
        return set.contains(converted.lowercased())
    }

    /// Клиенты удалённого рабочего стола: когда такое окно в фокусе, текст живёт
    /// на ДРУГОЙ машине — наш инстанс должен молчать и уступить удалённому RuSwitcher.
    static let remoteClients: Set<String> = [
        "com.apple.ScreenSharing",   // Apple «Общий экран» / Screen Sharing.app
        "com.apple.RemoteDesktop",   // Apple Remote Desktop
    ]

    static func isRemoteDesktopClient(_ bundleID: String?) -> Bool {
        guard let id = bundleID else { return false }
        return remoteClients.contains(id)
    }

    /// Правило «уступи удалёнке»: режим удалённого стола включён И в фокусе клиент
    /// удалёнки → этот инстанс ничего не делает (ни триггер, ни авто), чтобы не
    /// дублировать работу инстанса на контролируемой машине.
    static var shouldDeferToRemoteClient: Bool {
        guard SettingsManager.shared.remoteDesktopMode else { return false }
        return isRemoteDesktopClient(NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
    }
}
