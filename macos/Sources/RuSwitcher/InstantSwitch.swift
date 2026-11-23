import Foundation

/// Детектор «не та раскладка» по НЕЗАКОНЧЕННОМУ слову — конверсия прямо во время набора,
/// не дожидаясь пробела (поведение Caramba Switcher).
///
/// Почему не словарём, как `LayoutDetector`: словарь судит только о целом слове, по префиксу
/// «ghb» он молчит. Здесь работают две модели, обе про начало слова и обе без XPC — только
/// поиск в памяти, поэтому их не страшно гнать на каждую нажатую букву:
///
///  1. Буквосочетания: «^gh» + «ghb» для английского невозможны, а «^пр» + «при» для русского обычны.
///  2. Начала настоящих слов: «при» начинает живые русские слова, «ghb» — никакие английские.
///
/// Данных своих нет: обе модели строятся из частотных паков (`FrequencyPacks`) — тех же, что
/// включает «Расширенный словарь». Нет пака хотя бы одной стороны — детектор молчит.
///
/// Поодиночке каждая модель ошибается, и по-разному. Сочетания честно считают «http» невозможным —
/// сам по себе этот детектор превращал бы «htt» в «рее». Начала слов, наоборот, объявляют мусором
/// любое редкое слово вне пака. Поэтому конвертируем ТОЛЬКО при согласии обеих.
///
/// Замер на паках v1 (ru 50k, en 30k; ложные — с весом по частоте на 200k словоформ
/// FrequencyWords, то есть «на миллион слов живого текста», плюс словарь Вебстера):
/// отлов 91% русского текста, набранного в EN, и 75% английского в RU, в среднем на 2,4-2,5-й
/// букве; ложных 122 на миллион английских слов и 119 на миллион русских. Остаток — где обе стороны
/// правдоподобны — по-прежнему добирает конвейер конца слова: проверки дополняют друг друга.
enum InstantDetector {
    /// Минимум букв. На двух буквах сочетание уже есть («^gj»), и для «пожалуйста»/«по» это
    /// самый ранний и самый полезный сигнал: в боевом логе форка 94 срабатывания из 107 были
    /// двухбуквенными. Цена — двухбуквенные токены, см. `twoLetterTokens`.
    static let minLength = 2

    /// Префиксы длиннее не проверяем по пакам: дальше пяти букв уже хватает сочетаний,
    /// а длинный префикс редкого слова не начинал бы ни одного слова пака — ложный «мусор».
    private static let prefixMaxLength = 5

    /// true — набранное стоит немедленно сконвертировать и переключить раскладку.
    /// `typed`/`converted` — то же, что отдаёт `DynamicKeyMapping.convertKeys` для буфера
    /// текущего слова; языки — от `LayoutSwitcher.currentAndOppositeLanguage()`.
    @MainActor
    static func shouldSwitch(typed: String, converted: String,
                             currentLang: String, otherLang: String, capsLock: Bool) -> Bool {
        guard typed.count >= minLength, typed.count == converted.count else { return false }
        // Нет пака хотя бы одной стороны (словари выключены, язык без пака) — молчим.
        guard let cur = InstantModel.model(for: currentLang),
              let oth = InstantModel.model(for: otherLang) else { return false }

        // Акронимы (BBC, NHS) — сплошь заглавные, и в чужой раскладке легко выглядят
        // правдоподобным словом. Вето то же, что у словарного детектора, и по той же причине
        // снимается под Caps Lock: там ВЕСЬ текст заглавный, это не акроним.
        if !capsLock, LayoutDetector.isAllCaps(typed) { return false }

        let t = typed.lowercased()
        let c = converted.lowercased()
        // Одна и та же буква подряд — междометие или стук по клавише («ууу», «шшш», «dd»).
        // Сочетание «ууу» в паке не встречается, но мусором раскладки это не делает.
        if Set(t).count == 1 { return false }
        if t.count == 2, isTwoLetterToken(t, lang: currentLang) { return false }

        // Конверсия должна быть чистым словом чужого алфавита: цифры, пунктуация и обрывки
        // (URL, код, почта) сразу выводят из игры — их «конверсия» ничего не значит.
        guard oth.isPureAlphabet(c) else { return false }
        // Сигналы «за»: конверсия и по сочетаниям обычна, и начинает настоящие слова.
        guard !oth.hasImpossible(c), oth.isWordStart(String(c.prefix(prefixMaxLength))) else { return false }
        // Сигналы «против»: набранное невозможно в своём языке И не начинает ни одного его
        // слова. Символ вне алфавита (пунктуация на месте букв ж/э/б/ю в ЙЦУКЕН) считается
        // невозможным сочетанием — и по делу: «ghbdtn;» в английском не слово.
        return cur.hasImpossible(t) && !cur.isWordStart(String(t.prefix(prefixMaxLength)))
    }

    /// Двухбуквенное начало, которое само по себе — живой токен своего языка: на нём ждём
    /// третьей буквы. В паках нет слов короче трёх букв, поэтому для модели начал любой такой
    /// токен — «не слово», и «rm» (команда в терминале IDE) уходило бы в «кь» с первой же пары.
    /// Списки — частые двухбуквенные токены FrequencyWords (топ-400), оставлены только те, на
    /// которых правило без них срабатывает; плюс частые короткие слова `ShortWords` (их
    /// неоднозначные vs/dj/kb/jr/bp/ye/ds — там же). Замер: ложных 122/119 на миллион слов
    /// вместо 192/153, а на второй букве по-прежнему ловится 65% (без вето — 71%).
    @MainActor
    private static func isTwoLetterToken(_ t: String, lang: String) -> Bool {
        if let short = ShortWords.common(lang), short.contains(t) { return true }
        return twoLetterTokens[String(lang.prefix(2))]?.contains(t) ?? false
    }

    private static let twoLetterTokens: [String: Set<String>] = [
        "en": ["bc", "bt", "cg", "ck", "cv", "cw", "db", "dg", "dk", "dl", "dp", "fc", "fx", "gm",
               "gt", "hd", "ht", "iy", "jc", "jd", "jk", "jp", "kc", "ks", "kt", "ld", "lk", "lp",
               "lv", "lz", "nk", "nr", "pj", "pk", "qc", "rb", "rc", "rd", "rm", "rn", "rt", "tb",
               "tk", "tp", "uv", "vd", "xv", "ys"],
        "ru": ["лш", "пз", "пк", "цщ", "ый", "ым", "ын", "ыс", "ьы"],
    ]

    /// Собирает модели текущей пары раскладок заранее (зовётся из прогрева на старте) —
    /// чтобы первая набранная буква не платила за разбор пака (~50 тыс. слов, десятки мс).
    @MainActor
    static func warmUp() {
        guard SettingsManager.shared.instantConvert,
              let langs = LayoutSwitcher.currentAndOppositeLanguage() else { return }
        _ = InstantModel.model(for: langs.current)
        _ = InstantModel.model(for: langs.opposite)
    }
}

/// Модель одного языка, собранная из его частотного пака: допустимые триграммы (с маркером
/// начала слова «^») и сам пак для проверки начал слов. Пак = язык, не пара: детектор берёт две
/// модели и сравнивает «невозможно в своём / правдоподобно в чужом», поэтому новый пак в
/// манифесте автора сразу даёт все пары с этим языком.
@MainActor
final class InstantModel {
    /// Кэш по языку. Модель привязана к конкретному объекту пака: обновился пак или словари
    /// выключили (FrequencyPacks.reload) — объект другой или nil, модель пересобирается/гаснет.
    private static var cache: [String: InstantModel] = [:]

    private let pack: WordPack
    private let alphabet: Set<Character>
    private let trigrams: Set<String>

    static func model(for lang: String) -> InstantModel? {
        let code = String(lang.prefix(2))
        guard let pack = FrequencyPacks.pack(for: code) else {
            cache[code] = nil
            return nil
        }
        if let m = cache[code], m.pack === pack { return m }
        let m = InstantModel(pack: pack)
        cache[code] = m
        rslog("instant: model \(code) — \(m.trigrams.count) trigrams, \(m.alphabet.count) letters")
        return m
    }

    private init(pack: WordPack) {
        self.pack = pack
        // Алфавит — буквы, которые встречаются в словах пака: языки не захардкожены.
        // Слова с апострофом или дефисом в сочетания не идут — это не буквы алфавита.
        var letters = Set<Character>()
        var tri = Set<String>()
        pack.forEachWord { w in
            let chars = Array(w)
            guard chars.allSatisfy({ $0.isLetter }) else { return }
            letters.formUnion(chars)
            let s: [Character] = ["^"] + chars
            for i in 0..<(s.count - 2) { tri.insert(String(s[i...i + 2])) }
        }
        self.alphabet = letters
        self.trigrams = tri
    }

    /// Все ли символы строки — буквы этого языка (регистр уже нижний).
    func isPureAlphabet(_ s: String) -> Bool {
        !s.isEmpty && s.allSatisfy { alphabet.contains($0) }
    }

    /// Есть ли в слове сочетание, которого нет ни в одном слове пака. Символ вне алфавита
    /// (цифра, пунктуация) делает сочетание невозможным — это и есть сигнал «не та раскладка».
    func hasImpossible(_ word: String) -> Bool {
        let s: [Character] = ["^"] + Array(word)
        guard s.count >= 3 else { return false }   // короче двух букв судить не о чем
        for i in 0..<(s.count - 2) where !trigrams.contains(String(s[i...i + 2])) { return true }
        return false
    }

    /// Начинается ли с этой строки хоть одно слово пака.
    func isWordStart(_ prefix: String) -> Bool { pack.hasPrefix(prefix) }
}
