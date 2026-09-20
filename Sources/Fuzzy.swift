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

  /// True for an incomplete filler word: "j", "ju" and "jus" on the way to "just".
  static func isStopwordPrefix(_ word: String) -> Bool {
    !word.isEmpty && !stopwords.contains(word) && stopwords.contains { $0.hasPrefix(word) }
  }

  struct Term: Sendable {
    let text: String
    let count: Int
    let bytes: [UInt8]

    init(_ text: String) {
      self.text = text
      count = text.count
      bytes = Array(text.utf8)
    }
  }

  struct Query {
    let all: [String]
    let meaningful: [String]
    let directed: [String]
    let joined: String
    let weightedMeaningful: [(term: Term, count: Int)]
    let weightedDirected: [(term: Term, count: Int)]

    init(_ text: String) {
      all = tokens(text)
      var filtered = all.filter { !stopwords.contains($0) }
      // A trailing token that is only the beginning of a filler word is still being typed;
      // scoring it as unmatched would empty the list until the word completes.
      if filtered.count > 1, let last = all.last, filtered.last == last, isStopwordPrefix(last) {
        filtered.removeLast()
      }
      meaningful = filtered.isEmpty ? all : filtered
      directed = all.filter { !stopwords.contains($0) || $0 == "on" || $0 == "show" }
      joined = all.joined()
      weightedMeaningful = Self.weighted(meaningful)
      weightedDirected = Self.weighted(directed)
    }

    private static func weighted(_ words: [String]) -> [(term: Term, count: Int)] {
      var counts: [String: Int] = [:]
      var ordered: [String] = []
      for word in words {
        if counts[word] == nil { ordered.append(word) }
        counts[word, default: 0] += 1
      }
      return ordered.map { (Term($0), counts[$0, default: 0]) }
    }
  }

  /// A candidate's searchable text, tokenized once so scoring a keystroke allocates nothing.
  struct Document: Sendable {
    let titleTokens: [String]
    let firstTitleToken: String
    let joinedTitle: String
    let joinedTitleBytes: [UInt8]
    let terms: [Term]
    let initials: String
    let longestTerm: Int
    let isToggle: Bool

    init(_ candidate: Candidate) {
      titleTokens = tokens(candidate.title)
      firstTitleToken = titleTokens.first ?? ""
      joinedTitle = titleTokens.joined()
      joinedTitleBytes = Array(joinedTitle.utf8)
      terms = (titleTokens + candidate.keywords.flatMap(tokens) + candidate.appRoleTerms).map(
        Term.init)
      initials = String(titleTokens.compactMap(\.first))
      longestTerm = terms.map(\.bytes.count).max() ?? 0
      isToggle = candidate.kind == .systemToggle
    }
  }

  /// Score in 0...1. Zero means the candidate should not be shown for this query.
  static func score(query: String, candidate: Candidate) -> Double {
    score(query: Query(query), candidate: candidate)
  }

  static func score(query: Query, candidate: Candidate, exactQuery: Query? = nil) -> Double {
    score(query: query, document: Document(candidate), exactQuery: exactQuery)
  }

  static func score(query: Query, document: Document, exactQuery: Query? = nil) -> Double {
    guard !query.all.isEmpty || exactQuery != nil else { return 0 }
    let meaningful = document.isToggle ? query.directed : query.meaningful
    let exact = exactQuery ?? query
    let exactWords = document.isToggle ? exact.directed : exact.meaningful
    if exact.all == document.titleTokens || exactWords == document.titleTokens
      || exact.joined == document.joinedTitle
    {
      return 1
    }
    guard !meaningful.isEmpty else { return 0 }

    var total = 0.0
    var unmatched = 0
    let weighted = document.isToggle ? query.weightedDirected : query.weightedMeaningful
    for token in weighted {
      let best = bestMatch(token: token.term, document: document)
      if best == 0 { unmatched += token.count }
      total += best * Double(token.count)
    }
    guard total > 0 else { return 0 }
    var score = total / Double(meaningful.count)
    if unmatched > 0 { score *= 0.5 }
    return min(0.95, score)
  }

  private static func bestMatch(token: Term, document: Document) -> Double {
    let length = token.count
    guard length <= document.joinedTitleBytes.count || length <= document.longestTerm + 1 else {
      return 0
    }
    var best = 0.0
    for term in document.terms {
      if term.text == token.text {
        return 0.9
      }
      if token.text.hasSuffix("s"), token.bytes.dropLast().elementsEqual(term.bytes) {
        best = max(best, 0.88)
      }
      if term.text.hasPrefix(token.text) {
        // Starting the name ("sa" → Safari) is a stronger signal than starting a later word.
        let lead = term.text == document.firstTitleToken ? 0.03 : 0
        best = max(best, 0.72 + 0.15 * Double(length) / Double(term.count) + lead)
      }
    }
    if best > 0 { return best }
    if length >= 2, document.initials.hasPrefix(token.text) {
      return 0.7
    }
    if document.joinedTitle.contains(token.text) {
      return 0.55
    }
    if length >= 4,
      document.terms.contains(where: { $0.count >= 4 && isSingleEdit(token.bytes, $0.bytes) })
    {
      return 0.65
    }
    if length >= 3,
      let contiguity = subsequenceContiguity(token.bytes, in: document.joinedTitleBytes)
    {
      return 0.2 + 0.2 * contiguity
    }
    return 0
  }

  static func isSingleEdit(_ a: [UInt8], _ b: [UInt8]) -> Bool {
    guard abs(a.count - b.count) <= 1 else { return false }
    if a.count == b.count {
      var first = -1
      var second = -1
      for index in a.indices where a[index] != b[index] {
        if first < 0 {
          first = index
        } else if second < 0 {
          second = index
        } else {
          return false
        }
      }
      if first < 0 { return false }
      if second < 0 { return true }
      return second == first + 1 && a[first] == b[second] && a[second] == b[first]
    }
    let shorter = a.count < b.count ? a : b
    let longer = a.count < b.count ? b : a
    var index = 0
    while index < shorter.count, shorter[index] == longer[index] { index += 1 }
    return shorter[index...].elementsEqual(longer[(index + 1)...])
  }

  /// Returns the fraction of adjacent matches when `needle` is a subsequence of `haystack`.
  static func subsequenceContiguity(_ needle: String, in haystack: String) -> Double? {
    subsequenceContiguity(Array(needle.utf8), in: Array(haystack.utf8))
  }

  static func subsequenceContiguity(_ needle: [UInt8], in haystack: [UInt8]) -> Double? {
    guard !needle.isEmpty else { return 1 }
    var needleIndex = 0
    var lastMatch = -2
    var adjacent = 0
    for index in haystack.indices where needleIndex < needle.count {
      if haystack[index] == needle[needleIndex] {
        if lastMatch == index - 1 { adjacent += 1 }
        lastMatch = index
        needleIndex += 1
      }
    }
    guard needleIndex == needle.count else { return nil }
    return needle.count > 1 ? Double(adjacent) / Double(needle.count - 1) : 1
  }
}
