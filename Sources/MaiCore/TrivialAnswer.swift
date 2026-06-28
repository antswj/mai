import Foundation

// Instant, local, no-web answers for the trivial route: arithmetic, percentages,
// and a curated set of exact unit/temperature conversions. Deliberately
// CONSERVATIVE: it returns a string only when it can answer correctly, and nil
// otherwise so the router falls through to a real lookup. It never guesses, so a
// trivial card never carries a wrong number (which would be worse than no card).
public enum TrivialAnswer {

    /// A short answer (e.g. "12", "236.59 ml", "20°C") or nil if not confidently local.
    public static func answer(_ raw: String) -> String? {
        var q = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip common lead-ins and a trailing question mark / equals.
        for lead in ["what's ", "whats ", "what is ", "how much is ", "calculate ", "compute ", "="] {
            if q.hasPrefix(lead) { q = String(q.dropFirst(lead.count)) }
        }
        q = q.trimmingCharacters(in: CharacterSet(charactersIn: "?=. "))
        if q.isEmpty { return nil }

        if let pct = percentage(q) { return pct }
        if let temp = temperature(q) { return temp }
        if let conv = unitConversion(q) { return conv }
        if let calc = arithmetic(q) { return calc }
        return nil
    }

    // MARK: - Percentages ("15% of 80", "20 percent of 50")

    private static func percentage(_ q: String) -> String? {
        let s = q.replacingOccurrences(of: "percent", with: "%")
        guard let r = firstMatch(#"([0-9]+(?:\.[0-9]+)?)\s*%\s*of\s*([0-9][0-9,]*(?:\.[0-9]+)?)"#, in: s),
              r.count == 3,
              let p = Double(r[1]), let base = Double(r[2].replacingOccurrences(of: ",", with: "")) else { return nil }
        return fmt(p / 100.0 * base)
    }

    // MARK: - Temperature (affine, handled apart from the linear unit table)

    private static func temperature(_ q: String) -> String? {
        guard let r = firstMatch(#"(-?[0-9]+(?:\.[0-9]+)?)\s*(°?\s*[cf]|celsius|fahrenheit|centigrade)\s*(?:in|to|=|->)\s*(°?\s*[cf]|celsius|fahrenheit|centigrade)"#, in: q),
              r.count == 4, let v = Double(r[1]) else { return nil }
        func isC(_ s: String) -> Bool { s.contains("c") }   // celsius/centigrade/°c all contain 'c' but not 'f'
        let from = r[2], to = r[3]
        let fromC = isC(from) && !from.contains("f")
        let toC = isC(to) && !to.contains("f")
        if fromC == toC { return nil }                       // same unit; not a conversion
        if fromC { return fmt(v * 9.0 / 5.0 + 32.0) + "°F" } // C -> F
        return fmt((v - 32.0) * 5.0 / 9.0) + "°C"            // F -> C
    }

    // MARK: - Linear unit conversion (curated, exact factors in SI base units)

    // factor = how many SI base units one of this unit is. length->meters,
    // mass->kilograms, volume->liters. Conversions stay within one dimension.
    private static let units: [String: (dim: String, factor: Double)] = [
        // length (meters)
        "m": ("len", 1), "meter": ("len", 1), "meters": ("len", 1), "metre": ("len", 1),
        "km": ("len", 1000), "kilometer": ("len", 1000), "kilometers": ("len", 1000),
        "cm": ("len", 0.01), "centimeter": ("len", 0.01), "centimeters": ("len", 0.01),
        "mm": ("len", 0.001), "millimeter": ("len", 0.001), "millimeters": ("len", 0.001),
        "mi": ("len", 1609.344), "mile": ("len", 1609.344), "miles": ("len", 1609.344),
        "ft": ("len", 0.3048), "foot": ("len", 0.3048), "feet": ("len", 0.3048),
        "in": ("len", 0.0254), "inch": ("len", 0.0254), "inches": ("len", 0.0254),
        "yd": ("len", 0.9144), "yard": ("len", 0.9144), "yards": ("len", 0.9144),
        // mass (kilograms)
        "kg": ("mass", 1), "kilogram": ("mass", 1), "kilograms": ("mass", 1),
        "g": ("mass", 0.001), "gram": ("mass", 0.001), "grams": ("mass", 0.001),
        "mg": ("mass", 0.000001), "milligram": ("mass", 0.000001), "milligrams": ("mass", 0.000001),
        "lb": ("mass", 0.45359237), "lbs": ("mass", 0.45359237), "pound": ("mass", 0.45359237), "pounds": ("mass", 0.45359237),
        "oz": ("mass", 0.028349523), "ounce": ("mass", 0.028349523), "ounces": ("mass", 0.028349523),
        // volume (liters)
        "l": ("vol", 1), "liter": ("vol", 1), "liters": ("vol", 1), "litre": ("vol", 1), "litres": ("vol", 1),
        "ml": ("vol", 0.001), "milliliter": ("vol", 0.001), "milliliters": ("vol", 0.001),
        "cup": ("vol", 0.2365882365), "cups": ("vol", 0.2365882365),
        "tbsp": ("vol", 0.0147867648), "tablespoon": ("vol", 0.0147867648), "tablespoons": ("vol", 0.0147867648),
        "tsp": ("vol", 0.00492892159), "teaspoon": ("vol", 0.00492892159), "teaspoons": ("vol", 0.00492892159),
        "gal": ("vol", 3.785411784), "gallon": ("vol", 3.785411784), "gallons": ("vol", 3.785411784),
    ]

    private static func unitConversion(_ q: String) -> String? {
        // "how many ml in a cup" / "how many cm in an inch"
        if let r = firstMatch(#"how many\s+([a-z]+)\s+(?:in|are in|per)\s+(?:a|an|one|1)\s+([a-z]+)"#, in: q),
           r.count == 3, let a = units[r[1]], let b = units[r[2]], a.dim == b.dim {
            return fmt(b.factor / a.factor) + " " + r[1]
        }
        // "convert 5 km to miles" / "5 km in miles" / "5 km to mi"
        if let r = firstMatch(#"(?:convert\s+)?(-?[0-9]+(?:\.[0-9]+)?)\s*([a-z]+)\s*(?:in|to|=|->)\s*([a-z]+)"#, in: q),
           r.count == 4, let n = Double(r[1]), let a = units[r[2]], let b = units[r[3]], a.dim == b.dim {
            return fmt(n * a.factor / b.factor) + " " + r[3]
        }
        return nil
    }

    // MARK: - Arithmetic (recursive descent over + - * / and parentheses)

    private static func arithmetic(_ q: String) -> String? {
        var s = " " + q + " "
        let words: [(String, String)] = [
            (" plus ", " + "), (" minus ", " - "), (" times ", " * "),
            (" multiplied by ", " * "), (" divided by ", " / "), (" over ", " / "), (" x ", " * "),
        ]
        for (w, op) in words { s = s.replacingOccurrences(of: w, with: op) }
        s = s.replacingOccurrences(of: ",", with: "")
        let compact = s.replacingOccurrences(of: " ", with: "")
        guard !compact.isEmpty,
              compact.allSatisfy({ "0123456789.+-*/()".contains($0) }),
              compact.contains(where: { "+*/".contains($0) }) || compact.dropFirst().contains("-") else {
            return nil   // not a pure arithmetic expression with a real operator
        }
        var parser = ExprParser(Array(compact))
        guard let value = parser.parseExpression(), parser.atEnd, value.isFinite else { return nil }
        return fmt(value)
    }

    // MARK: - Helpers

    private static func fmt(_ d: Double) -> String {
        if abs(d - d.rounded()) < 1e-9 { return String(Int(d.rounded())) }
        var s = String(format: "%.2f", d)
        while s.hasSuffix("0") { s = String(s.dropLast()) }
        if s.hasSuffix(".") { s = String(s.dropLast()) }
        return s
    }

    private static func firstMatch(_ pattern: String, in text: String) -> [String]? {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let m = re.firstMatch(in: text, range: range) else { return nil }
        var groups: [String] = []
        for i in 0..<m.numberOfRanges {
            guard let r = Range(m.range(at: i), in: text) else { return nil }
            groups.append(String(text[r]))
        }
        return groups
    }
}

// Tiny recursive-descent arithmetic evaluator over a character array.
private struct ExprParser {
    private let chars: [Character]
    private var pos = 0
    init(_ chars: [Character]) { self.chars = chars }

    var atEnd: Bool { pos >= chars.count }
    private func peek() -> Character? { pos < chars.count ? chars[pos] : nil }

    mutating func parseExpression() -> Double? {
        guard var value = parseTerm() else { return nil }
        while let op = peek(), op == "+" || op == "-" {
            pos += 1
            guard let rhs = parseTerm() else { return nil }
            value = op == "+" ? value + rhs : value - rhs
        }
        return value
    }
    private mutating func parseTerm() -> Double? {
        guard var value = parseFactor() else { return nil }
        while let op = peek(), op == "*" || op == "/" {
            pos += 1
            guard let rhs = parseFactor() else { return nil }
            if op == "/" { if rhs == 0 { return nil }; value /= rhs } else { value *= rhs }
        }
        return value
    }
    private mutating func parseFactor() -> Double? {
        guard let c = peek() else { return nil }
        if c == "-" { pos += 1; return parseFactor().map { -$0 } }
        if c == "+" { pos += 1; return parseFactor() }
        if c == "(" {
            pos += 1
            let v = parseExpression()
            guard peek() == ")" else { return nil }
            pos += 1
            return v
        }
        var num = ""
        while let d = peek(), d.isNumber || d == "." { num.append(d); pos += 1 }
        return Double(num)
    }
}
