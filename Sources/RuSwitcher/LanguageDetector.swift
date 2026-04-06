import Foundation

/// Определяет язык слова по частотным биграммам
final class LanguageDetector {
    enum Language {
        case russian
        case english
    }

    // Частые биграммы русского языка
    private let ruBigrams: Set<String> = [
        "ст", "но", "то", "на", "ен", "ни", "ро", "ов", "ко", "по",
        "ра", "ер", "та", "не", "ал", "ть", "от", "пр", "ре", "ор",
        "ос", "ан", "ли", "ол", "ин", "да", "во", "ел", "ло", "ка",
        "де", "ла", "ве", "ет", "ск", "ле", "ти", "ой", "ые", "ит",
        "ом", "ес", "ая", "ем", "го", "ат", "ие", "ас", "ри", "те",
        "од", "ны", "ди", "ва", "ог", "ме", "ий", "се", "ил", "об",
    ]

    // Частые биграммы английского языка
    private let enBigrams: Set<String> = [
        "th", "he", "in", "er", "an", "re", "on", "at", "en", "nd",
        "ti", "es", "or", "te", "of", "ed", "is", "it", "al", "ar",
        "st", "to", "nt", "ng", "se", "ha", "as", "ou", "io", "le",
        "ve", "co", "me", "de", "hi", "ri", "ro", "ic", "ne", "ea",
        "ra", "ce", "li", "ch", "ll", "be", "ma", "si", "om", "ur",
    ]

    // Невозможные биграммы в русском (если встретились — точно не русский)
    private let ruImpossible: Set<String> = [
        "ьъ", "ъь", "ъъ", "ьь", "жщ", "щж", "шщ", "щш", "гъ", "ъг",
    ]

    /// Проверяет, похоже ли слово на указанный язык
    func isLikely(_ word: String, language: Language) -> Bool {
        let lower = word.lowercased()
        guard lower.count >= 3 else { return false }

        let bigrams = extractBigrams(lower)
        guard !bigrams.isEmpty else { return false }

        let targetSet: Set<String>
        switch language {
        case .russian:
            // Проверяем невозможные биграммы
            for bg in bigrams {
                if ruImpossible.contains(bg) { return false }
            }
            targetSet = ruBigrams
        case .english:
            targetSet = enBigrams
        }

        let matchCount = bigrams.filter { targetSet.contains($0) }.count
        let ratio = Double(matchCount) / Double(bigrams.count)

        // Порог: минимум 40% биграмм должны быть из частотного набора
        return ratio >= 0.4
    }

    private func extractBigrams(_ text: String) -> [String] {
        let chars = Array(text)
        guard chars.count >= 2 else { return [] }
        return (0..<chars.count - 1).map { String(chars[$0]) + String(chars[$0 + 1]) }
    }
}
