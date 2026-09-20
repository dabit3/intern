import Foundation

/// One row in the results list.
struct RankedHit: Identifiable, Equatable, Sendable {
  let candidate: Candidate
  let fuzzy: Double
  /// Jev's probability that this candidate is the intended target; nil when Jev did not answer.
  let jevProbability: Double?
  /// Jev's probability that this candidate fits the description in the query on its own.
  let matchProbability: Double?
  /// True when the row belongs to the set the group row would open.
  let inSet: Bool
  let score: Double
  var id: String { candidate.id }

  var isGroup: Bool {
    if case .group = candidate.payload { return true }
    return false
  }
}

/// Deterministic prefilter and ranking. Jev only ever sees the output of `prefilter`.
enum Ranker {
  static let prefilterLimit = 13
  /// With a time window the query describes a period, so more rows are shown to Jev.
  static let windowedPrefilterLimit = 30
  static let minimumFuzzy = 0.15
  /// The window already bounds the set in code, so a weaker description still gets a row in.
  static let windowedMinimumFuzzy = 0.05
  static let webSearchID = "web:search"
  static let calculationID = "calc:result"
  static let groupID = "group:all"

  private static let fileTypes: [String: Set<String>] = [
    "pdf": ["pdf"], "paper": ["pdf"],
    "image": ["png", "jpg", "jpeg", "gif", "heic", "webp"],
    "picture": ["png", "jpg", "jpeg", "gif", "heic", "webp"],
    "photo": ["png", "jpg", "jpeg", "gif", "heic", "webp"],
    "screenshot": ["png", "jpg", "jpeg", "heic"],
    "video": ["mov", "mp4", "m4v"], "movie": ["mov", "mp4", "m4v"],
    "spreadsheet": ["csv", "xlsx", "xls", "numbers"],
    "presentation": ["ppt", "pptx", "key"], "deck": ["ppt", "pptx", "key"],
    "archive": ["zip", "tar", "gz"], "installer": ["dmg", "pkg"],
  ]
  private static let recencyWords: Set<String> = [
    "latest", "newest", "recent", "recently", "most", "downloaded", "download",
    "added", "opened", "used", "modified", "edited", "visited",
  ]
  private static let fileWords: Set<String> = ["file", "files", "document", "documents"]
  private static let linkWords: Set<String> = ["link", "links", "page", "pages", "site", "sites"]
  private static let fileExtensions = Set(fileTypes.values.flatMap { $0 }).union([
    "doc", "docx", "odt", "rtf", "rtfd", "txt", "md", "swift", "json", "app",
    "html", "css", "js", "ts", "py", "rb", "sh", "yml", "yaml", "xml", "plist",
  ])

  /// Personal-library boosts are clamped to this; a boost at or above `aliasBoost` marks an item
  /// the user chose for this exact query before.
  static let maximumBoost = 0.35
  static let aliasBoost = 0.3

  /// Jev must lean at least this far toward "all" before the group row leads the list.
  static let setThreshold = 0.5
  /// A candidate is part of the set when Jev is at least this sure it fits the description.
  static let memberThreshold = 0.6
  /// Below this the query reads as clearly singular and no group row is offered at all.
  static let offerThreshold = 0.15
  /// With `one` intent, a group row is still offered (below the top hit) when this many rows fit.
  static let minimumSetSize = 2
  static let maximumSetSize = 25

  struct Prefiltered: Equatable, Sendable {
    let candidates: [Candidate]
    let fuzzy: [String: Double]
    let window: TimeWindow?

    init(candidates: [Candidate], fuzzy: [String: Double], window: TimeWindow? = nil) {
      self.candidates = candidates
      self.fuzzy = fuzzy
      self.window = window
    }
  }

  /// A candidate with its searchable text tokenized once, so each keystroke only compares.
  struct Entry: Sendable {
    let candidate: Candidate
    let document: Fuzzy.Document

    init(_ candidate: Candidate) {
      self.candidate = candidate
      document = Fuzzy.Document(candidate)
    }

    init(candidate: Candidate, document: Fuzzy.Document) {
      self.candidate = candidate
      self.document = document
    }
  }

  static func prefilter(
    query: String, index: [Candidate], now: Date = Date(), scope: SearchScope = .all,
    boosts: [String: Double] = [:]
  ) -> Prefiltered {
    prefilter(query: query, entries: index.map(Entry.init), now: now, scope: scope, boosts: boosts)
  }

  /// Fuzzy-scores the whole index and keeps the top-k, then appends synthetic candidates
  /// (a calculation when the query parses, and a web search for any non-empty query).
  /// A time window in the query is applied here, in code: items outside it are never sent.
  static func prefilter(
    query: String, entries: [Entry], now: Date = Date(), scope: SearchScope = .all,
    boosts: [String: Double] = [:]
  ) -> Prefiltered {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return Prefiltered(candidates: [], fuzzy: [:]) }
    let window = TimeWindow.parse(trimmed, now: now)
    let matchQuery = window?.remainder.trimmingCharacters(in: .whitespacesAndNewlines) ?? trimmed
    let fullQuery = Fuzzy.Query(trimmed)
    let words = Fuzzy.tokens(matchQuery)
    let typeWords = Set(words.filter { fileTypes[singular($0)] != nil })
    let extensions = typeWords.reduce(into: Set<String>()) {
      $0.formUnion(fileTypes[singular($1)] ?? [])
    }
    let wordSet = Set(words)
    let wantsFiles =
      !extensions.isEmpty
      || (!wordSet.isDisjoint(with: fileWords) && !wordSet.contains("hidden"))
    let wantsLinks = !wantsFiles && !wordSet.isDisjoint(with: linkWords)
    let hasRecency = window != nil || !wordSet.isDisjoint(with: recencyWords)
    let structured = wantsFiles || wantsLinks || hasRecency
    var descriptiveWords =
      structured
      ? words.filter {
        !Fuzzy.stopwords.contains($0) && !typeWords.contains($0)
          && !recencyWords.contains($0) && !fileWords.contains($0) && !linkWords.contains($0)
      } : words
    if structured, let last = descriptiveWords.last, last == words.last,
      Fuzzy.isStopwordPrefix(last)
    {
      descriptiveWords.removeLast()
    }
    let prepared = Fuzzy.Query(descriptiveWords.joined(separator: " "))
    // "everything from the past hour": nothing describable is left once stopwords go.
    let windowOnly =
      window != nil && descriptiveWords.isEmpty
    let limit = window == nil ? prefilterLimit : windowedPrefilterLimit
    let floor = window == nil ? minimumFuzzy : windowedMinimumFuzzy

    var scored: [(candidate: Candidate, score: Double, age: Double)] = []
    let recency = FileRecency(query: trimmed)
    scored.reserveCapacity(min(entries.count, 256))
    for entry in entries where scope.includes(entry.candidate) {
      let candidate = entry.candidate
      let lexical = Fuzzy.score(query: prepared, document: entry.document, exactQuery: fullQuery)
      if lexical < 1 {
        if wantsFiles, !SearchScope.files.includes(candidate) { continue }
        if wantsLinks, !SearchScope.links.includes(candidate) { continue }
        if !extensions.isEmpty,
          !extensions.contains(candidate.fileURL?.pathExtension.lowercased() ?? "")
        {
          continue
        }
      }
      let age = candidate.age(for: recency, now: now)
      if lexical < 1 {
        if recency == .opened, SearchScope.files.includes(candidate), age == nil {
          continue
        }
        if hasRecency, let age, age < 0 { continue }
        if let window {
          if let age, !window.contains(ageDays: age, now: now) { continue }
          if age == nil,
            SearchScope.files.includes(candidate) || SearchScope.links.includes(candidate)
          {
            continue
          }
        }
      }
      let suppliedBoost = boosts[candidate.id] ?? 0
      let boost = suppliedBoost.isFinite ? min(maximumBoost, max(0, suppliedBoost)) : 0
      let score: Double
      if structured, descriptiveWords.isEmpty, lexical < 1 {
        if windowOnly || hasRecency {
          guard age != nil else { continue }
        }
        score = 0.8
      } else {
        // A learned alias (the user picked this item for exactly this query before) counts as
        // a strong match even when the words differ; other habits only strengthen real matches.
        guard lexical > 0 || boost >= aliasBoost else { continue }
        let relevance = max(lexical, boost >= aliasBoost ? 0.7 : 0)
        score = lexical == 1 ? 1 : min(0.99, relevance + boost)
      }
      if score >= floor { scored.append((candidate, score, age ?? .infinity)) }
    }
    scored.sort { lhs, rhs in
      if lhs.score != rhs.score { return lhs.score > rhs.score }
      if lhs.age != rhs.age { return lhs.age < rhs.age }
      if lhs.candidate.title != rhs.candidate.title {
        return lhs.candidate.title < rhs.candidate.title
      }
      return lhs.candidate.id < rhs.candidate.id
    }
    var candidates: [Candidate] = []
    var fuzzy: [String: Double] = [:]
    if scope == .all, let evaluation = Calculator.evaluate(trimmed) {
      let calc = Candidate(
        id: calculationID, title: "= \(evaluation.formatted)",
        subtitle: "\(evaluation.expression) · Enter copies the result", kind: .calculate,
        payload: .calculation(expression: evaluation.expression, result: evaluation.formatted))
      candidates.append(calc)
      fuzzy[calc.id] = 0.95
    }
    var seen = Set(candidates.map(\.id))
    var retained = 0
    for item in scored where seen.insert(item.candidate.id).inserted {
      guard retained < limit else { break }
      candidates.append(item.candidate)
      fuzzy[item.candidate.id] = item.score
      retained += 1
    }
    let web = Candidate(
      id: webSearchID, title: "Search the web for “\(trimmed)”",
      subtitle: "Opens your default browser", kind: .webSearch, payload: .webSearch(trimmed))
    if scope == .all || scope == .links {
      if let url = directURL(trimmed),
        !candidates.contains(where: { $0.kind != .openURL && fuzzy[$0.id] == 1 })
      {
        let id = "url:\(url.absoluteString)"
        candidates.removeAll { $0.id == id }
        candidates.insert(
          Candidate(
            id: id, title: url.absoluteString, subtitle: "Open website", kind: .openURL,
            payload: .url(url)), at: 0)
        fuzzy[id] = 1
      }
      candidates.append(web)
      fuzzy[web.id] = 0.1
    }
    return Prefiltered(candidates: candidates, fuzzy: fuzzy, window: window)
  }

  private static func singular(_ word: String) -> String {
    word.hasSuffix("s") ? String(word.dropLast()) : word
  }

  private static func directURL(_ text: String) -> URL? {
    guard !text.contains(where: { $0.isWhitespace || $0.isNewline }) else { return nil }
    let explicit = text.contains("://")
    guard let components = URLComponents(string: explicit ? text : "https://\(text)"),
      let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
      components.user == nil, components.password == nil,
      let host = components.host, !host.isEmpty,
      components.port.map({ (1...65_535).contains($0) }) ?? true,
      let url = components.url
    else { return nil }
    if !explicit {
      let labels = host.split(separator: ".", omittingEmptySubsequences: false)
      guard labels.count >= 2, labels.allSatisfy({ !$0.isEmpty }),
        let suffix = labels.last, suffix.count >= 2,
        suffix.allSatisfy(\.isLetter),
        !fileExtensions.contains(suffix.lowercased())
      else { return nil }
    }
    return url
  }

  static let targetWeight = 0.65
  static let actionWeight = 0.20
  static let fuzzyWeight = 0.15
  /// Set members rise with the strength of the "all of them" reading so they sit together.
  static let setMemberWeight = 0.25
  /// A judgment for an earlier draft of the query keeps this share of its influence.
  static let staleWeight = 0.5
  /// Typing an item's exact name is definitive; no online reading demotes it below this.
  static let exactNameFloor = 0.9

  /// Merges fuzzy scores with Jev's judgment. With no judgment the order is pure fuzzy.
  /// When Jev finds several rows that fit the description, a group row is added: on top when
  /// Jev reads the query as "all of them", just below the single best hit when it could go
  /// either way, and not at all when the query is clearly about one item. A stale judgment
  /// (for a prefix of the current query) only nudges the order and never offers a group.
  static func rank(_ prefiltered: Prefiltered, judgment: JevJudgment?, fresh: Bool = true)
    -> [RankedHit]
  {
    let members = fresh ? setMembers(prefiltered, judgment: judgment) : []
    let candidates = uniqueCandidates(prefiltered.candidates)
    let positions = Dictionary(
      uniqueKeysWithValues: candidates.enumerated().map { ($0.element.id, $0.offset) })
    let probabilities = judgment?.targetProbabilities.values.sorted(by: >) ?? []
    let lead = (probabilities.first ?? 0) - (probabilities.dropFirst().first ?? 0)
    let onlineWeight =
      min(1, 2 * max(judgment?.targetConfidence ?? 0, lead)) * (fresh ? 1 : staleWeight)
    var hits = candidates.map { candidate -> RankedHit in
      let fuzzy = prefiltered.fuzzy[candidate.id] ?? 0
      guard let judgment else {
        return RankedHit(
          candidate: candidate, fuzzy: fuzzy, jevProbability: nil, matchProbability: nil,
          inSet: false, score: fuzzy)
      }
      let target = judgment.targetProbabilities[candidate.id] ?? 0
      let action = judgment.actionProbabilities[candidate.kind] ?? 0
      let match = judgment.matchProbabilities[candidate.id]
      let inSet = members.contains(candidate.id)
      var score =
        onlineWeight * (targetWeight * target + actionWeight * action)
        + (1 - onlineWeight * (1 - fuzzyWeight)) * fuzzy
      if inSet { score += setMemberWeight * judgment.setProbability * (match ?? 0) }
      if fuzzy == 1, candidate.isOpenable || candidate.kind == .systemToggle {
        score = max(score, exactNameFloor)
      }
      return RankedHit(
        candidate: candidate, fuzzy: fuzzy, jevProbability: target, matchProbability: match,
        inSet: inSet, score: score)
    }
    hits.sort { lhs, rhs in
      if lhs.score != rhs.score { return lhs.score > rhs.score }
      return (positions[lhs.id] ?? 0) < (positions[rhs.id] ?? 0)
    }
    guard let judgment, !members.isEmpty else { return hits }
    let ordered = hits.filter { members.contains($0.candidate.id) }.map(\.candidate)
    let group = RankedHit(
      candidate: groupCandidate(ordered), fuzzy: 0, jevProbability: judgment.setProbability,
      matchProbability: nil, inSet: false, score: judgment.setProbability)
    if judgment.setProbability >= setThreshold {
      // With no single target to pick, the target Choice leaks onto the web-search fallback;
      // keep it as the last resort so the members sit under the group row.
      hits =
        hits.filter(\.inSet) + hits.filter { !$0.inSet && $0.id != webSearchID }
        + hits.filter { $0.id == webSearchID }
      hits.insert(group, at: 0)
    } else {
      hits.insert(group, at: min(1, hits.count))
    }
    return hits
  }

  /// Candidate ids Jev judged to fit the description, bounded in size. Empty unless a group is
  /// worth offering: at least two members and a query that is not clearly about one item.
  static func setMembers(_ prefiltered: Prefiltered, judgment: JevJudgment?) -> Set<String> {
    guard let judgment, judgment.setProbability >= offerThreshold else { return [] }
    let eligible = uniqueCandidates(prefiltered.candidates).filter { candidate in
      candidate.isOpenable
        && (judgment.matchProbabilities[candidate.id] ?? 0) >= memberThreshold
    }
    let sorted = eligible.sorted {
      (judgment.matchProbabilities[$0.id] ?? 0) > (judgment.matchProbabilities[$1.id] ?? 0)
    }
    guard sorted.count >= minimumSetSize else { return [] }
    return Set(sorted.prefix(maximumSetSize).map(\.id))
  }

  private static func uniqueCandidates(_ candidates: [Candidate]) -> [Candidate] {
    var seen = Set<String>()
    return candidates.filter { seen.insert($0.id).inserted }
  }

  static func groupCandidate(_ members: [Candidate]) -> Candidate {
    let kinds = Set(members.map(\.kind))
    let kind = kinds.count == 1 ? kinds.first! : .unclear
    let noun: String
    switch kind {
    case .openURL: noun = "link"
    case .openFile: noun = "file"
    case .openApp: noun = "app"
    default: noun = "item"
    }
    let names = members.prefix(3).map(\.title).joined(separator: ", ")
    let more = members.count > 3 ? " and \(members.count - 3) more" : ""
    return Candidate(
      id: groupID,
      title: members.count == 1 ? "Open 1 \(noun)" : "Open all \(members.count) \(noun)s",
      subtitle: names + more, kind: kind, payload: .group(members))
  }
}
