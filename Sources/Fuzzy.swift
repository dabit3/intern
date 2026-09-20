import Foundation

/// Fast, deterministic fuzzy matcher used to prefilter the local index before anything is sent
/// to Jev, and as the complete ranking when Jev is off or unavailable.
enum Fuzzy {
  static let stopwords: Set<String> = [
    "the", "a", "an", "i", "my", "me", "to", "of", "that", "just", "please", "open", "launch",
    "run", "go", "show", "find", "get", "up", "it", "ve", "s", "d", "ll", "re", "m", "in", "on",
    "from", "for", "with", "all", "every", "everything", "any", "and", "was", "were", "been",
    "have", "had", "ive", "did", "about", "at", "page", "pages", "site", "sites", "stuff",
    "thing", "things", "read", "looked", "saw", "some", "those", "these", "them", "this",
    "opened", "used", "last", "edited", "modified", "working", "worked",
  ]

  static func tokens(_ text: String) -> [String] {
    if text.utf8.allSatisfy({ $0 < 128 }) {
      return text.utf8.split(whereSeparator: {
        !(65...90).contains($0) && !(97...122).contains($0) && !(48...57).contains($0)
      }).map { String(decoding: $0, as: UTF8.self).lowercased() }
    }
    let normalized = text.folding(
      options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
      locale: Locale(identifier: "en_US_POSIX"))
    return normalized.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map {
      String($0)
    }
  }

  struct Query {
    let all: [String]
    let meaningful: [String]
    let directed: [String]

    init(_ text: String) {
      all = tokens(text)
      let filtered = all.filter { !stopwords.contains($0) }
      meaningful = filtered.isEmpty ? all : filtered
      directed = all.filter { !stopwords.contains($0) || $0 == "on" || $0 == "show" }
    }
  }

  /// Score in 0...1. Zero means the candidate should not be shown for this query.
  static func score(query: String, candidate: Candidate) -> Double {
    score(query: Query(query), candidate: candidate)
  }

  static func score(query: Query, candidate: Candidate, exactQuery: Query? = nil) -> Double {
    guard !query.all.isEmpty || exactQuery != nil else { return 0 }
    let meaningful = candidate.kind == .systemToggle ? query.directed : query.meaningful
    let titleTokens = tokens(candidate.title)
    let joinedTitle = titleTokens.joined()
    let exact = exactQuery ?? query
    let exactWords = candidate.kind == .systemToggle ? exact.directed : exact.meaningful
    if exact.all == titleTokens || exactWords == titleTokens
      || exact.all.joined() == joinedTitle
    {
      return 1
    }
    guard !meaningful.isEmpty else { return 0 }
    let terms = titleTokens + candidate.keywords.flatMap(tokens) + candidate.appRoleTerms
    let initials = String(titleTokens.compactMap(\.first))

    var total = 0.0
    var unmatched = 0
    for token in meaningful {
      let best = bestMatch(
        token: token, terms: terms, joinedTitle: joinedTitle, initials: initials)
      if best == 0 { unmatched += 1 }
      total += best
    }
    guard total > 0 else { return 0 }
    var score = total / Double(meaningful.count)
    if unmatched > 0 { score *= 0.5 }
    return min(0.95, score)
  }

  private static func bestMatch(
    token: String, terms: [String], joinedTitle: String, initials: String
  )
    -> Double
  {
    var best = 0.0
    for term in terms {
      if term == token {
        return 0.9
      }
      if token.hasSuffix("s"), String(token.dropLast()) == term {
        best = max(best, 0.88)
      }
      if term.hasPrefix(token) {
        best = max(best, 0.72 + 0.15 * Double(token.count) / Double(term.count))
      }
    }
    if best > 0 { return best }
    if token.count >= 2, initials.hasPrefix(token) {
      return 0.7
    }
    if joinedTitle.contains(token) {
      return 0.55
    }
    if token.count >= 4,
      terms.contains(where: { $0.count >= 4 && isSingleEdit(token, $0) })
    {
      return 0.65
    }
    if token.count >= 3, let contiguity = subsequenceContiguity(token, in: joinedTitle) {
      return 0.2 + 0.2 * contiguity
    }
    return 0
  }

  private static func isSingleEdit(_ lhs: String, _ rhs: String) -> Bool {
    guard abs(lhs.count - rhs.count) <= 1 else { return false }
    let a = Array(lhs)
    let b = Array(rhs)
    if a.count == b.count {
      let differences = a.indices.filter { a[$0] != b[$0] }
      if differences.count == 1 { return true }
      guard differences.count == 2, differences[1] == differences[0] + 1 else { return false }
      let index = differences[0]
      return a[index] == b[index + 1] && a[index + 1] == b[index]
    }
    let shorter = a.count < b.count ? a : b
    let longer = a.count < b.count ? b : a
    var index = 0
    while index < shorter.count, shorter[index] == longer[index] { index += 1 }
    return shorter[index...] == longer[(index + 1)...]
  }

  /// Returns the fraction of adjacent matches when `needle` is a subsequence of `haystack`.
  static func subsequenceContiguity(_ needle: String, in haystack: String) -> Double? {
    var needleIndex = needle.startIndex
    var lastMatch: String.Index?
    var adjacent = 0
    for index in haystack.indices where needleIndex < needle.endIndex {
      if haystack[index] == needle[needleIndex] {
        if let last = lastMatch, haystack.index(after: last) == index { adjacent += 1 }
        lastMatch = index
        needleIndex = needle.index(after: needleIndex)
      }
    }
    guard needleIndex == needle.endIndex else { return nil }
    return needle.count > 1 ? Double(adjacent) / Double(needle.count - 1) : 1
  }
}
