import Foundation

/// Детектор «не та раскладка» по НЕЗАКОНЧЕННОМУ слову — конверсия прямо во время набора,
/// не дожидаясь пробела (поведение Caramba Switcher).
///
/// Почему не словарём, как `LayoutDetector`: словарь судит только о целом слове, по префиксу
/// «ghb» он молчит. Здесь работают две модели, обе про начало слова и обе без XPC — только
/// чтение битов, поэтому их не страшно гнать на каждую нажатую букву:
///
///  1. Статистика буквосочетаний (`NGramTables`): «ghb» для английского невозможно, а «при»
///     для русского обычно.
///  2. Начала настоящих слов (`WordPrefixes`): «при» начинает живые русские слова, «ghb» —
///     никакие английские.
///
/// Поодиночке каждая ошибается, и по-разному. Статистика честно считает «http» невозможным
/// сочетанием — сам по себе этот детектор превращал бы «htt» в «рее». Словарь начал слов, наоборот,
/// объявляет мусором любое редкое слово вне корпуса. Поэтому конвертируем ТОЛЬКО при согласии
/// обеих. Замер (учили на 80% корпуса, ложные считали на отложенных 20% и на словаре Вебстера
/// как «редкие слова»): 0,14% ложных на Вебстере против 0,27% и 0,40% у моделей по отдельности,
/// при отлове 79% русских слов, набранных в EN-раскладке (в среднем на 2,6-й букве), и 71%
/// английских, набранных в RU (на 2,5-й).
///
/// Оставшуюся четверть — где обе стороны выглядят правдоподобно — по-прежнему добирает
/// словарный путь на пробеле (`LayoutDetector`): эти проверки дополняют друг друга.
enum InstantDetector {
    /// Минимум букв. На одной букве сочетаний нет вообще, на двух работает пара «^ab» —
    /// этого уже хватает, чтобы поймать «gj» из «пожалуйста».
    static let minLength = 2

    /// true — набранное стоит немедленно сконвертировать и переключить раскладку.
    /// `typed`/`converted` — то же, что отдаёт `DynamicKeyMapping.convertKeys` для буфера
    /// текущего слова; языки — от `LayoutSwitcher.currentAndOppositeLanguage()`.
    static func shouldSwitch(typed: String, converted: String,
                             currentLang: String, otherLang: String, capsLock: Bool) -> Bool {
        // Пары без таблиц (иврит, немецкий, любая третья раскладка) молчат — их обслуживает
        // словарный путь на пробеле. Статистику под каждый язык нужно генерировать отдельно.
        guard let cur = language(currentLang), let oth = language(otherLang) else { return false }
        guard typed.count >= minLength, typed.count == converted.count else { return false }

        // Акронимы (BBC, NHS) — сплошь заглавные, и в чужой раскладке легко выглядят
        // правдоподобным словом. Вето то же, что у словарного детектора, и по той же причине
        // снимается под Caps Lock: там ВЕСЬ текст заглавный, это не акроним.
        if !capsLock, LayoutDetector.isAllCaps(typed) { return false }

        let t = typed.lowercased()
        let c = converted.lowercased()
        // Конверсия должна быть чистым словом чужого алфавита: цифры, пунктуация и обрывки
        // (URL, код, почта) сразу выводят из игры — их «конверсия» ничего не значит.
        guard oth.ngrams.isPureAlphabet(c) else { return false }

        // Сигналы «за»: конверсия и по сочетаниям обычна, и начинает настоящие слова.
        guard oth.ngrams.allowsAll(c), oth.prefixes.isWordStart(c) else { return false }
        // Сигналы «против»: набранное невозможно в своём языке И не начинает ни одного его
        // слова. Символ вне алфавита (пунктуация на месте букв ж/э/б/ю в ЙЦУКЕН) считается
        // невозможным сочетанием — и по делу: «ghbdtn;» в английском не слово.
        return cur.ngrams.hasImpossible(t) && !cur.prefixes.isWordStart(t)
    }

    /// Разворачивает таблицы из base64 заранее (вызывается из прогрева на старте) — чтобы
    /// первая же набранная буква не платила за инициализацию статики.
    static func warmUp() {
        _ = shouldSwitch(typed: "ghb", converted: "при", currentLang: "en", otherLang: "ru", capsLock: false)
        _ = shouldSwitch(typed: "зкщ", converted: "pro", currentLang: "ru", otherLang: "en", capsLock: false)
    }

    private static func language(_ lang: String) -> (ngrams: NGramSet, prefixes: PrefixBloom)? {
        switch String(lang.prefix(2)) {
        case "ru": return (NGramTables.ru, WordPrefixes.ru)
        case "en": return (NGramTables.en, WordPrefixes.en)
        default:   return nil
        }
    }
}
