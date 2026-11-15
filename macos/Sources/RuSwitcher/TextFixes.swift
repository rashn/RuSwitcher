import Foundation

/// Правка текста на конце слова (3.5.0b): две заглавные, числа, опечатка соседней
/// клавишей. Чистые функции: словарь и раскладки приходят замыканиями — всё гоняется
/// на стенде (docs/tools/wordend-tests, docs/tools/autobench).
enum TextFixes {
    /// Цифровой ряд (keyCode): цифры во всех раскладках на одних клавишах.
    static let digitKeys: Set<UInt16> = [18, 19, 20, 21, 23, 22, 26, 28, 25, 29]

    /// Буквенные ряды ANSI по keyCode. Ряды сдвинуты на полклавиши вправо, поэтому соседи
    /// клавиши i: тот же ряд i±1, ряд выше — i и i+1, ряд ниже — i−1 и i.
    static let rows: [[UInt16]] = [
        [12, 13, 14, 15, 17, 16, 32, 34, 31, 35, 33, 30],   // Q W E R T Y U I O P [ ]
        [0, 1, 2, 3, 5, 4, 38, 40, 37, 41, 39],             // A S D F G H J K L ; '
        [6, 7, 8, 9, 11, 45, 46, 43, 47, 44],               // Z X C V B N M , . /
    ]

    static let neighbors: [UInt16: [UInt16]] = {
        var map: [UInt16: [UInt16]] = [:]
        for (r, row) in rows.enumerated() {
            for (i, code) in row.enumerated() {
                var n: [UInt16] = []
                func add(_ rr: Int, _ ii: Int) {
                    guard rr >= 0, rr < rows.count, ii >= 0, ii < rows[rr].count else { return }
                    n.append(rows[rr][ii])
                }
                add(r, i - 1); add(r, i + 1)
                add(r - 1, i); add(r - 1, i + 1)
                add(r + 1, i - 1); add(r + 1, i)
                map[code] = n
            }
        }
        return map
    }()

    /// «КОгда» → «Когда». Только буквы, длина ≥3, первые две заглавные, остальные
    /// строчные. isWord получает исправленную форму в нижнем регистре: без словарного
    /// подтверждения не трогаем — так целы IPv6, GHz, MHz.
    static func fixTwoCaps(_ word: String, isWord: (String) -> Bool) -> String? {
        guard isTwoCaps(word) else { return nil }
        let fixed = String(word.prefix(1)) + word.dropFirst().lowercased()
        return isWord(fixed.lowercased()) ? fixed : nil
    }

    /// Шаблон опечатки «КОгда»: только буквы, длина ≥3, первые две заглавные, остальные строчные.
    static func isTwoCaps(_ word: String) -> Bool {
        let c = Array(word)
        guard c.count >= 3, c.allSatisfy({ $0.isLetter }),
              c[0].isUppercase, c[1].isUppercase,
              c[2...].allSatisfy({ $0.isLowercase }) else { return false }
        // «IDs», «PCs», «CDs» — множественное число аббревиатуры, а не опечатка (ревью I1:
        // словарь принимает ids/pcs, и без этой проверки они становились «Ids», «Pcs»).
        return String(c[2...]) != "s"
    }

    /// «1ю8» → «1.8»: точка или запятая, набранные в нелатинской раскладке между цифрами.
    /// Слово целиком: цифра (разделитель цифра)+. Разделитель — клавиша, которая в текущей
    /// раскладке дала букву, а в другой раскладке пары (otherChar, без shift) — «.» или «,».
    /// Shift запрещён: Shift+цифра — это знаки.
    static func fixNumber(keys: [TypedKey], typed: String, otherChar: (UInt16) -> Character?) -> String? {
        let t = Array(typed)
        guard keys.count == t.count, keys.count >= 3,
              keys.allSatisfy({ !$0.shift && $0.char == nil }) else { return nil }
        var out = ""
        var sawSeparator = false
        for (i, k) in keys.enumerated() {
            if digitKeys.contains(k.keyCode) { out.append(t[i]); continue }
            guard i > 0, i < keys.count - 1,
                  digitKeys.contains(keys[i - 1].keyCode), digitKeys.contains(keys[i + 1].keyCode),
                  t[i].isLetter, let o = otherChar(k.keyCode), o == "." || o == "," else { return nil }
            out.append(o)
            sawSeparator = true
        }
        return sawSeparator ? out : nil
    }

    /// «тедефон» → «телефон»: ровно одна клавиша заменена соседней. Правим, только если
    /// набранное не слово (isTypedWord) и ровно один кандидат проходит isCandidateWord.
    /// Оба замыкания получают слово в нижнем регистре. charFor(keyCode, shift) — символ
    /// клавиши в ТЕКУЩЕЙ раскладке. Регистр набранного сохраняется.
    static func fixTypo(keys: [TypedKey], typed: String,
                        charFor: (UInt16, Bool) -> Character?,
                        isTypedWord: (String) -> Bool,
                        isCandidateWord: (String) -> Bool) -> String? {
        let t = Array(typed)
        guard keys.count == t.count, t.count >= 5,
              t.allSatisfy({ $0.isLetter }),
              keys.allSatisfy({ $0.char == nil && !$0.caps }),
              !t.dropFirst().contains(where: { $0.isUppercase }) else { return nil }
        guard !isTypedWord(typed.lowercased()) else { return nil }
        var found: String?
        var seen = Set<String>()
        for i in 0..<keys.count {
            for n in neighbors[keys[i].keyCode] ?? [] {
                guard let ch = charFor(n, keys[i].shift), ch.isLetter else { continue }
                var cand = t
                cand[i] = ch
                let word = String(cand)
                let low = word.lowercased()
                guard seen.insert(low).inserted, isCandidateWord(low) else { continue }
                if found != nil { return nil }   // два варианта — неоднозначно, не трогаем
                found = word
            }
        }
        return found
    }
}
