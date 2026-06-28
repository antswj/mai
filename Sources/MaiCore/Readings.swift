import Foundation

// One renderable unit of a line: a base run plus an optional reading shown above it
// (furigana for Japanese kanji words, pinyin for Chinese hanzi). Units with no
// reading still occupy the base line so a custom layout can keep baselines aligned.
public struct RubyUnit: Sendable, Equatable {
    public let base: String
    public let reading: String?
    public init(base: String, reading: String?) { self.base = base; self.reading = reading }
}

// Local, fast, no-network reading generation. Japanese furigana via the system
// tokenizer (word boundary, Latin transcription) then Latin to Hiragana. Chinese
// pinyin via the system Mandarin to Latin transform, per hanzi. Verified against
// the macOS SDK headers (CFStringTokenizer, CFStringTransform), 2026-06.
public enum Readings {

    /// Segment a line into ruby units for the given floor language.
    public static func units(_ text: String, language: Language) -> [RubyUnit] {
        switch language {
        case .ja: return furiganaUnits(text)
        case .zh: return pinyinUnits(text)
        case .en: return text.isEmpty ? [] : [RubyUnit(base: text, reading: nil)]
        }
    }

    // MARK: - Japanese

    /// Word tokens; kanji-containing words get a hiragana reading, everything else
    /// (kana, punctuation, spaces, Latin, digits) passes through with no reading.
    /// The full original line is preserved: gaps between word tokens are kept as
    /// plain base units.
    public static func furiganaUnits(_ text: String) -> [RubyUnit] {
        if text.isEmpty { return [] }
        let ns = text as NSString
        let cf = text as CFString
        let locale = NSLocale(localeIdentifier: "ja") as CFLocale
        guard let tk = CFStringTokenizerCreate(
            kCFAllocatorDefault, cf,
            CFRangeMake(0, CFStringGetLength(cf)),
            kCFStringTokenizerUnitWordBoundary, locale
        ) else {
            return [RubyUnit(base: text, reading: nil)]
        }

        var units: [RubyUnit] = []
        var cursor = 0  // UTF-16 offset of the next unconsumed character
        while CFStringTokenizerAdvanceToNextToken(tk) != [] {
            let r = CFStringTokenizerGetCurrentTokenRange(tk)
            let start = r.location
            let len = r.length
            if start > cursor {
                // Preserve any skipped run (whitespace, punctuation) verbatim.
                let gap = ns.substring(with: NSRange(location: cursor, length: start - cursor))
                if !gap.isEmpty { units.append(RubyUnit(base: gap, reading: nil)) }
            }
            let word = ns.substring(with: NSRange(location: start, length: len))
            var reading: String? = nil
            if containsHan(word),
               let attr = CFStringTokenizerCopyCurrentTokenAttribute(tk, kCFStringTokenizerAttributeLatinTranscription) {
                let hira = latinToHiragana((attr as! CFString) as String)
                if !hira.isEmpty, hira != word { reading = hira }
            }
            units.append(RubyUnit(base: word, reading: reading))
            cursor = start + len
        }
        if cursor < ns.length {
            let tail = ns.substring(with: NSRange(location: cursor, length: ns.length - cursor))
            if !tail.isEmpty { units.append(RubyUnit(base: tail, reading: nil)) }
        }
        return units.isEmpty ? [RubyUnit(base: text, reading: nil)] : units
    }

    // MARK: - Chinese

    /// Each hanzi becomes a unit with its pinyin (tone marks). Consecutive non-hanzi
    /// (punctuation, spaces, Latin, digits) are grouped into one no-reading unit.
    public static func pinyinUnits(_ text: String) -> [RubyUnit] {
        if text.isEmpty { return [] }
        var units: [RubyUnit] = []
        var buffer = ""
        func flush() {
            if !buffer.isEmpty { units.append(RubyUnit(base: buffer, reading: nil)); buffer = "" }
        }
        for ch in text {
            if isHan(ch) {
                flush()
                units.append(RubyUnit(base: String(ch), reading: pinyin(forCharacter: String(ch))))
            } else {
                buffer.append(ch)
            }
        }
        flush()
        return units
    }

    public static func pinyin(forCharacter c: String, stripTones: Bool = false) -> String {
        let s = NSMutableString(string: c)
        CFStringTransform(s as CFMutableString, nil, kCFStringTransformMandarinLatin, false)
        if stripTones { CFStringTransform(s as CFMutableString, nil, kCFStringTransformStripDiacritics, false) }
        return s as String
    }

    // MARK: - helpers

    static func latinToHiragana(_ romaji: String) -> String {
        let s = NSMutableString(string: romaji)
        CFStringTransform(s as CFMutableString, nil, kCFStringTransformLatinHiragana, false)
        return s as String
    }

    public static func containsHan(_ s: String) -> Bool { s.contains(where: isHan) }

    static func isHan(_ ch: Character) -> Bool {
        ch.unicodeScalars.contains { u in
            let v = u.value
            return (0x4E00...0x9FFF).contains(v) || (0x3400...0x4DBF).contains(v)
                || (0x20000...0x2A6DF).contains(v) || (0xF900...0xFAFF).contains(v)
        }
    }
}
