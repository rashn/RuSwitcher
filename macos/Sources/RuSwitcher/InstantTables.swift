import Foundation

/// Таблицы для конверсии на лету — ЗАГРУЖАЕМЫЕ, не встроенные. Приложение не возит данных с
/// собой (та же причина, по которой словарь берётся системный, а не бандлится): паки качаются
/// по включению настройки, проверяются по sha256 из манифеста и лежат в Application Support.
///
/// Пак = один ЯЗЫК, не пара. Детектор берёт две языковые таблицы и сравнивает «невозможно в
/// своём / правдоподобно в чужом», поэтому ru+en дают пару ru↔en, а добавленный третий язык —
/// сразу все пары с ним. Алфавит и параметры Bloom лежат ВНУТРИ пака: новый язык — это запись
/// в манифесте и ассет, приложение править не нужно.
///
/// Нет пака (не скачан, нет сети, не сошёлся хеш) — конверсия на лету просто молчит, работает
/// обычный путь на пробеле.
enum InstantTables {
    /// Разобранные паки по коду языка. Заполняется при загрузке с диска, живёт до перезапуска.
    @MainActor private static var loaded: [String: LanguageTables] = [:]
    @MainActor private static var missing: Set<String> = []   // чтобы не долбить диск на каждую букву

    /// Таблицы языка или nil, если пака нет. Первое обращение читает файл с диска, дальше — память.
    @MainActor static func tables(for lang: String) -> LanguageTables? {
        let code = String(lang.prefix(2)).lowercased()
        if let t = loaded[code] { return t }
        if missing.contains(code) { return nil }
        guard let data = try? Data(contentsOf: packURL(code)),
              let parsed = LanguageTables(pack: data) else {
            missing.insert(code)
            return nil
        }
        loaded[code] = parsed
        return parsed
    }

    /// Есть ли на диске пак этого языка (без разбора — для UI и для решения «качать ли»).
    static func isDownloaded(_ lang: String) -> Bool {
        FileManager.default.fileExists(atPath: packURL(String(lang.prefix(2)).lowercased()).path)
    }

    /// Кладёт скачанный пак на диск и роняет кэш языка, чтобы следующий запрос перечитал файл.
    @MainActor static func install(_ data: Data, lang: String) throws {
        let dir = directory()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try data.write(to: packURL(lang), options: .atomic)
        loaded[lang] = nil
        missing.remove(lang)
    }

    /// Версия таблиц установленного пака (для сверки с манифестом), nil — пака нет.
    @MainActor static func installedVersion(_ lang: String) -> Int? {
        tables(for: lang)?.version
    }

    static func directory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("RuSwitcher/InstantTables", isDirectory: true)
    }

    private static func packURL(_ lang: String) -> URL {
        directory().appendingPathComponent("\(lang).pack")
    }
}

/// Разобранный пак одного языка: маска допустимых буквосочетаний + Bloom начал слов.
struct LanguageTables: Sendable {
    let language: String
    let version: Int
    let ngrams: NGramSet
    let prefixes: PrefixBloom

    /// Разбор бинаря пака (формат см. macos/tools/gen_instant_tables.py). Любое несоответствие —
    /// nil: битый или чужой файл должен выключать фичу, а не притворяться таблицами.
    init?(pack data: Data) {
        var r = PackReader(data)
        guard r.readBytes(4) == Data("RSIT".utf8),
              let format = r.readUInt8(), format == 1,
              let version = r.readUInt8(),
              let langLen = r.readUInt8(),
              let langData = r.readBytes(Int(langLen)),
              let language = String(data: langData, encoding: .utf8),
              let alphaLen = r.readUInt16(),
              let alphaData = r.readBytes(Int(alphaLen)),
              let alphabet = String(data: alphaData, encoding: .utf8),
              let ngramLen = r.readUInt32(),
              let ngramBits = r.readBytes(Int(ngramLen)),
              let bloomBits = r.readUInt32(),
              let bloomK = r.readUInt8(),
              let prefixMaxLen = r.readUInt8(),
              let bloomLen = r.readUInt32(),
              let bloomData = r.readBytes(Int(bloomLen)),
              !alphabet.isEmpty, bloomBits > 0, bloomK > 0, prefixMaxLen > 0
        else { return nil }

        self.language = language
        self.version = Int(version)
        self.ngrams = NGramSet(alphabet: Array(alphabet), bits: [UInt8](ngramBits))
        self.prefixes = PrefixBloom(bits: Int(bloomBits), hashCount: Int(bloomK),
                                    maxLength: Int(prefixMaxLen), data: [UInt8](bloomData))
    }
}

/// Последовательное чтение бинаря с проверкой границ — файл приходит из сети, доверять длинам нельзя.
private struct PackReader {
    private let data: Data
    private var offset: Int
    init(_ data: Data) { self.data = data; self.offset = data.startIndex }

    mutating func readBytes(_ count: Int) -> Data? {
        guard count >= 0, offset + count <= data.endIndex else { return nil }
        defer { offset += count }
        return data[offset..<(offset + count)]
    }
    mutating func readUInt8() -> UInt8? { readBytes(1)?.first }
    mutating func readUInt16() -> UInt16? {
        guard let b = readBytes(2).map([UInt8].init) else { return nil }
        return UInt16(b[0]) | UInt16(b[1]) << 8
    }
    mutating func readUInt32() -> UInt32? {
        guard let b = readBytes(4).map([UInt8].init) else { return nil }
        return UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24
    }
}

/// Битовая маска допустимых триграмм (с маркером начала слова «^») одного языка.
/// Индекс = c0*N² + c1*N + c2, где N = алфавит+1, код 0 — «начало слова».
/// Проверка сочетания — сдвиг и AND: ни словаря, ни XPC, поэтому её не страшно гнать
/// на каждую нажатую букву, не рискуя фризом event tap.
struct NGramSet: Sendable {
    private let code: [Character: Int]      // символ → индекс (0 зарезервирован под «начало слова»)
    private let n: Int
    private let bits: [UInt8]

    init(alphabet: [Character], bits: [UInt8]) {
        var map: [Character: Int] = [:]
        for (i, c) in alphabet.enumerated() { map[c] = i + 1 }
        self.code = map
        self.n = alphabet.count + 1
        self.bits = bits
    }

    /// Все ли символы строки принадлежат алфавиту языка (регистр уже приведён к нижнему).
    func isPureAlphabet(_ s: String) -> Bool {
        !s.isEmpty && s.allSatisfy { code[$0] != nil }
    }

    /// Встречается ли сочетание в языке. Символ вне алфавита (цифра, пунктуация) делает
    /// сочетание невозможным — это и есть сигнал «набрано не в той раскладке».
    func allows(_ a: Character, _ b: Character, _ c: Character) -> Bool {
        guard let i = index(a), let j = index(b), let k = index(c) else { return false }
        let bit = (i * n + j) * n + k
        let byte = bit >> 3
        guard byte < bits.count else { return false }
        return bits[byte] & (1 << UInt8(bit & 7)) != 0
    }

    /// Все ли сочетания слова возможны в этом языке (слово берётся с маркером начала).
    func allowsAll(_ word: String) -> Bool { !hasImpossible(word) }

    /// Есть ли в слове сочетание, невозможное в этом языке.
    func hasImpossible(_ word: String) -> Bool {
        let chars = Array("^" + word)
        guard chars.count >= 3 else { return false }   // короче двух букв судить не о чем
        for i in 0...(chars.count - 3) where !allows(chars[i], chars[i+1], chars[i+2]) {
            return true
        }
        return false
    }

    private func index(_ c: Character) -> Int? {
        if c == "^" { return 0 }
        return code[c]
    }
}

/// Bloom-фильтр начал настоящих слов одного языка (префиксы до maxLength символов).
///
/// Зачем вдобавок к статистике сочетаний: она честно считает «http» невозможным для
/// английского (такого сочетания в живой речи нет), и «htt» улетало бы в «рее». Словарь начал
/// слов это ловит. Обратная проверка тоже нужна: одного словаря мало, редкое слово вне корпуса
/// он объявляет мусором, поэтому решение требует согласия обеих моделей (см. InstantDetector).
///
/// Bloom, а не точный набор: 10 бит на префикс дают десятки килобайт вместо сотен, ценой
/// ~0,8% ложноположительных — и обе стороны от них лишь консервативнее (лишний раз промолчим).
struct PrefixBloom: Sendable {
    private let m: Int
    private let hashCount: Int
    private let maxLength: Int
    private let bits: [UInt8]

    init(bits count: Int, hashCount: Int, maxLength: Int, data: [UInt8]) {
        self.m = count
        self.hashCount = hashCount
        self.maxLength = maxLength
        self.bits = data
    }

    /// Начинается ли хоть одно слово языка с этой строки (регистр — нижний).
    /// Ложноположительные возможны (Bloom), ложноотрицательных нет.
    func isWordStart(_ prefix: String) -> Bool {
        guard !bits.isEmpty, m > 0, !prefix.isEmpty else { return false }
        let key = String(prefix.prefix(maxLength))
        let data = Array(key.utf8)
        let h1 = PrefixBloom.fnv1a(data, seed: 0)
        let h2 = PrefixBloom.fnv1a(data, seed: 0x9E37_79B9_7F4A_7C15)
        for i in 0..<hashCount {
            let bit = Int((h1 &+ UInt64(i) &* h2) % UInt64(m))
            let byte = bit >> 3
            guard byte < bits.count, bits[byte] & (1 << UInt8(bit & 7)) != 0 else { return false }
        }
        return true
    }

    /// FNV-1a 64. Тот же алгоритм, что в генераторе — иначе фильтр читался бы мимо.
    /// ВАЖНО: арифметика здесь wrapping, и в генераторе хеши обязаны маскироваться до 64 бит.
    private static func fnv1a(_ data: [UInt8], seed: UInt64) -> UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325 ^ seed
        for b in data {
            h = (h ^ UInt64(b)) &* 0x0000_0100_0000_01b3
        }
        return h
    }
}
