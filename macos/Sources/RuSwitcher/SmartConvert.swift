import Foundation

/// issue #22 (вариант B): умная по-словная конверсия ВЫДЕЛЕННОГО текста.
///
/// Обычный путь конвертирует всё выделение в одну сторону (по активной раскладке), поэтому
/// mixed-мусор «ghtlkj d ьшчув» чинится лишь наполовину. Здесь решаем ПО КАЖДОМУ СЛОВУ:
/// переворачиваем слово только если оно «мусор в своей письменности, но валидное слово после
/// флипа» (по системному словарю). Так mixed-мусор чинится целиком, а намеренное «iPhone
/// стоит»/«стоит,» остаются нетронутыми.
///
/// Точность важнее полноты (скептик #22):
/// • 2-буквенные — только через частотный ShortWords (NSSpellChecker на длине 2 ненадёжен);
/// • ALL-CAPS акронимы и camelCase/смешанные — пропускаем (те же гейты, что в decide);
/// • одиночную букву флипаем ТОЛЬКО в сторону реально флипнутых соседей — «z yt vjue»→
///   «я не могу» (вся фраза — не та раскладка), но «витамин c»/«число e» не трогаем (сосед
///   валиден и остался), т.к. «c»/«e» — научный символ, а не мусор.
///
/// Тумблер «Конвертировать по тексту» (A) идёт мимо — тотальный флип
/// (DynamicKeyMapping.convertBidirectional). Пары не «латиница+кириллица» — обычный путь.
enum SmartConvert {
    private enum Script { case cyr, lat, other, mixed }
    /// keepValid — слово ПОДТВЕРЖДЕНО словарём своего языка (не просто «не трогаем»). Отдельно
    /// от .keep, потому что для хвоста фразы это стоп-сигнал: см. lineTail.
    private enum WordDecision { case keep, keepValid, flip(String, Script), unresolved }

    // Частотные однобуквенные слова — доп. страховка для флипа ОДИНОЧНЫХ букв по сигналу.
    private static let cyr1: Set<Character> = ["я", "в", "с", "к", "о", "у", "а", "и"]
    private static let lat1: Set<Character> = ["a", "i"]

    /// Умная по-словная конверсия выделения. Возвращает обычную одностороннюю конверсию, если
    /// пара не латиница+кириллица или словари недоступны.
    @MainActor
    static func selection(_ text: String) -> String {
        guard let (latLang, cyrLang) = classifyPair(),
              Dict.isAvailable(latLang), Dict.isAvailable(cyrLang) else {
            return DynamicKeyMapping.convert(text)   // не Lat+Cyr пара — обычный путь
        }
        return run(text, latLang: latLang, cyrLang: cyrLang, forcedTarget: nil)
    }

    /// Хвост фразы при конверсии на лету: направление УЖЕ известно — его определил
    /// InstantDetector по текущему слову. Отличие от selection(): сигнал не выводится из
    /// соседей, а задан снаружи, поэтому короткие двусмысленные слова дотягиваются даже
    /// когда весь остальной хвост словарь подтвердить не смог — ровно случай «dj gfitn»,
    /// где «gfitn» опознано как «пашет», а «dj» само по себе честное английское слово.
    ///
    /// nil — «не трогать голову»: вызывающий тогда заменяет только текущее слово.
    ///
    /// ДОПУСК ГОЛОВЫ (боевая находка 19.08). Правим голову, только если КАЖДОЕ её слово —
    /// заведомый мусор: либо словарь подтверждает флип, либо слово короче трёх букв (там словарь
    /// и так не судья), либо это пунктуация с цифрами. Одно слово, подтверждённое словарём
    /// своего языка, или одно неразрешённое длинное (имя, бренд, термин) — отказ целиком.
    ///
    /// Ради чего так строго: ложное срабатывание на двух буквах уносило с собой уже набранную
    /// верную фразу. Длинные слова словарь отстаивал сам, а вот короткие («и», «в», «не»)
    /// дотягивались по заданному направлению и превращались в латинский мусор — 25 символов
    /// готового текста за один раз, дважды. Ради «dj gfitn» правило не мешает: там в голове
    /// одно двухбуквенное слово, подтверждать нечего.
    @MainActor
    static func lineTail(_ text: String, toCyrillic: Bool) -> String? {
        guard let (latLang, cyrLang) = classifyPair(),
              Dict.isAvailable(latLang), Dict.isAvailable(cyrLang) else { return nil }
        guard headIsGarbage(text, latLang: latLang, cyrLang: cyrLang) else { return nil }
        return run(text, latLang: latLang, cyrLang: cyrLang, forcedTarget: toCyrillic ? .cyr : .lat)
    }

    /// Целиком ли голова состоит из мусора — можно ли её переписывать (см. допуск в lineTail).
    @MainActor
    private static func headIsGarbage(_ text: String, latLang: String, cyrLang: String) -> Bool {
        for tok in tokenize(text) where tok.isWord {
            switch decideWord(tok.str, latLang: latLang, cyrLang: cyrLang, forcedTarget: nil) {
            case .keepValid:
                rslog("instant: line tail bail — в голове словарное слово")
                return false
            case .unresolved where letterCore(tok.str).count >= 3:
                rslog("instant: line tail bail — в голове нераспознанное слово")
                return false   // имя/бренд/термин: словарь его флип не подтвердил, не трогаем
            default:
                continue       // мусор с подтверждённым флипом, короткое слово, пунктуация
            }
        }
        return true
    }

    /// Кириллический ли язык (нужно вызывающему, чтобы задать направление lineTail).
    static func isCyrillic(lang: String) -> Bool { isCyrillicLang(lang) }

    @MainActor
    private static func run(_ text: String, latLang: String, cyrLang: String,
                            forcedTarget: Script?) -> String {
        let toks = tokenize(text)
        var results = [String?](repeating: nil, count: toks.count)
        var pending: [Int] = []                  // неразрешённые токены — решаем в пасе 2 по сигналу
        var flippedCyr = 0, flippedLat = 0

        // Пас 1 — валидные оставляем, распознанный мусор флипаем и считаем направление.
        for (i, tok) in toks.enumerated() {
            guard tok.isWord else { results[i] = tok.str; continue }
            switch decideWord(tok.str, latLang: latLang, cyrLang: cyrLang, forcedTarget: forcedTarget) {
            case .keep, .keepValid:
                results[i] = tok.str
            case let .flip(s, toScript):
                results[i] = s
                if toScript == .cyr { flippedCyr += 1 } else if toScript == .lat { flippedLat += 1 }
            case .unresolved:
                pending.append(i)
            }
        }

        // Сигнал — направление РЕАЛЬНО флипнутых соседей (не оставленных валидными): если всё
        // выделение флипается в одну сторону, значит это не та раскладка целиком → дотягиваем
        // и неразрешённые токены («до», имена, одиночные буквы) туда же. «z yt vjue»→«я не могу»,
        // «иду до дома», «Вася пришёл». Но «iPhone стоит»/«витамин c» — 0 флипов → сигнала нет →
        // не трогаем. Разнобой (оба скрипта флипались) → сигнала нет.
        let target: Script? = forcedTarget
                            ?? ((flippedCyr > 0 && flippedLat == 0) ? .cyr
                            :   (flippedLat > 0 && flippedCyr == 0) ? .lat : nil)

        // Пас 2 — неразрешённые по сигналу.
        for i in pending { results[i] = signalFlip(toks[i].str, target: target) }
        return results.map { $0 ?? "" }.joined()
    }

    /// Решение по слову. .flip несёт письменность РЕЗУЛЬТАТА (сигнал для пасса 2); .unresolved —
    /// кандидат на флип по сигналу соседей (мусор в своём скрипте, но словарём не подтверждён).
    @MainActor
    private static func decideWord(_ w: String, latLang: String, cyrLang: String,
                                   forcedTarget: Script?) -> WordDecision {
        let core = letterCore(w)
        let script = dominantScript(core)
        guard core.count >= 1, script == .cyr || script == .lat else { return .keep }
        // Акронимы и код — как в LayoutDetector.decide.
        if LayoutDetector.isAllCaps(core) || LayoutDetector.looksLikeCodeIdentifier(core) { return .keep }

        let wordLang = (script == .cyr) ? cyrLang : latLang
        let flipLang = (script == .cyr) ? latLang : cyrLang
        let flippedScript: Script = (script == .cyr) ? .lat : .cyr

        // 1 буква — по словарю не решаемо; только по сигналу соседей (пас 2).
        if core.count == 1 { return .unresolved }

        // 2 буквы — только частотный список (NSSpellChecker на длине 2 ненадёжен), как decide.
        if core.count == 2 {
            let whole = DynamicKeyMapping.convertBidirectional(w)
            let wc = letterCore(whole)
            let flipIsCommon = wc.count == 2 && (ShortWords.common(flipLang)?.contains(wc.lowercased()) ?? false)
            // Неоднозначные токены (vs, dj, kb, ye) лежат в ОБОИХ списках, чтобы без контекста
            // отклоняться в обе стороны — «Spain vs Italy» не должно стать «Spain мы Italy».
            // Но когда направление задано снаружи (конверсия на лету уже опознала язык фразы по
            // соседнему слову), контекст как раз есть: «dj» посреди русской фразы — это «во».
            if let forcedTarget, flippedScript == forcedTarget, flipIsCommon {
                return .flip(whole, flippedScript)
            }
            if let cur = ShortWords.common(wordLang), cur.contains(core.lowercased()) { return .keep }
            if flipIsCommon { return .flip(whole, flippedScript) }
            return .unresolved   // «до», «уж» и т.п. — не в списке → по сигналу
        }

        // 3+ — словарь. Уже валидное слово своего языка → не трогаем (iPhone, стоит).
        if Dict.isValidWord(core.lowercased(), lang: wordLang) { return .keepValid }
        // (1) флип целиком — ловит «ёлка» (`krf), «делю» (ltk.), «продолжение».
        let whole = DynamicKeyMapping.convertBidirectional(w)
        let wc = letterCore(whole)
        if wc.count >= 2, wc.allSatisfy({ $0.isLetter }), Dict.isValidWord(wc.lowercased(), lang: flipLang) {
            return .flip(whole, flippedScript)
        }
        // (2) со снятым хвостом реальной пунктуации — «ghtlkj;tybt,» → «продолжение» + «,».
        let (body, suffix) = splitTrailingNonLetters(w)
        if !suffix.isEmpty, !body.isEmpty {
            let bflip = DynamicKeyMapping.convertBidirectional(body)
            let bc = letterCore(bflip)
            if bc.count >= 2, bc.allSatisfy({ $0.isLetter }), Dict.isValidWord(bc.lowercased(), lang: flipLang) {
                return .flip(bflip + suffix, flippedScript)
            }
        }
        return .unresolved   // имя/бренд/термин, словарём не подтверждён → по сигналу
    }

    /// Флипаем неразрешённый токен ТОЛЬКО при явном сигнале (соседи флипнулись в одну сторону)
    /// и только если сам токен в ДРУГОМ скрипте (флип ведёт к target). Флипаем лишь буквенное
    /// ядро, окружающую пунктуацию сохраняем: «lj,»→«до,», «z»→«я». Одиночную букву дополнительно
    /// страхуем частотным списком (её флип должен быть частым 1-букв. словом target).
    /// ВАЖНО: главная защита научных «c»/«e» — ОТСУТСТВИЕ сигнала (сосед-слово валиден → target
    /// nil → сюда не входим). При СИЛЬНОМ сигнале «c»/«e» всё же флипаются (c→с, e→у — частотные
    /// 1-букв. слова), т.е. это часть агрессивности «умной» (по решению владельца, вариант A).
    private static func signalFlip(_ orig: String, target: Script?) -> String {
        guard let target else { return orig }
        var lead = "", trail = ""
        var chars = Array(orig)
        while let f = chars.first, !f.isLetter { lead.append(f); chars.removeFirst() }
        while let l = chars.last, !l.isLetter { trail = String(l) + trail; chars.removeLast() }
        let core = String(chars)
        guard !core.isEmpty, dominantScript(core) != target else { return orig }
        // Скептик 3.2.0 (#4/#6): 3+ буквенные неразрешённые по сигналу НЕ тянем — раз словарь их
        // флип не подтвердил (иначе были бы .flip в decideWord), это скорее иностранное слово/
        // бренд/термин (Github, гугл), а не мусор. Реальные слова и известные имена (Вася,
        // Комаров) словарь ловит в decideWord. Тянем только 1–2 буквы («до», «z») — их словарь
        // на длине 1–2 надёжно не решает, а частотные функц. слова важно дочинить.
        guard core.count <= 2 else { return orig }
        let flipped = DynamicKeyMapping.convertBidirectional(core)
        if core.count == 1 {                                    // одиночная — доп. страховка
            guard let fch = letterCore(flipped).first,
                  (target == .cyr ? cyr1 : lat1).contains(Character(fch.lowercased())) else { return orig }
        }
        return lead + flipped + trail
    }

    // MARK: - Helpers

    /// Классификация пары раскладок: (латинский язык, кириллический язык) или nil, если пара
    /// не «латиница+кириллица» (тогда умный путь неприменим).
    @MainActor
    private static func classifyPair() -> (latLang: String, cyrLang: String)? {
        guard let (a, b) = LayoutSwitcher.currentAndOppositeLanguage() else { return nil }
        let aCyr = isCyrillicLang(a), bCyr = isCyrillicLang(b)
        let aLat = isLatinLang(a), bLat = isLatinLang(b)
        if aCyr && bLat { return (b, a) }
        if bCyr && aLat { return (a, b) }
        return nil
    }

    private static let cyrillicLangs: Set<String> = ["ru", "uk", "be", "bg", "sr", "mk", "kk", "ky", "mn", "tg"]
    private static func isCyrillicLang(_ lang: String) -> Bool {
        cyrillicLangs.contains(String(lang.lowercased().prefix(2)))
    }
    // Латинская письменность = не кириллица и не иврит/греческий/армянский/грузинский/арабский.
    private static let nonLatinLangs: Set<String> = ["he", "iw", "el", "hy", "ka", "ar", "fa", "yi"]
    private static func isLatinLang(_ lang: String) -> Bool {
        let two = String(lang.lowercased().prefix(2))
        return !cyrillicLangs.contains(two) && !nonLatinLangs.contains(two)
    }

    private static func dominantScript(_ s: String) -> Script {
        var cyr = 0, lat = 0
        for u in s.unicodeScalars {
            if u.value >= 0x0400 && u.value <= 0x04FF { cyr += 1 }
            else if (u.value >= 0x41 && u.value <= 0x5A) || (u.value >= 0x61 && u.value <= 0x7A) { lat += 1 }
        }
        if cyr > 0 && lat > 0 { return .mixed }
        if cyr > 0 { return .cyr }
        if lat > 0 { return .lat }
        return .other
    }

    /// Слово без окружающих не-букв (для проверки по словарю). «`krf»→«krf», «дел.»→«дел».
    private static func letterCore(_ s: String) -> String {
        var chars = Array(s)
        while let f = chars.first, !f.isLetter { chars.removeFirst() }
        while let l = chars.last, !l.isLetter { chars.removeLast() }
        return String(chars)
    }

    /// Отделяет хвост НЕ-букв (реальную пунктуацию) от тела слова: «прод,»→(«прод»,«,»).
    private static func splitTrailingNonLetters(_ s: String) -> (body: String, suffix: String) {
        var body = Array(s); var suffix = ""
        while let l = body.last, !l.isLetter { suffix = String(l) + suffix; body.removeLast() }
        return (String(body), suffix)
    }

    /// Разбивает текст на чередующиеся куски: слова (не-пробелы) и разделители (пробелы),
    /// сохраняя всё — сборка обратно даёт исходную длину.
    private static func tokenize(_ s: String) -> [(isWord: Bool, str: String)] {
        var out: [(Bool, String)] = []
        var cur = ""
        var curWS: Bool? = nil
        for ch in s {
            let ws = ch.isWhitespace
            if let w = curWS {
                if ws == w { cur.append(ch) }
                else { out.append((!w, cur)); cur = String(ch); curWS = ws }
            } else {
                curWS = ws; cur = String(ch)
            }
        }
        if let w = curWS, !cur.isEmpty { out.append((!w, cur)) }
        return out
    }
}
