import Foundation

/// Одно нажатие в буфере конверсии. Для обычного локального ввода известен keyCode
/// (char == nil). Для ввода, проброшенного через удалённый стол, Apple Screen Sharing
/// шлёт keyCode 0 + сам символ — тогда char != nil, и конверсия идёт по символу,
/// а не по бесполезному keyCode 0 (именно keyCode 0 рождал «фффффф»).
struct TypedKey {
    let keyCode: UInt16
    let shift: Bool
    let caps: Bool
    var char: Character? = nil
}

/// Клавиша с shift — ключ таблиц «клавиша → символ» раскладки (3.5.0b).
struct KeyStroke: Hashable, Sendable {
    let code: UInt16
    let shift: Bool
}

/// Режет строку на куски не длиннее limit UTF-16 единиц по границам символов: один
/// CGEvent с юникод-строкой надёжно несёт около 20 единиц, а расшифровка автозамены
/// бывает до 500 знаков. Символ длиннее limit (составной эмодзи) идёт отдельным куском.
func insertChunks(_ s: String, limit: Int = 20) -> [String] {
    var out: [String] = []
    var cur = ""
    var curLen = 0
    for ch in s {
        let n = ch.utf16.count
        if curLen > 0, curLen + n > limit {
            out.append(cur); cur = ""; curLen = 0
        }
        cur.append(ch); curLen += n
    }
    if !cur.isEmpty { out.append(cur) }
    return out
}

/// Выделенная подсказка автодополнения сразу за набранным (#47): выделение непустое и
/// начинается за словом, а текст перед ним — само слово. Регистр не важен: браузер может
/// подставить регистр подсказки. AX бывает на символ позади ввода — тогда перед выделением
/// слово без последней буквы. textBefore(location, n) — n единиц UTF-16 перед location.
func inlineCompletionMatches(typed: String, location: Int, length: Int,
                             textBefore: (Int, Int) -> String?) -> Bool {
    let full = (typed as NSString).length
    guard length > 0, full > 0 else { return false }
    for n in [full, full - 1] where n > 0 && location >= n {
        let expected = (typed as NSString).substring(to: n)
        if let s = textBefore(location, n), s.caseInsensitiveCompare(expected) == .orderedSame { return true }
    }
    return false
}
