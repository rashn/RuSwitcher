#!/usr/bin/env python3
"""Генератор таблиц для конверсии на лету (InstantDetector).

Делает два Swift-файла в Sources/RuSwitcher/:
  NGramTables.swift   — битовые маски допустимых триграмм (с маркером начала слова)
  WordPrefixes.swift  — Bloom-фильтры начал реальных слов (префиксы длиной до 5)

Корпус: hermitdave/FrequencyWords, OpenSubtitles-2018, top-50k слов на язык.
    curl -sL -o /tmp/ru_freq.txt https://raw.githubusercontent.com/hermitdave/FrequencyWords/master/content/2018/ru/ru_50k.txt
    curl -sL -o /tmp/en_freq.txt https://raw.githubusercontent.com/hermitdave/FrequencyWords/master/content/2018/en/en_50k.txt
    python3 macos/tools/gen_instant_tables.py

Пороги и параметры подбирались по замерам на самом корпусе (отложенные 20% слов +
словарь Вебстера /usr/share/dict/web2 как «редкие слова»): комбинация двух моделей
даёт ~0.1% ложных на редких словах при отлове ~75% в среднем на 2,5-й букве.
"""
import base64, collections, textwrap, os

RU = "абвгдеёжзийклмнопрстуфхцчшщъыьэюя"
EN = "abcdefghijklmnopqrstuvwxyz"
TRIGRAM_THRESHOLD = 1e-7   # доля от корпуса, ниже которой сочетание считаем невозможным
PREFIX_MAXLEN = 5          # длиннее не храним: там уже хватает статистики сочетаний
BLOOM_BITS_PER_ITEM = 10   # ≈0.8% ложноположительных при k=7
BLOOM_K = 7
OUT = os.path.join(os.path.dirname(__file__), "..", "Sources", "RuSwitcher")


def load(path, alphabet):
    aset, out = set(alphabet), []
    for line in open(path, encoding="utf-8", errors="ignore"):
        p = line.split()
        if len(p) != 2:
            continue
        w, f = p[0].lower(), int(p[1])
        if w and all(c in aset for c in w):
            out.append((w, f))
    return out


def trigrams(word):
    s = "^" + word
    return [s[i:i + 3] for i in range(len(s) - 2)]


def build_trigrams(words):
    cnt, total = collections.Counter(), 0
    for w, f in words:
        total += f
        for t in trigrams(w):
            cnt[t] += f
    thr = total * TRIGRAM_THRESHOLD
    return {t for t, c in cnt.items() if c >= thr}


def encode_trigrams(allowed, alphabet):
    n = len(alphabet) + 1
    idx = lambda c: 0 if c == "^" else alphabet.index(c) + 1
    bits = bytearray((n * n * n + 7) // 8)
    for t in allowed:
        i = (idx(t[0]) * n + idx(t[1])) * n + idx(t[2])
        bits[i >> 3] |= 1 << (i & 7)
    return bytes(bits)


def fnv1a(data, seed):
    h = 0xcbf29ce484222325 ^ seed
    for b in data:
        h = ((h ^ b) * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF
    return h


def build_prefixes(words):
    s = set()
    for w, _ in words:
        for n in range(1, min(len(w), PREFIX_MAXLEN) + 1):
            s.add(w[:n])
    return s


def encode_bloom(items):
    m = max(8, len(items) * BLOOM_BITS_PER_ITEM)
    bits = bytearray((m + 7) // 8)
    for s in items:
        data = s.encode("utf-8")
        h1, h2 = fnv1a(data, 0), fnv1a(data, 0x9E3779B97F4A7C15)
        for i in range(BLOOM_K):
            # маска обязательна: в Swift эта арифметика wrapping (&+, &*), а у Python числа
            # неограниченные — без обрезки до 64 бит генератор и приложение расходятся в битах
            bit = ((h1 + i * h2) & 0xFFFFFFFFFFFFFFFF) % m
            bits[bit >> 3] |= 1 << (bit & 7)
    return bytes(bits), m


def wrap(b):
    return "\n".join("    " + l for l in textwrap.wrap(base64.b64encode(b).decode(), 96))


def main():
    ru_words = load("/tmp/ru_freq.txt", RU)
    en_words = load("/tmp/en_freq.txt", EN)
    ru_tri = encode_trigrams(build_trigrams(ru_words), RU)
    en_tri = encode_trigrams(build_trigrams(en_words), EN)
    ru_pref, ru_m = encode_bloom(build_prefixes(ru_words))
    en_pref, en_m = encode_bloom(build_prefixes(en_words))

    ngram = f'''import Foundation

/// Таблицы допустимых буквосочетаний (триграмм с маркером начала слова «^») для русского
/// и английского. СГЕНЕРИРОВАНО `macos/tools/gen_instant_tables.py` по частотному корпусу
/// OpenSubtitles-2018 (hermitdave/FrequencyWords, 50k слов на язык); порог — суммарная
/// взвешенная частота сочетания ≥ {TRIGRAM_THRESHOLD:g} от корпуса: он отсекает опечатки и
/// иноязычный мусор корпуса, сохраняя живые редкие сочетания. Руками не править.
///
/// Формат: битовая маска, индекс = c0*N² + c1*N + c2, где N = алфавит+1, код 0 — «начало слова».
/// Размер: ru {len(ru_tri)} Б, en {len(en_tri)} Б — проверка сочетания это сдвиг и AND, никакого
/// словаря и никакого XPC (в отличие от NSSpellChecker), поэтому детект можно гнать на каждую
/// нажатую букву, не рискуя фризом event tap.
enum NGramTables {{
    static let ruAlphabet = Array("{RU}")
    static let enAlphabet = Array("{EN}")

    static let ru = NGramSet(alphabet: ruAlphabet, base64: ruBase64)
    static let en = NGramSet(alphabet: enAlphabet, base64: enBase64)

    private static let ruBase64 = """
{wrap(ru_tri)}
    """

    private static let enBase64 = """
{wrap(en_tri)}
    """
}}

/// Битовая маска допустимых триграмм одного языка.
struct NGramSet: Sendable {{
    private let code: [Character: Int]      // символ → индекс (0 зарезервирован под «начало слова»)
    private let n: Int
    private let bits: [UInt8]

    init(alphabet: [Character], base64: String) {{
        var map: [Character: Int] = [:]
        for (i, c) in alphabet.enumerated() {{ map[c] = i + 1 }}
        self.code = map
        self.n = alphabet.count + 1
        self.bits = [UInt8](Data(base64Encoded: base64, options: .ignoreUnknownCharacters) ?? Data())
    }}

    /// Все ли символы строки принадлежат алфавиту языка (регистр уже приведён к нижнему).
    func isPureAlphabet(_ s: String) -> Bool {{
        !s.isEmpty && s.allSatisfy {{ code[$0] != nil }}
    }}

    /// Встречается ли сочетание в языке. Символ вне алфавита (цифра, пунктуация) делает
    /// сочетание невозможным — это и есть сигнал «набрано не в той раскладке».
    func allows(_ a: Character, _ b: Character, _ c: Character) -> Bool {{
        guard let i = index(a), let j = index(b), let k = index(c) else {{ return false }}
        let bit = (i * n + j) * n + k
        let byte = bit >> 3
        guard byte < bits.count else {{ return false }}
        return bits[byte] & (1 << UInt8(bit & 7)) != 0
    }}

    /// Все ли сочетания слова возможны в этом языке (слово берётся с маркером начала).
    func allowsAll(_ word: String) -> Bool {{ !hasImpossible(word) }}

    /// Есть ли в слове сочетание, невозможное в этом языке.
    func hasImpossible(_ word: String) -> Bool {{
        let chars = Array("^" + word)
        guard chars.count >= 3 else {{ return false }}   // короче двух букв судить не о чем
        for i in 0...(chars.count - 3) where !allows(chars[i], chars[i+1], chars[i+2]) {{
            return true
        }}
        return false
    }}

    private func index(_ c: Character) -> Int? {{
        if c == "^" {{ return 0 }}
        return code[c]
    }}
}}
'''

    prefixes = f'''import Foundation

/// Начала настоящих слов русского и английского — Bloom-фильтры на префиксах длиной до
/// {PREFIX_MAXLEN} символов. СГЕНЕРИРОВАНО `macos/tools/gen_instant_tables.py` по тому же корпусу, что и
/// `NGramTables`. Руками не править.
///
/// Зачем вдобавок к статистике сочетаний: она честно считает «http» невозможным для английского
/// (такого сочетания в живой речи нет), и «htt» улетало бы в «рее». Словарь начал слов это
/// ловит — «http» настоящее слово, значит человек его и печатал. Обратная проверка тоже нужна:
/// одного словаря мало, редкое слово вне корпуса он объявляет мусором, поэтому решение
/// принимается только при согласии обеих моделей (см. InstantDetector).
///
/// Bloom, а не точный набор: {BLOOM_BITS_PER_ITEM} бит на префикс даёт ru {len(ru_pref)} Б и en {len(en_pref)} Б вместо сотен
/// килобайт, ценой ~0,8% ложноположительных — и обе стороны от них лишь консервативнее
/// (лишний раз промолчим), потому что решение требует согласия ещё и статистики сочетаний.
enum WordPrefixes {{
    static let ru = PrefixBloom(bits: {ru_m}, base64: ruBase64)
    static let en = PrefixBloom(bits: {en_m}, base64: enBase64)

    private static let ruBase64 = """
{wrap(ru_pref)}
    """

    private static let enBase64 = """
{wrap(en_pref)}
    """
}}

/// Bloom-фильтр начал слов одного языка.
struct PrefixBloom: Sendable {{
    /// Дальше префиксы не хранились — длинные обрезаем до этой длины (надмножество: любой
    /// более длинный префикс начинается с сохранённого, так что «неизвестно» не соврёт).
    static let maxLength = {PREFIX_MAXLEN}
    private static let hashCount = {BLOOM_K}

    private let m: Int
    private let bits: [UInt8]

    init(bits count: Int, base64: String) {{
        self.m = count
        self.bits = [UInt8](Data(base64Encoded: base64, options: .ignoreUnknownCharacters) ?? Data())
    }}

    /// Начинается ли хоть одно слово языка с этой строки (регистр — нижний).
    /// Ложноположительные возможны (Bloom), ложноотрицательных нет.
    func isWordStart(_ prefix: String) -> Bool {{
        guard !bits.isEmpty, !prefix.isEmpty else {{ return false }}
        let key = String(prefix.prefix(PrefixBloom.maxLength))
        let data = Array(key.utf8)
        let h1 = PrefixBloom.fnv1a(data, seed: 0)
        let h2 = PrefixBloom.fnv1a(data, seed: 0x9E37_79B9_7F4A_7C15)
        for i in 0..<PrefixBloom.hashCount {{
            let bit = Int((h1 &+ UInt64(i) &* h2) % UInt64(m))
            let byte = bit >> 3
            guard byte < bits.count, bits[byte] & (1 << UInt8(bit & 7)) != 0 else {{ return false }}
        }}
        return true
    }}

    /// FNV-1a 64. Тот же алгоритм, что в генераторе — иначе фильтр читался бы мимо.
    private static func fnv1a(_ data: [UInt8], seed: UInt64) -> UInt64 {{
        var h: UInt64 = 0xcbf2_9ce4_8422_2325 ^ seed
        for b in data {{
            h = (h ^ UInt64(b)) &* 0x0000_0100_0000_01b3
        }}
        return h
    }}
}}
'''
    open(os.path.join(OUT, "NGramTables.swift"), "w", encoding="utf-8").write(ngram)
    open(os.path.join(OUT, "WordPrefixes.swift"), "w", encoding="utf-8").write(prefixes)
    print(f"триграммы: ru {len(ru_tri)} Б, en {len(en_tri)} Б")
    print(f"префиксы:  ru {len(ru_pref)} Б ({ru_m} бит), en {len(en_pref)} Б ({en_m} бит)")


if __name__ == "__main__":
    main()
