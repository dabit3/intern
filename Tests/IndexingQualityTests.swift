import Foundation
import SQLite3
import XCTest

@testable import Intern

private final class IndexFixtureFileManager: FileManager, @unchecked Sendable {
  let home: URL

  init(home: URL) {
    self.home = home
    super.init()
  }

  override var homeDirectoryForCurrentUser: URL { home }

  override func fileExists(atPath path: String) -> Bool {
    path.hasPrefix(home.path + "/") && super.fileExists(atPath: path)
  }

  override func contentsOfDirectory(atPath path: String) throws -> [String] {
    guard path.hasPrefix(home.path + "/") else { return [] }
    return try super.contentsOfDirectory(atPath: path)
  }

  override func contentsOfDirectory(
    at url: URL, includingPropertiesForKeys keys: [URLResourceKey]?,
    options mask: FileManager.DirectoryEnumerationOptions = []
  ) throws -> [URL] {
    guard url.path.hasPrefix(home.path + "/") else { return [] }
    return try super.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: mask)
  }
}

final class IndexingQualityTests: XCTestCase {
  private var home: URL!
  private var manager: IndexFixtureFileManager!
  private let now = Date(timeIntervalSince1970: 1_789_876_800)

  override func setUpWithError() throws {
    home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
      "IndexingQualityFixtures-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    manager = IndexFixtureFileManager(home: home)
  }

  override func tearDownWithError() throws {
    try FileManager.default.removeItem(at: home)
  }

  @discardableResult
  private func file(_ path: String) throws -> URL {
    let url = home.appendingPathComponent(path)
    try manager.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("fixture".utf8).write(to: url)
    return url
  }

  private func database(_ path: String, wal: Bool = false) throws -> OpaquePointer {
    let url = home.appendingPathComponent(path)
    try manager.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    var handle: OpaquePointer?
    XCTAssertEqual(sqlite3_open(url.path, &handle), SQLITE_OK)
    let db = try XCTUnwrap(handle)
    if wal {
      try sql("PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0;", db: db)
    }
    try sql(
      """
      CREATE TABLE urls (url TEXT, title TEXT, last_visit_time INTEGER,
        visit_count INTEGER, hidden INTEGER DEFAULT 0);
      """, db: db)
    return db
  }

  private func sql(_ statement: String, db: OpaquePointer) throws {
    guard sqlite3_exec(db, statement, nil, nil, nil) == SQLITE_OK else {
      throw NSError(
        domain: "IndexFixture", code: Int(sqlite3_errcode(db)),
        userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))])
    }
  }

  func testNestedDownloadsAreRetrievedWithoutPrivateOrPackageContents() throws {
    let wanted = try file("Downloads/Projects/Quarter/Reports/roadmap.pdf")
    for path in [
      "Downloads/Library/private.txt", "Downloads/node_modules/package/readme.txt",
      "Downloads/.private/secret.txt", "Downloads/Example.app/Contents/info.txt",
      "Downloads/Archive.rtfd/contents.txt",
    ] {
      try file(path)
    }
    let candidates = LocalIndex.scanFiles(fileManager: manager, now: now)
    XCTAssertTrue(candidates.contains { $0.fileURL == wanted })
    XCTAssertFalse(candidates.contains { $0.title == "private.txt" || $0.title == "readme.txt" })
    XCTAssertFalse(candidates.contains { $0.title == "secret.txt" || $0.title == "info.txt" })
    XCTAssertFalse(candidates.contains { $0.title == "contents.txt" })
    XCTAssertFalse(candidates.contains { $0.title == "Example.app" })
  }

  func testOneCrowdedFolderCannotStarveTheRestOfTheScan() throws {
    for index in 0..<(LocalIndex.maxEntriesPerFolder + 100) {
      try file("Downloads/exports/export-\(index).csv")
    }
    for index in 0..<50 {
      try file("Downloads/logs/run-\(index).log")
    }
    let wanted = try file("Downloads/Projects/roadmap.pdf")
    let candidates = LocalIndex.scanFiles(fileManager: manager, now: now)
    XCTAssertTrue(candidates.contains { $0.fileURL == wanted })
    XCTAssertLessThanOrEqual(
      candidates.filter { $0.title.hasPrefix("export-") }.count, LocalIndex.maxEntriesPerFolder)
    XCTAssertFalse(candidates.contains { $0.title.hasSuffix(".log") })
  }

  func testEnclosingFolderNamesAreSearchable() throws {
    let url = try file("Downloads/Projects/Quarter-Review/roadmap.pdf")
    let candidate = LocalIndex.fileCandidate(url: url, folder: "Downloads", now: now)
    XCTAssertTrue(candidate.keywords.contains("projects"))
    XCTAssertTrue(candidate.keywords.contains("quarter"))
    XCTAssertTrue(candidate.keywords.contains("review"))
    XCTAssertEqual(
      Ranker.rank(Ranker.prefilter(query: "quarter roadmap", index: [candidate]), judgment: nil)
        .first?.id, candidate.id)
  }

  func testScannerReusesFolderScansAndRefreshesAfterTheInterval() async throws {
    try file("Downloads/first.pdf")
    var clock = now
    let scanner = LocalIndexScanner(fileManager: manager, clock: { clock })
    let first = await scanner.build(includeHistory: false)
    XCTAssertTrue(first.candidates.contains { $0.title == "first.pdf" })

    try file("Downloads/second.pdf")
    clock = now.addingTimeInterval(LocalIndexScanner.scanInterval / 2)
    let cached = await scanner.build(includeHistory: false)
    XCTAssertFalse(cached.candidates.contains { $0.title == "second.pdf" })

    clock = now.addingTimeInterval(LocalIndexScanner.scanInterval + 1)
    let refreshed = await scanner.build(includeHistory: false)
    XCTAssertTrue(refreshed.candidates.contains { $0.title == "second.pdf" })
  }

  func testHistoryStampsChangeOnlyWhenTheDatabaseFilesChange() throws {
    let url = home.appendingPathComponent(ChromeHistory.profileRoot)
      .appendingPathComponent("Default/History")
    try manager.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("one".utf8).write(to: url)
    let before = ChromeHistory.stamps(for: url)
    XCTAssertEqual(before, ChromeHistory.stamps(for: url))
    XCTAssertNotNil(before[0])
    XCTAssertNil(before[1])
    try Data("one two".utf8).write(to: url)
    XCTAssertNotEqual(before, ChromeHistory.stamps(for: url))
  }

  func testHomeFoldersRemainDirectlySearchable() throws {
    for name in LocalIndex.fileDirectories {
      try manager.createDirectory(
        at: home.appendingPathComponent(name), withIntermediateDirectories: true)
    }
    _ = try file("Downloads/report.pdf")
    let candidates = LocalIndex.scanFiles(fileManager: manager, now: now)
    for name in LocalIndex.fileDirectories {
      let results = Ranker.rank(
        Ranker.prefilter(query: "open \(name)", index: candidates), judgment: nil)
      XCTAssertEqual(results.first?.candidate.fileURL, home.appendingPathComponent(name))
    }
  }

  func testSymlinkDoesNotExposeLibraryContents() throws {
    let secret = try file("Library/Private/secret.pdf")
    try manager.createDirectory(
      at: home.appendingPathComponent("Downloads"), withIntermediateDirectories: true)
    try manager.createSymbolicLink(
      at: home.appendingPathComponent("Downloads/linked"),
      withDestinationURL: secret.deletingLastPathComponent())
    XCTAssertFalse(
      LocalIndex.scanFiles(fileManager: manager, now: now).contains { $0.title == "secret.pdf" })
  }

  func testSymlinkedRootDoesNotExposeLibraryContents() throws {
    let secret = try file("Library/Private/secret.pdf")
    try manager.createSymbolicLink(
      at: home.appendingPathComponent("Downloads"),
      withDestinationURL: secret.deletingLastPathComponent())
    XCTAssertTrue(LocalIndex.scanFiles(fileManager: manager, now: now).isEmpty)
  }

  func testCommonSystemAppLocationsIncludeFinderAndSafari() {
    XCTAssertTrue(LocalIndex.systemApps.contains("/System/Library/CoreServices/Finder.app"))
    XCTAssertTrue(
      LocalIndex.appDirectories.contains(
        "/System/Volumes/Preboot/Cryptexes/App/System/Applications"))
  }

  func testAppCopiesDeduplicateByBundleIdentityWithoutHidingDifferentApps() throws {
    for name in ["First", "Second"] {
      let info = try file("Applications/\(name).app/Contents/Info.plist")
      try Data(
        """
        <plist version="1.0"><dict>
        <key>CFBundleIdentifier</key><string>test.shared-app</string>
        </dict></plist>
        """.utf8
      ).write(to: info)
    }
    XCTAssertEqual(LocalIndex.scanApps(fileManager: manager).count, 1)
  }

  func testShortcutsHandleFailureTimeoutAndOutputLimits() {
    let shell = URL(fileURLWithPath: "/bin/sh")
    let success = LocalIndex.scanShortcuts(
      executableURL: shell, arguments: ["-c", "printf 'First\\nFirst\\nSecond\\n'"])
    XCTAssertEqual(success.map(\.title), ["First", "Second"])
    XCTAssertTrue(
      LocalIndex.scanShortcuts(
        executableURL: shell, arguments: ["-c", "printf 'Partial\\n'; exit 1"]
      ).isEmpty)
    let started = ProcessInfo.processInfo.systemUptime
    XCTAssertTrue(
      LocalIndex.scanShortcuts(
        executableURL: shell, arguments: ["-c", "trap '' TERM; while :; do :; done"],
        timeout: 0.1
      ).isEmpty)
    XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 2)
    XCTAssertTrue(
      LocalIndex.scanShortcuts(
        executableURL: URL(fileURLWithPath: "/usr/bin/yes"), arguments: [],
        timeout: 2
      ).isEmpty)
  }

  func testShortcutsStopWhenTaskIsCancelled() async throws {
    let task = Task.detached {
      LocalIndex.scanShortcuts(
        executableURL: URL(fileURLWithPath: "/bin/sh"),
        arguments: ["-c", "trap '' TERM; while :; do :; done"], timeout: 10)
    }
    try await Task.sleep(for: .milliseconds(100))
    let started = ProcessInfo.processInfo.systemUptime
    task.cancel()
    let candidates = await task.value
    XCTAssertTrue(candidates.isEmpty)
    XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 2)
  }

  func testCancelledHistoryNeverDiscoversProfiles() async {
    let manager = manager!
    let now = now
    let task = Task.detached {
      withUnsafeCurrentTask { $0?.cancel() }
      return ChromeHistory.load(fileManager: manager, now: now)
    }
    let entries = await task.value
    XCTAssertTrue(entries.isEmpty)
  }

  func testNestedAppInstallationsAndIdenticalNamesAreNotLost() throws {
    for path in [
      "Applications/Utilities/Tool.app/Contents/Info.plist",
      "Applications/Vendor One/Editor.app/Contents/Info.plist",
      "Applications/Vendor Two/Editor.app/Contents/Info.plist",
    ] {
      try file(path)
    }
    let apps = LocalIndex.scanApps(fileManager: manager)
    XCTAssertEqual(apps.filter { $0.title == "Tool" }.count, 1)
    XCTAssertEqual(apps.filter { $0.title == "Editor" }.count, 2)
    XCTAssertTrue(apps.allSatisfy { $0.kind == .openApp })
  }

  func testAppRolesComeFromBundleMetadata() throws {
    let browser = try file("Applications/Aurora.app/Contents/Info.plist")
    let editor = try file("Applications/Studio.app/Contents/Info.plist")
    try Data(
      """
      <?xml version="1.0" encoding="UTF-8"?>
      <plist version="1.0"><dict>
      <key>CFBundleIdentifier</key><string>test.browser</string>
      <key>CFBundleURLTypes</key><array><dict>
      <key>CFBundleURLSchemes</key><array><string>http</string><string>https</string></array>
      </dict></array></dict></plist>
      """.utf8
    ).write(to: browser)
    try Data(
      """
      <?xml version="1.0" encoding="UTF-8"?>
      <plist version="1.0"><dict>
      <key>CFBundleIdentifier</key><string>test.editor</string>
      <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
      <key>CFBundleDocumentTypes</key><array><dict>
      <key>CFBundleTypeRole</key><string>Editor</string>
      <key>LSItemContentTypes</key><array><string>public.source-code</string></array>
      </dict></array></dict></plist>
      """.utf8
    ).write(to: editor)
    let apps = LocalIndex.scanApps(fileManager: manager)
    let browserCandidate = try XCTUnwrap(apps.first { $0.title == "Aurora" })
    let editorCandidate = try XCTUnwrap(apps.first { $0.title == "Studio" })
    XCTAssertTrue(browserCandidate.keywords.contains("browser"))
    XCTAssertEqual(
      Ranker.rank(Ranker.prefilter(query: "browser", index: apps), judgment: nil).first?.id,
      browserCandidate.id)
    XCTAssertTrue(editorCandidate.keywords.contains("code"))
    XCTAssertTrue(editorCandidate.keywords.contains("editor"))
    XCTAssertFalse(browserCandidate.keywords.contains("editor"))
  }

  func testMissingMetadataStaysUnknownAndDownloadsKeywordsSurviveSpotlight() throws {
    let missing = LocalIndex.fileCandidate(
      url: home.appendingPathComponent("gone.pdf"), folder: "Documents", now: now)
    XCTAssertNil(missing.modifiedAt)
    XCTAssertNil(missing.ageDays)
    XCTAssertFalse(missing.subtitle.contains("over a year"))
    let url = try file("Downloads/Projects/report.pdf")
    let candidate = LocalIndex.fileCandidate(url: url, folder: "Projects", now: now)
    XCTAssertTrue(candidate.keywords.contains("downloaded"))
    XCTAssertTrue(candidate.keywords.contains("downloads"))
  }

  func testLocalLimitRetainsRecentlyDownloadedAndOpenedOldFiles() {
    let old = now.addingTimeInterval(-365 * 86_400)
    var candidates = (0..<LocalIndex.maxFilesPerDirectory).map { index in
      Candidate(
        id: "file:\(index)", title: "\(index).pdf", subtitle: "", kind: .openFile,
        payload: .file(home.appendingPathComponent("\(index).pdf")),
        modifiedAt: now.addingTimeInterval(-86_400))
    }
    for (id, added, opened) in [
      ("downloaded", Optional(now), nil as Date?),
      ("opened", nil as Date?, Optional(now)),
    ] {
      candidates.append(
        Candidate(
          id: id, title: id, subtitle: "", kind: .openFile,
          payload: .file(home.appendingPathComponent(id)),
          modifiedAt: old, lastOpenedAt: opened, addedAt: added))
    }
    let retained = LocalIndex.recentFiles(candidates)
    XCTAssertEqual(retained.count, LocalIndex.maxFilesPerDirectory)
    XCTAssertTrue(retained.contains { $0.id == "downloaded" })
    XCTAssertTrue(retained.contains { $0.id == "opened" })
  }

  func testCommonDocumentAndMediaTypesHaveAccurateSearchWords() {
    XCTAssertTrue(LocalIndex.fileTypeWords("docx").contains("document"))
    XCTAssertTrue(LocalIndex.fileTypeWords("pptx").contains("presentation"))
    XCTAssertTrue(LocalIndex.fileTypeWords("key").contains("deck"))
    XCTAssertTrue(LocalIndex.fileTypeWords("mp3").contains("audio"))
    XCTAssertTrue(LocalIndex.fileTypeWords("tiff").contains("image"))
    XCTAssertFalse(LocalIndex.fileTypeWords("zip").contains("installer"))
    XCTAssertFalse(LocalIndex.fileTypeWords("jpg").contains("screenshot"))
  }

  @MainActor
  func testSpotlightChecksNormalizedAndCaseInsensitivePrivatePaths() {
    for path in [
      "Documents/../Library/secret.pdf", "Documents/../../outside.pdf",
      "Downloads/Library/private.txt", "Projects/NODE_MODULES/a.txt",
      "Tools/Hidden.APP/Contents/a.txt",
    ] {
      XCTAssertFalse(
        SpotlightSearch.allowed(path: home.appendingPathComponent(path).path, home: home.path))
    }
  }

  @MainActor
  func testSpotlightFilenameWordsMustAllMatch() {
    let predicate = SpotlightSearch.predicate(for: "quarterly roadmap pdf")
    let names = namePredicate(in: predicate)
    XCTAssertTrue(names.evaluate(with: ["kMDItemFSName": "quarterly roadmap.pdf"]))
    XCTAssertFalse(names.evaluate(with: ["kMDItemFSName": "quarterly invoice.pdf"]))
    XCTAssertFalse(names.evaluate(with: ["kMDItemFSName": "old roadmap.pdf"]))
  }

  private func namePredicate(in predicate: NSPredicate) -> NSPredicate {
    if let compound = predicate as? NSCompoundPredicate {
      let children = compound.subpredicates.compactMap { $0 as? NSPredicate }
        .filter { $0.predicateFormat.contains("kMDItemFSName") }
      return NSCompoundPredicate(
        type: compound.compoundPredicateType, subpredicates: children.map { namePredicate(in: $0) })
    }
    return predicate
  }

  @MainActor
  func testSpotlightAppliesTimeWindowBeforeResultLimit() {
    for (text, key) in [
      ("files modified yesterday", "kMDItemFSContentChangeDate"),
      ("files opened yesterday", "kMDItemLastUsedDate"),
      ("files downloaded yesterday", "kMDItemDateAdded"),
    ] {
      let predicate = SpotlightSearch.predicate(for: text, now: now)
      let query = NSMetadataQuery()
      query.predicate = predicate
      XCTAssertNotNil(query.predicate)
      let format = predicate.predicateFormat
      XCTAssertTrue(format.contains("\(key) >="), format)
      XCTAssertTrue(format.contains("\(key) <="), format)
    }
  }

  @MainActor
  func testSpotlightRejectsSymlinksIntoPrivateDirectories() throws {
    let secret = try file("Library/Private/secret.pdf")
    let link = home.appendingPathComponent("report.pdf")
    try manager.createSymbolicLink(at: link, withDestinationURL: secret)
    XCTAssertFalse(SpotlightSearch.allowed(path: link.path, home: home.path))
  }

  func testLockedHistoryReturnsPromptlyWithoutChangingDatabase() throws {
    let db = try database("History")
    defer { sqlite3_close(db) }
    try sql("BEGIN EXCLUSIVE;", db: db)
    defer { try? sql("ROLLBACK;", db: db) }
    let started = ProcessInfo.processInfo.systemUptime
    XCTAssertTrue(
      ChromeHistory.read(
        database: home.appendingPathComponent("History"), fileManager: manager, now: now
      )
      .isEmpty)
    XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 1)
  }

  func testExclusiveBrowserConnectionsStillExposeCommittedHistory() throws {
    for wal in [false, true] {
      let name = "Exclusive-\(wal)"
      let db = try database(name, wal: wal)
      defer { sqlite3_close(db) }
      try sql("PRAGMA locking_mode=EXCLUSIVE;", db: db)
      let timestamp = ChromeHistory.chromeTime(from: now.addingTimeInterval(-60))
      try sql(
        "INSERT INTO urls VALUES ('https://example.com/committed', 'Committed', \(timestamp), 1, 0);",
        db: db)
      let source = home.appendingPathComponent(name)
      let before = try Data(contentsOf: source)
      let walURL = home.appendingPathComponent(name + "-wal")
      let walBefore = try? Data(contentsOf: walURL)
      XCTAssertTrue(ChromeHistory.query(copy: source, now: now).isEmpty)
      let entries = ChromeHistory.read(database: source, fileManager: manager, now: now)
      XCTAssertEqual(entries.map(\.title), ["Committed"], "wal=\(wal)")
      XCTAssertEqual(try Data(contentsOf: source), before)
      XCTAssertEqual(try? Data(contentsOf: walURL), walBefore)
    }
  }

  func testLockedSnapshotRecoversWithoutExposingUncommittedVisits() throws {
    let db = try database("History")
    defer { sqlite3_close(db) }
    let timestamp = ChromeHistory.chromeTime(from: now.addingTimeInterval(-60))
    try sql(
      "INSERT INTO urls VALUES ('https://example.com/committed', 'Committed', \(timestamp), 1, 0);",
      db: db)
    try sql("PRAGMA cache_size=1; BEGIN EXCLUSIVE;", db: db)
    defer { try? sql("ROLLBACK;", db: db) }
    try sql(
      """
      INSERT INTO urls VALUES ('https://example.com/uncommitted',
        '\(String(repeating: "uncommitted", count: 10_000))', \(timestamp), 1, 0);
      """, db: db)
    let source = home.appendingPathComponent("History")
    let before = try Data(contentsOf: source)
    let journal = home.appendingPathComponent("History-journal")
    let journalBefore = try Data(contentsOf: journal)
    let entries = ChromeHistory.read(database: source, fileManager: manager, now: now)
    XCTAssertEqual(entries.map(\.title), ["Committed"])
    XCTAssertEqual(try Data(contentsOf: source), before)
    XCTAssertEqual(try Data(contentsOf: journal), journalBefore)
  }

  func testHistorySnapshotIncludesCommittedWALVisitsWithoutChangingDatabase() throws {
    let db = try database("History", wal: true)
    defer { sqlite3_close(db) }
    try sql("PRAGMA wal_checkpoint(TRUNCATE);", db: db)
    let timestamp = ChromeHistory.chromeTime(from: now.addingTimeInterval(-60))
    try sql(
      "INSERT INTO urls VALUES ('https://example.com/recent', 'Recent', \(timestamp), 1, 0);",
      db: db)
    let source = home.appendingPathComponent("History")
    let before = try Data(contentsOf: source)
    let walBefore = try Data(contentsOf: home.appendingPathComponent("History-wal"))
    let entries = ChromeHistory.read(database: source, fileManager: manager, now: now)
    XCTAssertEqual(entries.map(\.title), ["Recent"])
    XCTAssertEqual(try Data(contentsOf: source), before)
    XCTAssertEqual(try Data(contentsOf: home.appendingPathComponent("History-wal")), walBefore)
  }

  func testHistoryRejectsInvalidURLsAndFutureVisits() throws {
    let db = try database("History")
    defer { sqlite3_close(db) }
    let recent = ChromeHistory.chromeTime(from: now.addingTimeInterval(-60))
    let future = ChromeHistory.chromeTime(from: now.addingTimeInterval(86_400))
    try sql(
      """
      INSERT INTO urls VALUES ('https://', 'Bad', \(recent), 1, 0);
      INSERT INTO urls VALUES ('https:relative', 'Bad', \(recent), 1, 0);
      INSERT INTO urls VALUES ('https://future.example.com', 'Future', \(future), 1, 0);
      INSERT INTO urls VALUES ('https://valid.example.com', '   ', \(recent), 1, 0);
      """, db: db)
    let entries = ChromeHistory.read(
      database: home.appendingPathComponent("History"), fileManager: manager, now: now)
    XCTAssertEqual(entries.map(\.url.absoluteString), ["https://valid.example.com"])
    XCTAssertEqual(
      ChromeHistory.candidates(from: entries, now: now).first?.title, "valid.example.com")
  }

  func testChromeProfilesMergeNewestDuplicatesAndRespectGlobalLimit() throws {
    let root = ChromeHistory.profileRoot
    for profile in ["Default", "Profile 1"] {
      let db = try database("\(root)/\(profile)/History")
      defer { sqlite3_close(db) }
      let time = ChromeHistory.chromeTime(
        from: now.addingTimeInterval(profile == "Default" ? -120 : -60))
      try sql(
        """
        WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<2000)
        INSERT INTO urls SELECT 'https://example.com/\(profile)/'||x, 'Page', \(time), 1, 0 FROM n;
        INSERT INTO urls VALUES ('https://shared.example.com', '\(profile)', \(time), 1, 0);
        """, db: db)
    }
    let entries = ChromeHistory.load(fileManager: manager, now: now)
    XCTAssertEqual(entries.count, ChromeHistory.maxEntries)
    XCTAssertEqual(entries.first { $0.url.host == "shared.example.com" }?.title, "Profile 1")
  }

  func testNamedChromeProfilesFromLocalStateAreIncludedButGuestIsNot() throws {
    let root = ChromeHistory.profileRoot
    for profile in ["Work", "Guest Profile", "System Profile"] {
      let db = try database("\(root)/\(profile)/History")
      sqlite3_close(db)
    }
    let state = """
      {"profile":{"info_cache":{"Work":{},"Guest Profile":{},"System Profile":{},"../escaped":{}}}}
      """
    try Data(state.utf8).write(to: home.appendingPathComponent("\(root)/Local State"))
    XCTAssertEqual(
      ChromeHistory.databaseURLs(fileManager: manager).map {
        $0.deletingLastPathComponent().lastPathComponent
      }, ["Work"])
  }
}
