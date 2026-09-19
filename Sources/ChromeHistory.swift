import Foundation
import SQLite3

/// Reads Google Chrome's local history database into candidates. Chrome keeps the file locked
/// while running, so it is copied to a private location first. Only title, URL and last-visit
/// time leave this type; nothing is written back and nothing is logged.
enum ChromeHistory {
  static let maxEntries = 3_000
  /// Visits older than this are not indexed at all.
  static let maxAgeDays = 90.0

  static let profileRoot = "Library/Application Support/Google/Chrome"

  struct Entry: Equatable, Sendable {
    let url: URL
    let title: String
    let lastVisit: Date
    let visitCount: Int
  }

  /// The History files of every Chrome profile that exists, newest profile first.
  static func databaseURLs(fileManager: FileManager = .default) -> [URL] {
    let root = fileManager.homeDirectoryForCurrentUser.appendingPathComponent(profileRoot)
    guard let names = try? fileManager.contentsOfDirectory(atPath: root.path) else { return [] }
    return
      names
      .filter { $0 == "Default" || $0.hasPrefix("Profile ") }
      .sorted()
      .map { root.appendingPathComponent($0).appendingPathComponent("History") }
      .filter { fileManager.fileExists(atPath: $0.path) }
  }

  /// Chrome stores times as microseconds since 1601-01-01 UTC (the Windows epoch).
  static let epochOffset: TimeInterval = 11_644_473_600
  static func date(fromChromeTime micros: Int64) -> Date {
    Date(timeIntervalSince1970: Double(micros) / 1_000_000 - epochOffset)
  }
  static func chromeTime(from date: Date) -> Int64 {
    Int64((date.timeIntervalSince1970 + epochOffset) * 1_000_000)
  }

  static func load(fileManager: FileManager = .default, now: Date = Date()) -> [Entry] {
    var merged: [URL: Entry] = [:]
    for database in databaseURLs(fileManager: fileManager) {
      for entry in read(database: database, fileManager: fileManager, now: now) {
        if let existing = merged[entry.url], existing.lastVisit >= entry.lastVisit { continue }
        merged[entry.url] = entry
      }
    }
    return merged.values.sorted { $0.lastVisit > $1.lastVisit }
  }

  static func read(database: URL, fileManager: FileManager, now: Date) -> [Entry] {
    let scratch = fileManager.temporaryDirectory.appendingPathComponent(
      "jev-launcher-history-\(UUID().uuidString).sqlite")
    defer { try? fileManager.removeItem(at: scratch) }
    do {
      try fileManager.copyItem(at: database, to: scratch)
    } catch {
      return []
    }
    return query(copy: scratch, now: now)
  }

  static func query(copy: URL, now: Date) -> [Entry] {
    var handle: OpaquePointer?
    guard sqlite3_open_v2(copy.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
      let db = handle
    else { return [] }
    defer { sqlite3_close(db) }
    let sql = """
      SELECT url, title, last_visit_time, visit_count FROM urls
      WHERE last_visit_time > ? AND hidden = 0
      ORDER BY last_visit_time DESC LIMIT ?
      """
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
      return []
    }
    defer { sqlite3_finalize(statement) }
    let oldest = now.addingTimeInterval(-maxAgeDays * 86_400)
    sqlite3_bind_int64(statement, 1, chromeTime(from: oldest))
    sqlite3_bind_int(statement, 2, Int32(maxEntries))
    var entries: [Entry] = []
    while sqlite3_step(statement) == SQLITE_ROW {
      guard let rawURL = sqlite3_column_text(statement, 0),
        let url = URL(string: String(cString: rawURL)),
        let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https"
      else { continue }
      let title = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? ""
      entries.append(
        Entry(
          url: url, title: title,
          lastVisit: date(fromChromeTime: sqlite3_column_int64(statement, 2)),
          visitCount: Int(sqlite3_column_int(statement, 3))))
    }
    return entries
  }

  static func candidates(from entries: [Entry], now: Date) -> [Candidate] {
    entries.map { candidate(for: $0, now: now) }
  }

  static func candidate(for entry: Entry, now: Date) -> Candidate {
    let host = displayHost(entry.url)
    let title = entry.title.isEmpty ? host : entry.title
    let ageDays = max(0, now.timeIntervalSince(entry.lastVisit)) / 86_400
    var keywords = [
      "link", "links", "page", "site", "website", "url", "tab", "tabs", "visited", "history",
      "browser", "chrome", "web",
    ]
    keywords.append(contentsOf: hostWords(host))
    keywords.append(contentsOf: Fuzzy.tokens(entry.url.path).filter { $0.count >= 3 })
    if ageDays < 1 { keywords.append(contentsOf: ["recent", "latest", "today"]) }
    return Candidate(
      id: "url:\(entry.url.absoluteString)", title: title,
      subtitle: "\(host) · \(recency(ageDays))", kind: .openURL, keywords: keywords,
      payload: .url(entry.url), ageDays: ageDays)
  }

  static func displayHost(_ url: URL) -> String {
    var host = url.host ?? url.absoluteString
    if host.hasPrefix("www.") { host.removeFirst(4) }
    return host
  }

  static func hostWords(_ host: String) -> [String] {
    let parts = host.split(separator: ".").map(String.init)
    guard parts.count >= 2 else { return parts }
    return parts.dropLast() + [parts.suffix(2).joined(separator: ".")]
  }

  static func recency(_ ageDays: Double) -> String {
    LocalIndex.recency(ageDays).replacingOccurrences(of: "modified", with: "visited")
  }
}
