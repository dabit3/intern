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
    guard ageDays.isFinite, ageDays >= 0 else { return false }
    let moment = now.addingTimeInterval(-ageDays * 86_400)
    if moment < since { return false }
    if let until, moment >= until { return false }
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
      #"\b(?:(?:in|from|within|over|during)\s+)?(?:the\s+)?(?:past|last|previous|recent)\s+(?:(\d+|(?:a\s+)?(?:couple(?:\s+of)?|few)|a|an|one|two|three|four|five|six|seven|eight|nine|ten|twelve)\s+)?(minutes?|mins?|hours?|hrs?|h|days?|weeks?|months?)\b"#,
    options: [.caseInsensitive])

  private static let namedPattern = try! NSRegularExpression(
    pattern:
      #"\b(?:(?:from|since|during|on)\s+)?(earlier\s+today|today|yesterday|this\s+morning|this\s+afternoon|this\s+evening|tonight|this\s+week|this\s+month|last\s+week|last\s+month|last\s+night|just\s+now|recently)\b"#,
    options: [.caseInsensitive])

  private static let agoPattern = try! NSRegularExpression(
    pattern:
      #"\b(?:from\s+)?(\d+|(?:a\s+)?(?:couple(?:\s+of)?|few)|a|an|one|two|three|four|five|six|seven|eight|nine|ten|twelve)\s+(days?|weeks?|months?)\s+ago\b"#,
    options: [.caseInsensitive])

  static func parse(_ query: String, now: Date = Date(), calendar: Calendar = .current)
    -> TimeWindow?
  {
    let range = NSRange(query.startIndex..., in: query)
    let relative = relativePattern.firstMatch(in: query, range: range)
    if let match = namedPattern.firstMatch(in: query, range: range),
      let phraseRange = Range(match.range, in: query),
      let keyRange = Range(match.range(at: 1), in: query),
      query[keyRange].lowercased() != "recently" || relative == nil
    {
      let key = query[keyRange].lowercased().split(whereSeparator: \.isWhitespace).joined(
        separator: " ")
      let startOfToday = calendar.startOfDay(for: now)
      var since = startOfToday
      var until: Date?
      switch key {
      case "yesterday":
        since = calendar.date(byAdding: .day, value: -1, to: startOfToday) ?? startOfToday
        until = startOfToday
      case "last night":
        let yesterday = calendar.date(byAdding: .day, value: -1, to: startOfToday) ?? startOfToday
        since = calendar.date(bySettingHour: 18, minute: 0, second: 0, of: yesterday) ?? yesterday
        until = calendar.date(bySettingHour: 6, minute: 0, second: 0, of: startOfToday)
      case "this morning":
        until = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: startOfToday)
      case "this afternoon":
        since = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: now) ?? startOfToday
        until = calendar.date(bySettingHour: 18, minute: 0, second: 0, of: now)
      case "this evening", "tonight":
        since = calendar.date(bySettingHour: 18, minute: 0, second: 0, of: now) ?? startOfToday
      case "this week":
        since = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? startOfToday
      case "last week":
        let thisWeek = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? startOfToday
        since = calendar.date(byAdding: .weekOfYear, value: -1, to: thisWeek) ?? thisWeek
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
        since = calendar.date(byAdding: .day, value: -3, to: now) ?? startOfToday
      default:
        since = startOfToday
      }
      if query[phraseRange].lowercased().hasPrefix("since ") { until = nil }
      return TimeWindow(
        phrase: String(query[phraseRange]), since: since, until: until,
        remainder: removing(phraseRange, from: query))
    }
    if let match = agoPattern.firstMatch(in: query, range: range),
      let count = count(match, in: query),
      let unitRange = Range(match.range(at: 2), in: query),
      let phraseRange = Range(match.range, in: query)
    {
      let unit = query[unitRange].lowercased()
      guard let seconds = unitSeconds[unit],
        Double(count) * seconds < now.timeIntervalSince(.distantPast)
      else { return nil }
      let component: Calendar.Component =
        unit.hasPrefix("month") ? .month : (unit.hasPrefix("week") ? .weekOfYear : .day)
      guard let date = calendar.date(byAdding: component, value: -count, to: now),
        let interval = calendar.dateInterval(of: component, for: date)
      else { return nil }
      return TimeWindow(
        phrase: String(query[phraseRange]), since: interval.start, until: interval.end,
        remainder: removing(phraseRange, from: query))
    }
    if let match = relative,
      let count = count(match, in: query),
      let unitRange = Range(match.range(at: 2), in: query),
      let seconds = unitSeconds[query[unitRange].lowercased()],
      let phraseRange = Range(match.range, in: query)
    {
      let duration = Double(count) * seconds
      guard duration < now.timeIntervalSince(.distantPast) else { return nil }
      let since =
        query[unitRange].lowercased().hasPrefix("month")
        ? calendar.date(byAdding: .month, value: -count, to: now)
        : now.addingTimeInterval(-duration)
      guard let since else { return nil }
      return TimeWindow(
        phrase: String(query[phraseRange]), since: since,
        until: nil, remainder: removing(phraseRange, from: query))
    }
    return nil
  }

  private static func count(_ match: NSTextCheckingResult, in query: String) -> Int? {
    guard let range = Range(match.range(at: 1), in: query) else { return 1 }
    let words = query[range].lowercased().split(whereSeparator: \.isWhitespace)
    let word = words.first(where: { $0 != "a" && $0 != "of" }).map(String.init) ?? "a"
    guard let value = Int(word) ?? numberWords[word], value > 0 else { return nil }
    return value
  }

  private static func removing(_ range: Range<String.Index>, from query: String) -> String {
    var text = query
    text.replaceSubrange(range, with: " ")
    return text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
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
