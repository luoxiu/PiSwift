// BM25 tool search for code mode's `searchTools()` and the `tool_search` tool, a copy of the coding agent's tool search
// ranking: durable keeps its own copy of what it needs from the coding agent.

import Foundation

/// A document to rank: a tool's name and its search text.
struct SearchDocument: Sendable, Equatable {
    let name: String
    let text: String
}

private let stopWords: Set<String> = [
    "a", "an", "and", "are", "as", "at", "be", "by", "for", "from", "in", "is", "it",
    "of", "on", "or", "that", "the", "this", "to", "with",
]

/// Naive singular form, so `issues` matches `issue` and `searches` matches `search`. Terms are ASCII, so `count` is the
/// UTF-16 length upstream compares.
private func stem(_ term: String) -> String {
    if term.count > 4 && term.hasSuffix("ies") { return String(term.dropLast(3)) + "y" }
    if term.count > 4 && ["ches", "shes", "sses", "xes", "zes"].contains(where: term.hasSuffix) { return String(term.dropLast(2)) }
    if term.count > 3 && term.hasSuffix("s") && !term.hasSuffix("ss") { return String(term.dropLast()) }
    return term
}

private let lowerUpperBoundary = try! NSRegularExpression(pattern: "([a-z0-9])([A-Z])")
private let acronymBoundary = try! NSRegularExpression(pattern: "([A-Z]+)([A-Z][a-z])")

/// Lowercase terms, split at camelCase boundaries and non-alphanumerics, without stop words.
func tokenize(_ text: String) -> [String] {
    var spaced = text
    for boundary in [lowerUpperBoundary, acronymBoundary] {
        spaced = boundary.stringByReplacingMatches(in: spaced, range: NSRange(spaced.startIndex..., in: spaced),
                                                   withTemplate: "$1 $2")
    }
    var terms: [String] = []
    var term = String.UnicodeScalarView()
    func finish() {
        let value = String(term)
        if !value.isEmpty && !stopWords.contains(value) { terms.append(stem(value)) }
        term = String.UnicodeScalarView()
    }
    // Split at anything but `a-z0-9` after lowercasing, as upstream's `[^a-z0-9]+`.
    for scalar in spaced.lowercased().unicodeScalars {
        if (97...122).contains(scalar.value) || (48...57).contains(scalar.value) { term.append(scalar) } else { finish() }
    }
    finish()
    return terms
}

/// Okapi BM25 (k1 1.2, b 0.75): the names of the best matches, best first; ties keep document order.
func rankDocuments(_ query: String, _ documents: [SearchDocument], limit: Int) -> [String] {
    let k1 = 1.2
    let b = 0.75
    var seen = Set<String>()
    let queryTerms = tokenize(query).filter { seen.insert($0).inserted }
    if queryTerms.isEmpty || documents.isEmpty || limit <= 0 { return [] }
    let termCounts = documents.map { document in
        tokenize(document.text).reduce(into: [String: Int]()) { $0[$1, default: 0] += 1 }
    }
    let lengths = termCounts.map { $0.values.reduce(0, +) }
    let average = Double(lengths.reduce(0, +)) / Double(documents.count)
    let averageLength = average == 0 ? 1 : average
    let idf = Dictionary(uniqueKeysWithValues: queryTerms.map { term in
        let frequency = termCounts.filter { $0[term] != nil }.count
        return (term, log(1 + (Double(documents.count - frequency) + 0.5) / (Double(frequency) + 0.5)))
    })
    var matches: [(index: Int, name: String, score: Double)] = []
    for (index, document) in documents.enumerated() {
        var score = 0.0
        for term in queryTerms {
            guard let count = termCounts[index][term], count > 0 else { continue }
            let norm = k1 * (1 - b + b * Double(lengths[index]) / averageLength)
            score += (idf[term] ?? 0) * (Double(count) * (k1 + 1) / (Double(count) + norm))
        }
        if score > 0 { matches.append((index, document.name, score)) }
    }
    // Upstream's sort is stable; the index keeps tied documents in order.
    return matches.sorted { $0.score == $1.score ? $0.index < $1.index : $0.score > $1.score }
        .prefix(limit).map(\.name)
}
