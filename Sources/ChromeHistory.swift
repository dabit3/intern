import Darwin
import Foundation
import SQLite3

/// Reads Chrome history without writing to the browser's database.
/// Only title, URL and last-visit time leave this type; nothing is logged.
enum ChromeHistory {
  private static let readLock = NSLock()
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

  private struct LocalState: Decodable {
    struct Profile: Decodable {
      struct Info: Decodable {}
      let infoCache: [String: Info]?
      enum CodingKeys: String, CodingKey { case infoCache = "info_cache" }
    }
    let profile: Profile?
  }

  /// Regular Chrome profiles, including named profiles registered in Local State.
  static func databaseURLs(fileManager: FileManager = .default) -> [URL] {
    guard !Task.isCancelled else { return [] }
    let root = fileManager.homeDirectoryForCurrentUser.appendingPathComponent(profileRoot)
    guard let names = try? fileManager.contentsOfDirectory(atPath: root.path) else { return [] }
    var profiles = Set(names.filter { $0 == "Default" || $0.hasPrefix("Profile ") })
    if !Task.isCancelled,
      let data = try? Data(contentsOf: root.appendingPathComponent("Local State")),
      let state = try? JSONDecoder().decode(LocalState.self, from: data),
      let registered = state.profile?.infoCache
    {
      profiles.formUnion(registered.keys)
    }
    return
      profiles
      .filter {
        !$0.isEmpty && !$0.hasPrefix(".") && !$0.contains("/")
          && $0 != "Guest Profile" && $0 != "System Profile"
      }
      .sorted()
      .map { root.appendingPathComponent($0).appendingPathComponent("History") }
      .filter {
        !Task.isCancelled && fileManager.fileExists(atPath: $0.path)
          && $0.resolvingSymlinksInPath().path.hasPrefix(root.resolvingSymlinksInPath().path + "/")
      }
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
      guard !Task.isCancelled else { break }
      for entry in read(database: database, fileManager: fileManager, now: now) {
        guard !Task.isCancelled else { break }
        if let existing = merged[entry.url], existing.lastVisit >= entry.lastVisit { continue }
        merged[entry.url] = entry
      }
      if merged.count > maxEntries {
        merged = Dictionary(
          uniqueKeysWithValues: merged.values.sorted(by: newestFirst).prefix(maxEntries).map {
            ($0.url, $0)
          })
      }
    }
    return merged.values.sorted(by: newestFirst)
  }

  private static func newestFirst(_ lhs: Entry, _ rhs: Entry) -> Bool {
    lhs.lastVisit == rhs.lastVisit
      ? lhs.url.absoluteString < rhs.url.absoluteString : lhs.lastVisit > rhs.lastVisit
  }

  static func read(database: URL, fileManager: FileManager, now: Date) -> [Entry] {
    readLock.lock()
    defer { readLock.unlock() }
    guard !Task.isCancelled, fileManager.fileExists(atPath: database.path) else { return [] }
    let result = queryResult(copy: database, now: now)
    guard result.locked, !Task.isCancelled else { return result.entries }
    let directory = fileManager.temporaryDirectory.appendingPathComponent(
      "InternHistory-\(UUID().uuidString)", isDirectory: true)
    do {
      try fileManager.createDirectory(
        at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    } catch {
      return []
    }
    defer { try? fileManager.removeItem(at: directory) }
    let sources = ["", "-wal", "-journal"].map { URL(fileURLWithPath: database.path + $0) }
    for attempt in 0..<2 {
      guard !Task.isCancelled else { return [] }
      do {
        let before = try sources.map(fileStamp)
        guard before[0] != nil,
          before.compactMap({ $0?.size }).reduce(0, +) <= 256 * 1_024 * 1_024
        else { return [] }
        let snapshot = directory.appendingPathComponent("\(attempt)", isDirectory: true)
        try fileManager.createDirectory(at: snapshot, withIntermediateDirectories: false)
        for (source, stamp) in zip(sources, before) where stamp != nil {
          guard !Task.isCancelled else { return [] }
          let destination = snapshot.appendingPathComponent(source.lastPathComponent)
          if clonefile(source.path, destination.path, 0) != 0 {
            try fileManager.copyItem(at: source, to: destination)
          }
        }
        guard try sources.map(fileStamp) == before else { continue }
        return queryResult(
          copy: snapshot.appendingPathComponent(database.lastPathComponent), now: now,
          recoverSnapshot: true
        ).entries
      } catch {
        return []
      }
    }
    return []
  }

  private struct FileStamp: Equatable {
    let inode: ino_t
    let size: off_t
    let modifiedSeconds: Int
    let modifiedNanoseconds: Int
    let changedSeconds: Int
    let changedNanoseconds: Int
  }

  private enum SnapshotError: Error {
    case inaccessible
  }

  private static func fileStamp(_ url: URL) throws -> FileStamp? {
    var info = stat()
    guard lstat(url.path, &info) == 0 else {
      if errno == ENOENT { return nil }
      throw SnapshotError.inaccessible
    }
    guard info.st_mode & S_IFMT == S_IFREG else { throw SnapshotError.inaccessible }
    return FileStamp(
      inode: info.st_ino, size: info.st_size,
      modifiedSeconds: info.st_mtimespec.tv_sec, modifiedNanoseconds: info.st_mtimespec.tv_nsec,
      changedSeconds: info.st_ctimespec.tv_sec, changedNanoseconds: info.st_ctimespec.tv_nsec)
  }

  private final class QueryBudget {
    let deadline = ProcessInfo.processInfo.systemUptime + 2
    var expired: Bool { Task.isCancelled || ProcessInfo.processInfo.systemUptime >= deadline }
  }

  static func query(copy: URL, now: Date) -> [Entry] {
    readLock.withLock { queryResult(copy: copy, now: now).entries }
  }

  private static func queryResult(copy: URL, now: Date, recoverSnapshot: Bool = false)
    -> (entries: [Entry], locked: Bool)
  {
    guard !Task.isCancelled else { return ([], false) }
    var handle: OpaquePointer?
    guard
      sqlite3_open_v2(
        copy.path, &handle, recoverSnapshot ? SQLITE_OPEN_READWRITE : SQLITE_OPEN_READONLY, nil)
        == SQLITE_OK,
      let db = handle
    else {
      if let handle { sqlite3_close(handle) }
      return ([], false)
    }
    defer { sqlite3_close(db) }
    sqlite3_busy_timeout(db, 50)
    let budget = QueryBudget()
    sqlite3_progress_handler(
      db, 1_000,
      { context in
        guard let context else { return 1 }
        return Unmanaged<QueryBudget>.fromOpaque(context).takeUnretainedValue().expired ? 1 : 0
      }, Unmanaged.passUnretained(budget).toOpaque())
    defer {
      sqlite3_progress_handler(db, 0, nil, nil)
      withExtendedLifetime(budget) {}
    }
    if recoverSnapshot {
      var check: OpaquePointer?
      let prepared = sqlite3_prepare_v2(db, "PRAGMA quick_check(1)", -1, &check, nil)
      defer { sqlite3_finalize(check) }
      guard prepared == SQLITE_OK, let check, sqlite3_step(check) == SQLITE_ROW,
        let result = sqlite3_column_text(check, 0), String(cString: result) == "ok"
      else { return ([], false) }
    }
    let sql = """
      SELECT url, title, last_visit_time, visit_count FROM urls
      WHERE last_visit_time > ? AND last_visit_time <= ? AND hidden = 0
        AND (url LIKE 'https://_%' OR url LIKE 'http://_%')
      ORDER BY last_visit_time DESC, url ASC LIMIT ?
      """
    var statement: OpaquePointer?
    let prepared = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
    guard prepared == SQLITE_OK, let statement else {
      sqlite3_finalize(statement)
      return ([], prepared == SQLITE_BUSY || prepared == SQLITE_LOCKED)
    }
    defer { sqlite3_finalize(statement) }
    let oldest = now.addingTimeInterval(-maxAgeDays * 86_400)
    sqlite3_bind_int64(statement, 1, chromeTime(from: oldest))
    sqlite3_bind_int64(statement, 2, chromeTime(from: now))
    sqlite3_bind_int(statement, 3, Int32(maxEntries))
    var entries: [Entry] = []
    var step = sqlite3_step(statement)
    while !budget.expired, step == SQLITE_ROW {
      defer { step = sqlite3_step(statement) }
      guard let rawURL = sqlite3_column_text(statement, 0),
        let url = URL(string: String(cString: rawURL)),
        let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
        let host = url.host, !host.isEmpty
      else { continue }
      let title = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? ""
      entries.append(
        Entry(
          url: url, title: title,
          lastVisit: date(fromChromeTime: sqlite3_column_int64(statement, 2)),
          visitCount: max(0, Int(sqlite3_column_int64(statement, 3)))))
    }
    guard step == SQLITE_DONE, !budget.expired else {
      return ([], step == SQLITE_BUSY || step == SQLITE_LOCKED)
    }
    return (entries, false)
  }

  static func candidates(from entries: [Entry], now: Date) -> [Candidate] {
    var candidates: [Candidate] = []
    for entry in entries.prefix(maxEntries) {
      guard !Task.isCancelled else { break }
      candidates.append(candidate(for: entry, now: now))
    }
    return candidates
  }

  static func candidate(for entry: Entry, now: Date) -> Candidate {
    let host = displayHost(entry.url)
    let trimmedTitle = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
    let title = trimmedTitle.isEmpty ? host : trimmedTitle
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
      payload: .url(entry.url), ageDays: ageDays, visitedAt: entry.lastVisit)
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
