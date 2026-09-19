import Foundation

/// A recency constraint parsed from the query in code: "in the past 24 hours", "yesterday",
/// "this week". Jev never does date math; it only sees the phrase and each candidate's recency.
struct TimeWindow: Equatable, Sendable {
  /// The words that expressed the window, exactly as typed.
  let phrase: String
  /// Oldest moment that still counts. Items older than this are dropped before Jev sees them.
  let since: Date
  /// Newest moment that still counts, for windows like "yesterday". Nil means up to now.
  let until: Date?
  /// The query with the window phrase removed, for fuzzy matching against titles.
  let remainder: String

  func contains(ageDays: Double, now: Date) -> Bool {
    let moment = now.addingTimeInterval(-ageDays * 86_400)
    if moment < since { return false }
    if let until, moment > until { return false }
    return true
  }

  private static let unitSeconds: [String: TimeInterval] = [
    "minute": 60, "minutes": 60, "min": 60, "mins": 60,
    "hour": 3_600, "hours": 3_600, "hr": 3_600, "hrs": 3_600, "h": 3_600,
    "day": 86_400, "days": 86_400,
    "week": 604_800, "weeks": 604_800,
    "month": 2_592_000, "months": 2_592_000,
  ]

  private static let numberWords: [String: Int] = [
    "a": 1, "an": 1, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6,
    "seven": 7, "eight": 8, "nine": 9, "ten": 10, "twelve": 12, "couple": 2, "few": 3,
  ]

  /// Relative patterns, tried in order. `$N` is a count, `$U` a unit word.
  private static let relativePattern = try! NSRegularExpression(
    pattern:
      #"\b(?:(?:in|from|within|over|during)\s+)?(?:the\s+)?(?:past|last|previous|recent)\s+(?:(\d+|a|an|one|two|three|four|five|six|seven|eight|nine|ten|twelve|couple(?:\s+of)?|few)\s+)?([a-z]+)\b"#,
    options: [.caseInsensitive])

  private static let namedPattern = try! NSRegularExpression(
    pattern:
      #"\b(?:(?:from|since|during|on)\s+)?(today|yesterday|this\s+morning|this\s+afternoon|this\s+evening|tonight|this\s+week|this\s+month|last\s+week|last\s+month|last\s+night|earlier\s+today|just\s+now|recently)\b"#,
    options: [.caseInsensitive])

  static func parse(_ query: String, now: Date = Date(), calendar: Calendar = .current)
    -> TimeWindow?
  {
    let range = NSRange(query.startIndex..., in: query)
    if let match = relativePattern.firstMatch(in: query, range: range),
      let unitRange = Range(match.range(at: 2), in: query),
      let seconds = unitSeconds[query[unitRange].lowercased()]
    {
      var count = 1
      if let countRange = Range(match.range(at: 1), in: query) {
        let word = query[countRange].lowercased().replacingOccurrences(of: " of", with: "")
        count = Int(word) ?? numberWords[word] ?? 1
      }
      guard let phraseRange = Range(match.range, in: query) else { return nil }
      return TimeWindow(
        phrase: String(query[phraseRange]),
        since: now.addingTimeInterval(-Double(count) * seconds),
        until: nil,
        remainder: removing(phraseRange, from: query))
    }
    if let match = namedPattern.firstMatch(in: query, range: range),
      let phraseRange = Range(match.range, in: query)
    {
      let key = query[phraseRange].lowercased().split(separator: " ").joined(separator: " ")
      let startOfToday = calendar.startOfDay(for: now)
      let day: TimeInterval = 86_400
      var since = startOfToday
      var until: Date?
      switch key {
      case "yesterday", "last night":
        since = startOfToday.addingTimeInterval(-day)
        until = startOfToday
      case "this week":
        since = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? startOfToday
      case "last week":
        let thisWeek = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? startOfToday
        since = thisWeek.addingTimeInterval(-7 * day)
        until = thisWeek
      case "this month":
        since = calendar.dateInterval(of: .month, for: now)?.start ?? startOfToday
      case "last month":
        let thisMonth = calendar.dateInterval(of: .month, for: now)?.start ?? startOfToday
        since = calendar.date(byAdding: .month, value: -1, to: thisMonth) ?? thisMonth
        until = thisMonth
      case "just now":
        since = now.addingTimeInterval(-15 * 60)
      case "recently":
        since = now.addingTimeInterval(-3 * day)
      default:  // today, this morning/afternoon/evening, tonight, earlier today
        since = startOfToday
      }
      return TimeWindow(
        phrase: String(query[phraseRange]), since: since, until: until,
        remainder: removing(phraseRange, from: query))
    }
    return nil
  }

  private static func removing(_ range: Range<String.Index>, from query: String) -> String {
    var text = query
    text.removeSubrange(range)
    return text.split(separator: " ").joined(separator: " ")
  }

  /// How the window is described to Jev alongside the query.
  var description: String {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .full
    var text = "\(phrase): items from \(formatter.localizedString(for: since, relativeTo: Date()))"
    if let until {
      text += " until \(formatter.localizedString(for: until, relativeTo: Date()))"
    }
    return text
  }
}
