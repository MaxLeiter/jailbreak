import Foundation

/// Imports a `Recipe` from a web page by reading schema.org Recipe JSON-LD
/// (the `<script type="application/ld+json">` blocks that most recipe sites
/// embed). Foundation-only — no third-party dependencies.
///
/// Usage:
/// ```swift
/// let recipe = try await RecipeImporter.fetch(url)
/// ```
enum RecipeImporter {

    /// Friendly, user-facing import failures.
    enum ImportError: LocalizedError {
        case invalidURL
        case network(String)
        case unreadablePage
        case noRecipeFound

        var errorDescription: String? {
            switch self {
            case .invalidURL:
                return "That doesn't look like a valid link."
            case .network(let detail):
                return "Couldn't load that page. \(detail)"
            case .unreadablePage:
                return "Couldn't read that page."
            case .noRecipeFound:
                return "Couldn't read a recipe from that link. Try a different recipe page."
            }
        }
    }

    // A desktop browser User-Agent to slip past the simplest bot walls.
    private static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 " +
        "(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

    // MARK: - Public API

    static func fetch(_ url: URL) async throws -> Recipe {
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
                         forHTTPHeaderField: "Accept")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.timeoutInterval = 20

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw ImportError.network(error.localizedDescription)
        }

        if let http = response as? HTTPURLResponse, !(200..<400).contains(http.statusCode) {
            throw ImportError.network("The site returned an error (\(http.statusCode)).")
        }

        guard let html = decodeHTML(data) else { throw ImportError.unreadablePage }

        for block in extractJSONLD(from: html) {
            guard let blockData = block.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: blockData) else { continue }
            if let recipeDict = findRecipe(in: json) {
                return buildRecipe(from: recipeDict)
            }
        }

        throw ImportError.noRecipeFound
    }

    // MARK: - HTML / JSON-LD extraction

    private static func decodeHTML(_ data: Data) -> String? {
        if let s = String(data: data, encoding: .utf8) { return s }
        if let s = String(data: data, encoding: .isoLatin1) { return s }
        return String(data: data, encoding: .ascii)
    }

    /// All `<script type="application/ld+json">…</script>` payloads in the page.
    private static func extractJSONLD(from html: String) -> [String] {
        let pattern = "<script[^>]*type\\s*=\\s*[\"']application/ld\\+json[\"'][^>]*>(.*?)</script>"
        guard let regex = try? NSRegularExpression(
            pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators])
        else { return [] }

        let ns = html as NSString
        let matches = regex.matches(in: html, range: NSRange(location: 0, length: ns.length))
        return matches.compactMap { match in
            guard match.numberOfRanges > 1 else { return nil }
            var content = ns.substring(with: match.range(at: 1))
            content = content
                .replacingOccurrences(of: "<![CDATA[", with: "")
                .replacingOccurrences(of: "]]>", with: "")
            return content.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// Depth-first search for the first object whose `@type` is (or contains) "Recipe".
    /// Handles top-level objects, arrays, and `@graph` containers.
    private static func findRecipe(in json: Any) -> [String: Any]? {
        if let dict = json as? [String: Any] {
            if typeMatches(dict["@type"], "Recipe") { return dict }
            if let graph = dict["@graph"], let found = findRecipe(in: graph) { return found }
            for (key, value) in dict where key != "@graph" {
                if let found = findRecipe(in: value) { return found }
            }
        } else if let array = json as? [Any] {
            for value in array {
                if let found = findRecipe(in: value) { return found }
            }
        }
        return nil
    }

    private static func typeMatches(_ value: Any?, _ wanted: String) -> Bool {
        if let s = value as? String {
            return s.caseInsensitiveCompare(wanted) == .orderedSame
        }
        if let array = value as? [Any] {
            return array.contains { ($0 as? String)?.caseInsensitiveCompare(wanted) == .orderedSame }
        }
        return false
    }

    // MARK: - Mapping schema.org Recipe → our Recipe

    private static func buildRecipe(from dict: [String: Any]) -> Recipe {
        let title = stripHTML(firstString(dict["name"]) ?? "")
        let servings = parseYield(dict["recipeYield"] ?? dict["yield"])
        let minutes = parseMinutes(dict)
        let ingredients = parseIngredients(dict["recipeIngredient"] ?? dict["ingredients"])
        let steps = parseInstructions(dict["recipeInstructions"])

        return Recipe(title: title.isEmpty ? "Imported Recipe" : title,
                      minutes: minutes,
                      difficulty: "Easy",
                      baseServings: servings,
                      ingredients: ingredients,
                      steps: steps)
    }

    // MARK: Servings

    private static func parseYield(_ value: Any?) -> Int {
        func firstInt(in s: String) -> Int? {
            guard let range = s.range(of: "[0-9]+", options: .regularExpression) else { return nil }
            return Int(s[range])
        }
        switch value {
        case let n as Int:    return max(1, n)
        case let d as Double: return max(1, Int(d))
        case let s as String: return firstInt(in: s).map { max(1, $0) } ?? 2
        case let arr as [Any]:
            for item in arr {
                if let n = item as? Int { return max(1, n) }
                if let d = item as? Double { return max(1, Int(d)) }
                if let s = item as? String, let n = firstInt(in: s) { return max(1, n) }
            }
            return 2
        default:
            return 2
        }
    }

    // MARK: Time

    private static func parseMinutes(_ dict: [String: Any]) -> Int {
        if let total = parseDuration(dict["totalTime"]), total > 0 { return total }
        let cook = parseDuration(dict["cookTime"]) ?? 0
        let prep = parseDuration(dict["prepTime"]) ?? 0
        return cook + prep
    }

    /// ISO-8601 duration ("PT1H25M") → minutes. Plain integer strings are treated
    /// as minutes. Returns nil when nothing usable is found.
    private static func parseDuration(_ value: Any?) -> Int? {
        guard let raw = firstString(value)?.trimmingCharacters(in: .whitespaces),
              !raw.isEmpty else { return nil }

        let pattern = "^P(?:([0-9]+)W)?(?:([0-9]+)D)?(?:T(?:([0-9]+)H)?(?:([0-9]+)M)?(?:([0-9]+(?:\\.[0-9]+)?)S)?)?$"
        if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
            let ns = raw as NSString
            if let match = regex.firstMatch(in: raw, range: NSRange(location: 0, length: ns.length)) {
                func group(_ i: Int) -> Double {
                    let r = match.range(at: i)
                    guard r.location != NSNotFound else { return 0 }
                    return Double(ns.substring(with: r)) ?? 0
                }
                let weeks = group(1), days = group(2), hours = group(3)
                let minutes = group(4), seconds = group(5)
                let total = weeks * 7 * 24 * 60 + days * 24 * 60 + hours * 60 + minutes + seconds / 60
                let rounded = Int(total.rounded())
                if rounded > 0 { return rounded }
            }
        }

        if let n = Int(raw) { return n > 0 ? n : nil }
        return nil
    }

    // MARK: Ingredients

    private static func parseIngredients(_ value: Any?) -> [Ingredient] {
        let rawItems: [String]
        if let array = value as? [Any] {
            rawItems = array.compactMap { item in
                if let s = item as? String { return s }
                if let dict = item as? [String: Any] { return firstString(dict["text"] ?? dict["name"]) }
                return nil
            }
        } else if let s = value as? String {
            rawItems = [s]
        } else {
            rawItems = []
        }

        return rawItems
            .map(parseIngredient)
            .filter { !$0.name.isEmpty }
    }

    // Leading quantity: "1 1/2", "1/2", "1.5", "2", "1½", "½".
    private static let leadingQuantityRegex: NSRegularExpression? = {
        let frac = "½¼¾⅓⅔⅛⅜⅝⅞⅕⅖⅗⅘⅙⅚"
        let pattern = "^(?:\\d+\\s+\\d+/\\d+|\\d+/\\d+|\\d+(?:[.,]\\d+)?\\s*[\(frac)]?|[\(frac)])"
        return try? NSRegularExpression(pattern: pattern)
    }()

    private static let units: Set<String> = [
        "g", "gram", "grams", "kg", "kilogram", "kilograms", "mg",
        "ml", "milliliter", "milliliters", "millilitre", "millilitres",
        "l", "liter", "liters", "litre", "litres", "cl", "dl",
        "tsp", "teaspoon", "teaspoons", "tbsp", "tbs", "tablespoon", "tablespoons",
        "cup", "cups", "oz", "ounce", "ounces", "lb", "lbs", "pound", "pounds",
        "clove", "cloves", "pinch", "pinches", "can", "cans", "slice", "slices",
        "stick", "sticks", "pint", "pints", "quart", "quarts", "gallon", "gallons",
        "dash", "dashes", "handful", "handfuls", "sprig", "sprigs", "stalk", "stalks",
        "head", "heads", "package", "packages", "pkg", "bunch", "bunches",
        "piece", "pieces", "jar", "jars", "bottle", "bottles", "knob", "rasher", "rashers"
    ]

    private static func parseIngredient(_ raw: String) -> Ingredient {
        let cleaned = stripHTML(raw)
        guard !cleaned.isEmpty else { return Ingredient(name: "", amount: 0, unit: "") }

        let ns = cleaned as NSString
        var amount = 0.0
        var remainderStart = 0

        if let regex = leadingQuantityRegex,
           let match = regex.firstMatch(in: cleaned, range: NSRange(location: 0, length: ns.length)),
           match.range.length > 0 {
            amount = parseAmount(ns.substring(with: match.range))
            remainderStart = match.range.location + match.range.length
        }

        var remainder = ns.substring(from: remainderStart)
            .trimmingCharacters(in: .whitespaces)
        var unit = ""

        // Only treat a leading word as a unit when we actually parsed a quantity.
        if amount > 0 {
            let tokens = remainder.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            if let first = tokens.first {
                let normalized = String(first)
                    .trimmingCharacters(in: CharacterSet(charactersIn: ".,"))
                    .lowercased()
                if units.contains(normalized) {
                    unit = normalized
                    remainder = tokens.count > 1
                        ? String(tokens[1]).trimmingCharacters(in: .whitespaces)
                        : ""
                }
            }
        }

        let name = remainder.isEmpty ? cleaned : remainder
        return Ingredient(name: name, amount: amount, unit: unit)
    }

    /// Convert a quantity token ("1 1/2", "3/4", "1.5", "1½", "½") to a Double.
    private static func parseAmount(_ raw: String) -> Double {
        let unicodeFractions: [Character: Double] = [
            "½": 0.5, "¼": 0.25, "¾": 0.75, "⅓": 1.0 / 3, "⅔": 2.0 / 3,
            "⅛": 0.125, "⅜": 0.375, "⅝": 0.625, "⅞": 0.875,
            "⅕": 0.2, "⅖": 0.4, "⅗": 0.6, "⅘": 0.8, "⅙": 1.0 / 6, "⅚": 5.0 / 6
        ]

        var s = raw.trimmingCharacters(in: .whitespaces)
        var total = 0.0

        if let last = s.last, let value = unicodeFractions[last] {
            total += value
            s.removeLast()
            s = s.trimmingCharacters(in: .whitespaces)
        }

        s = s.replacingOccurrences(of: ",", with: ".")
        for part in s.split(separator: " ") {
            if part.contains("/") {
                let nums = part.split(separator: "/")
                if nums.count == 2, let n = Double(nums[0]), let d = Double(nums[1]), d != 0 {
                    total += n / d
                }
            } else if let d = Double(part) {
                total += d
            }
        }
        return total
    }

    // MARK: Instructions

    private static func parseInstructions(_ value: Any?) -> [RecipeStep] {
        var steps: [RecipeStep] = []

        func append(_ text: String?) {
            guard let text else { return }
            let cleaned = stripHTML(text)
            if !cleaned.isEmpty { steps.append(RecipeStep(text: cleaned)) }
        }

        func handle(_ item: Any) {
            if let s = item as? String {
                append(s)
            } else if let dict = item as? [String: Any] {
                // HowToSection: recurse into its list of steps.
                if typeMatches(dict["@type"], "HowToSection") || dict["itemListElement"] != nil {
                    if let list = dict["itemListElement"] {
                        handle(list)
                        return
                    }
                }
                append(firstString(dict["text"] ?? dict["name"]))
            } else if let array = item as? [Any] {
                array.forEach(handle)
            }
        }

        if let value { handle(value) }
        return steps
    }

    // MARK: - Shared helpers

    /// First usable String from a String / number / array value.
    private static func firstString(_ value: Any?) -> String? {
        switch value {
        case let s as String: return s
        case let n as Int:    return String(n)
        case let d as Double: return String(d)
        case let arr as [Any]: return arr.compactMap { firstString($0) }.first
        default: return nil
        }
    }

    /// Strip HTML tags and decode entities, collapsing whitespace.
    private static func stripHTML(_ s: String) -> String {
        var result = s.replacingOccurrences(of: "(?i)<br\\s*/?>", with: " ", options: .regularExpression)
        result = result.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        result = decodeEntities(result)
        result = result.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let namedEntities: [String: String] = [
        "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&apos;": "'", "&#39;": "'",
        "&nbsp;": " ", "&deg;": "°", "&frac12;": "½", "&frac14;": "¼", "&frac34;": "¾",
        "&frac13;": "⅓", "&frac23;": "⅔", "&hellip;": "…", "&mdash;": "—", "&ndash;": "–",
        "&rsquo;": "’", "&lsquo;": "‘", "&rdquo;": "”", "&ldquo;": "“", "&middot;": "·",
        "&eacute;": "é", "&egrave;": "è", "&agrave;": "à", "&ccedil;": "ç", "&ntilde;": "ñ",
        "&uuml;": "ü", "&ouml;": "ö", "&auml;": "ä", "&trade;": "™", "&copy;": "©", "&reg;": "®"
    ]

    private static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var result = s
        for (entity, replacement) in namedEntities {
            result = result.replacingOccurrences(of: entity, with: replacement)
        }
        result = decodeNumericEntities(result, pattern: "&#([0-9]+);", radix: 10)
        result = decodeNumericEntities(result, pattern: "&#[xX]([0-9A-Fa-f]+);", radix: 16)
        return result
    }

    private static func decodeNumericEntities(_ s: String, pattern: String, radix: Int) -> String {
        guard s.contains("&#"), let regex = try? NSRegularExpression(pattern: pattern) else { return s }
        let ns = s as NSString
        let matches = regex.matches(in: s, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return s }

        var output = ""
        var cursor = 0
        for match in matches {
            output += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let code = ns.substring(with: match.range(at: 1))
            if let value = UInt32(code, radix: radix), let scalar = Unicode.Scalar(value) {
                output.append(Character(scalar))
            }
            cursor = match.range.location + match.range.length
        }
        output += ns.substring(from: cursor)
        return output
    }
}
