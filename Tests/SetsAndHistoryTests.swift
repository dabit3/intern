import SQLite3
import XCTest

@testable import Launcher

enum HistoryFixtures {
  static let now = Date(timeIntervalSince1970: 1_790_000_000)

  static func link(_ id: String, _ title: String, _ url: String, hoursAgo: Double) -> Candidate {
    ChromeHistory.candidate(
      for: ChromeHistory.Entry(
        url: URL(string: url)!, title: title,
        lastVisit: now.addingTimeInterval(-hoursAgo * 3_600), visitCount: 1), now: now)
  }

  static let ambassador1 = link(
    "a1", "Devin Ambassador Program – Apply", "https://cognition.ai/ambassadors", hoursAgo: 2)
  static let ambassador2 = link(
    "a2", "Devin Ambassadors: Community Guide", "https://docs.devin.ai/ambassadors/guide",
    hoursAgo: 5)
  static let ambassador3 = link(
    "a3", "Ambassador kickoff call notes", "https://notion.so/devin-ambassador-kickoff",
    hoursAgo: 20)
  static let oldAmbassador = link(
    "a4", "Devin Ambassador Program – Apply", "https://cognition.ai/ambassadors?ref=old",
    hoursAgo: 72)
  static let youtube = link(
    "y1", "Lo-fi beats to code to", "https://youtube.com/watch?v=1", hoursAgo: 1)
  static let github = link(
    "g1", "dabit3/jev-experiments", "https://github.com/dabit3/jev-experiments", hoursAgo: 3)

  static let index =
    Fixtures.index + [ambassador1, ambassador2, ambassador3, oldAmbassador, youtube, github]
}

final class TimeWindowTests: XCTestCase {
  let now = HistoryFixtures.now
  var calendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
  }

  func testPast24Hours() {
    let window = TimeWindow.parse(
      "open devin ambassador links i've visited in the past 24 hours", now: now,
      calendar: calendar)
    XCTAssertNotNil(window)
    XCTAssertEqual(window?.since, now.addingTimeInterval(-86_400))
    XCTAssertNil(window?.until)
    XCTAssertEqual(window?.phrase, "in the past 24 hours")
    XCTAssertEqual(window?.remainder, "open devin ambassador links i've visited")
  }

  func testRelativeUnitsAndNumberWords() {
    XCTAssertEqual(
      TimeWindow.parse("files from the last hour", now: now, calendar: calendar)?.since,
      now.addingTimeInterval(-3_600))
    XCTAssertEqual(
      TimeWindow.parse("last few days", now: now, calendar: calendar)?.since,
      now.addingTimeInterval(-3 * 86_400))
    XCTAssertEqual(
      TimeWindow.parse("past couple of weeks", now: now, calendar: calendar)?.since,
      now.addingTimeInterval(-14 * 86_400))
    XCTAssertEqual(
      TimeWindow.parse("last 30 min", now: now, calendar: calendar)?.since,
      now.addingTimeInterval(-30 * 60))
  }

  func testNamedWindows() {
    let startOfToday = calendar.startOfDay(for: now)
    let today = TimeWindow.parse("pages I visited today", now: now, calendar: calendar)
    XCTAssertEqual(today?.since, startOfToday)
    XCTAssertNil(today?.until)
    XCTAssertEqual(today?.remainder, "pages I visited")

    let yesterday = TimeWindow.parse("the doc I edited yesterday", now: now, calendar: calendar)
    XCTAssertEqual(yesterday?.since, startOfToday.addingTimeInterval(-86_400))
    XCTAssertEqual(yesterday?.until, startOfToday)

    let week = TimeWindow.parse("downloads this week", now: now, calendar: calendar)
    XCTAssertEqual(week?.since, calendar.dateInterval(of: .weekOfYear, for: now)?.start)
  }

  func testNoWindowForPlainQueries() {
    XCTAssertNil(TimeWindow.parse("the pdf I just downloaded", now: now, calendar: calendar))
    XCTAssertNil(TimeWindow.parse("last.fm", now: now, calendar: calendar))
    XCTAssertNil(TimeWindow.parse("dark", now: now, calendar: calendar))
  }

  func testContainsRespectsBothBounds() {
    let yesterday = TimeWindow.parse("yesterday", now: now, calendar: calendar)!
    let hoursIntoToday = now.timeIntervalSince(calendar.startOfDay(for: now)) / 3_600
    XCTAssertTrue(yesterday.contains(ageDays: (hoursIntoToday + 3) / 24, now: now))
    XCTAssertFalse(yesterday.contains(ageDays: 0.01, now: now))
    XCTAssertFalse(yesterday.contains(ageDays: 3, now: now))
  }
}

final class ChromeHistoryTests: XCTestCase {
  func testChromeTimeRoundTrip() {
    // 13323235200000000 µs after 1601-01-01 is 2023-03-14 00:00:00 UTC.
    let date = ChromeHistory.date(fromChromeTime: 13_323_235_200_000_000)
    XCTAssertEqual(date.timeIntervalSince1970, 1_678_761_600, accuracy: 0.001)
    XCTAssertEqual(ChromeHistory.chromeTime(from: date), 13_323_235_200_000_000)
  }

  func testCandidateShapesTitleHostAndKeywords() {
    let candidate = HistoryFixtures.ambassador2
    XCTAssertEqual(candidate.kind, .openURL)
    XCTAssertEqual(candidate.title, "Devin Ambassadors: Community Guide")
    XCTAssertEqual(candidate.subtitle, "docs.devin.ai · visited 5 h ago")
    XCTAssertEqual(candidate.ageDays ?? 0, 5.0 / 24, accuracy: 1e-6)
    XCTAssertTrue(candidate.keywords.contains("links"))
    XCTAssertTrue(candidate.keywords.contains("devin.ai"))
    XCTAssertTrue(candidate.keywords.contains("ambassadors"))
    XCTAssertTrue(candidate.keywords.contains("visited"))
    if case .url(let url) = candidate.payload {
      XCTAssertEqual(url.absoluteString, "https://docs.devin.ai/ambassadors/guide")
    } else {
      XCTFail("expected a url payload")
    }
  }

  func testUntitledEntryFallsBackToHost() {
    let candidate = HistoryFixtures.link("u", "", "https://www.example.com/x", hoursAgo: 1)
    XCTAssertEqual(candidate.title, "example.com")
  }

  func testReadsCopiedSQLiteDatabase() throws {
    let now = HistoryFixtures.now
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(
      "history-test-\(UUID().uuidString).sqlite")
    defer { try? FileManager.default.removeItem(at: file) }
    var db: OpaquePointer?
    XCTAssertEqual(sqlite3_open(file.path, &db), SQLITE_OK)
    let recent = ChromeHistory.chromeTime(from: now.addingTimeInterval(-3_600))
    let ancient = ChromeHistory.chromeTime(from: now.addingTimeInterval(-200 * 86_400))
    let sql = """
      CREATE TABLE urls(id INTEGER PRIMARY KEY, url TEXT, title TEXT, visit_count INTEGER,
        typed_count INTEGER, last_visit_time INTEGER, hidden INTEGER DEFAULT 0);
      INSERT INTO urls VALUES(1, 'https://cognition.ai/ambassadors', 'Ambassadors', 3, 0, \(recent), 0);
      INSERT INTO urls VALUES(2, 'https://old.example.com', 'Old', 1, 0, \(ancient), 0);
      INSERT INTO urls VALUES(3, 'chrome://settings', 'Settings', 1, 0, \(recent), 0);
      INSERT INTO urls VALUES(4, 'https://hidden.example.com', 'Hidden', 1, 0, \(recent), 1);
      """
    XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
    sqlite3_close(db)

    let entries = ChromeHistory.read(database: file, fileManager: .default, now: now)
    XCTAssertEqual(entries.map(\.url.absoluteString), ["https://cognition.ai/ambassadors"])
    XCTAssertEqual(entries.first?.title, "Ambassadors")
    XCTAssertEqual(entries.first?.visitCount, 3)
    XCTAssertEqual(
      entries.first?.lastVisit.timeIntervalSince1970 ?? 0,
      now.addingTimeInterval(-3_600).timeIntervalSince1970, accuracy: 0.001)
  }

  func testMissingDatabaseYieldsNothing() {
    let missing = URL(fileURLWithPath: "/nonexistent/History")
    XCTAssertTrue(ChromeHistory.read(database: missing, fileManager: .default, now: Date()).isEmpty)
  }
}

final class SetRankingTests: XCTestCase {
  let now = HistoryFixtures.now
  let query = "open devin ambassador links i've visited in the past 24 hours"

  func testWindowDropsOldVisitsAndKeepsTimelessItems() {
    let prefiltered = Ranker.prefilter(query: query, index: HistoryFixtures.index, now: now)
    let ids = prefiltered.candidates.map(\.id)
    XCTAssertNotNil(prefiltered.window)
    XCTAssertTrue(ids.contains(HistoryFixtures.ambassador1.id))
    XCTAssertTrue(ids.contains(HistoryFixtures.ambassador2.id))
    XCTAssertTrue(ids.contains(HistoryFixtures.ambassador3.id))
    XCTAssertFalse(ids.contains(HistoryFixtures.oldAmbassador.id), "72 h old is outside 24 h")
    XCTAssertFalse(ids.contains(Fixtures.invoice.id), "a month-old file is outside 24 h")
    XCTAssertEqual(ids.last, Ranker.webSearchID)
  }

  func testWindowedPrefilterAllowsMoreRows() {
    let many = (0..<60).map { i in
      HistoryFixtures.link("l\(i)", "Devin note \(i)", "https://devin.ai/n/\(i)", hoursAgo: 1)
    }
    let result = Ranker.prefilter(query: "devin pages from today", index: many, now: now)
    XCTAssertEqual(result.candidates.count, Ranker.windowedPrefilterLimit + 1)
    XCTAssertLessThanOrEqual(result.candidates.count, JevQuestions.maxCandidates)
  }

  func testWindowOnlyQueryListsEverythingRecent() {
    let result = Ranker.prefilter(
      query: "everything from the past 3 hours", index: HistoryFixtures.index, now: now)
    let ids = result.candidates.map(\.id)
    XCTAssertEqual(
      Array(ids.prefix(2)), [Fixtures.roadmap.id, HistoryFixtures.youtube.id], "newest first")
    XCTAssertTrue(ids.contains(HistoryFixtures.ambassador1.id))
    XCTAssertFalse(ids.contains(HistoryFixtures.ambassador2.id))
    XCTAssertFalse(ids.contains(Fixtures.darkMode.id), "timeless items need a description")
  }

  private func judgment(set: Double, matches: [String: Double], target: [String: Double] = [:])
    -> JevJudgment
  {
    JevJudgment(
      targetProbabilities: target, noneProbability: 0, targetConfidence: 0.5, action: .openURL,
      actionProbabilities: [.openURL: 0.9], actionConfidence: 0.8, ready: 0.2,
      setProbability: set, matchProbabilities: matches)
  }

  func testAllIntentPutsGroupRowFirstWithMembersChecked() {
    let prefiltered = Ranker.prefilter(query: query, index: HistoryFixtures.index, now: now)
    let matches = [
      HistoryFixtures.ambassador1.id: 0.97, HistoryFixtures.ambassador2.id: 0.93,
      HistoryFixtures.ambassador3.id: 0.81, HistoryFixtures.github.id: 0.12,
      HistoryFixtures.youtube.id: 0.02, Ranker.webSearchID: 0.9,
    ]
    let hits = Ranker.rank(
      prefiltered,
      judgment: judgment(set: 0.92, matches: matches, target: [Ranker.webSearchID: 0.8]))
    let top = hits[0]
    XCTAssertTrue(top.isGroup)
    XCTAssertEqual(top.candidate.title, "Open all 3 links")
    XCTAssertEqual(top.candidate.kind, .openURL)
    XCTAssertEqual(top.jevProbability, 0.92)
    guard case .group(let members) = top.candidate.payload else { return XCTFail("no group") }
    XCTAssertEqual(
      Set(members.map(\.id)),
      [
        HistoryFixtures.ambassador1.id, HistoryFixtures.ambassador2.id,
        HistoryFixtures.ambassador3.id,
      ])
    XCTAssertEqual(hits.filter(\.inSet).count, 3)
    XCTAssertTrue(hits[1...3].allSatisfy(\.inSet), "members sit right under the group row")
    XCTAssertEqual(hits.last?.id, Ranker.webSearchID)
    XCTAssertFalse(hits.first { $0.id == HistoryFixtures.github.id }?.inSet ?? true)
    XCTAssertFalse(hits.first { $0.id == Ranker.webSearchID }?.inSet ?? true)
  }

  func testOneIntentKeepsSingleTargetOnTopButOffersGroup() {
    let prefiltered = Ranker.prefilter(
      query: "pdf downloads", index: HistoryFixtures.index, now: now)
    let hits = Ranker.rank(
      prefiltered,
      judgment: judgment(
        set: 0.2, matches: [Fixtures.roadmap.id: 0.9, Fixtures.invoice.id: 0.85],
        target: [Fixtures.roadmap.id: 0.7, Fixtures.invoice.id: 0.25]))
    XCTAssertEqual(hits[0].id, Fixtures.roadmap.id)
    XCTAssertTrue(hits[1].isGroup)
    XCTAssertEqual(hits[1].candidate.title, "Open all 2 files")
    XCTAssertTrue(hits[0].inSet)
  }

  func testClearlySingularQueryOffersNoGroupEvenWhenSeveralRowsFit() {
    let prefiltered = Ranker.prefilter(
      query: "pdf downloads", index: HistoryFixtures.index, now: now)
    let hits = Ranker.rank(
      prefiltered,
      judgment: judgment(
        set: 0.05, matches: [Fixtures.roadmap.id: 0.9, Fixtures.invoice.id: 0.85],
        target: [Fixtures.roadmap.id: 0.9]))
    XCTAssertFalse(hits.contains(where: \.isGroup))
    XCTAssertFalse(hits.contains(where: \.inSet))
  }

  func testNoGroupRowForASingleMatch() {
    let prefiltered = Ranker.prefilter(
      query: "pdf downloads", index: HistoryFixtures.index, now: now)
    let hits = Ranker.rank(
      prefiltered,
      judgment: judgment(set: 0.9, matches: [Fixtures.roadmap.id: 0.95, Fixtures.invoice.id: 0.1]))
    XCTAssertFalse(hits.contains(where: \.isGroup))
  }

  func testNoGroupRowWithoutJudgment() {
    let prefiltered = Ranker.prefilter(query: query, index: HistoryFixtures.index, now: now)
    XCTAssertFalse(Ranker.rank(prefiltered, judgment: nil).contains(where: \.isGroup))
  }

  func testGroupCandidateMixedKindsAndOverflowSubtitle() {
    let members = [
      Fixtures.roadmap, HistoryFixtures.github, HistoryFixtures.youtube, Fixtures.slack,
    ]
    let group = Ranker.groupCandidate(members)
    XCTAssertEqual(group.kind, .unclear)
    XCTAssertEqual(group.title, "Open all 4 items")
    XCTAssertTrue(group.subtitle.hasSuffix(" and 1 more"))
  }
}

final class SetQuestionTests: XCTestCase {
  func testRequestCarriesScopeWindowAndOneMatchPerRealCandidate() throws {
    let now = HistoryFixtures.now
    let query = "devin ambassador links from the past 24 hours"
    let prefiltered = Ranker.prefilter(query: query, index: HistoryFixtures.index, now: now)
    let context = LaunchContext(
      frontmostApp: "Finder", recentApps: [], clipboardKind: "empty", timeOfDay: "evening",
      weekday: "Thursday")
    let request = JevQuestions.buildRequest(
      query: query, context: context, candidates: prefiltered.candidates,
      window: prefiltered.window)
    XCTAssertEqual(request.questions["scope"]?.type, "choice")
    XCTAssertNotNil(request.state.timeWindow)
    let matchQuestions = request.questions.keys.filter { $0.hasPrefix("match_c") }
    let real = prefiltered.candidates.filter { $0.kind != .webSearch && $0.kind != .calculate }
    XCTAssertEqual(matchQuestions.count, real.count)
    XCTAssertEqual(request.questions.count, real.count + 4)

    let data = try JSONEncoder().encode(request)
    let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let state = try XCTUnwrap(json["state"] as? [String: Any])
    XCTAssertNotNil(state["time_window"])
    let questions = try XCTUnwrap(json["questions"] as? [String: Any])
    let scope = try XCTUnwrap(questions["scope"] as? [String: Any])
    let criteria = try XCTUnwrap(scope["criteria"] as? [String: String])
    XCTAssertEqual(Set(criteria.keys), [JevQuestions.scopeOne, JevQuestions.scopeAll])
  }

  func testParseReadsScopeAndMatches() throws {
    let candidates = [HistoryFixtures.ambassador1, HistoryFixtures.youtube]
    let json = """
      {"model":"jev-1.13.0",
       "answers":{
         "target":{"type":"choice","choice":"c0","confidence":0.5,"probabilities":{"c0":0.5,"c1":0.4,"none":0.1}},
         "action":{"type":"choice","choice":"open_url","confidence":0.9,"probabilities":{"open_url":0.9}},
         "ready":{"type":"noul","noul":0.3},
         "scope":{"type":"choice","choice":"all","confidence":0.88,"probabilities":{"all":0.88,"one":0.12}},
         "match_c0":{"type":"noul","noul":0.96},
         "match_c1":{"type":"noul","noul":0.04}},
       "usage":{"input_tokens":2100,"output_tokens":0}}
      """
    let response = try JSONDecoder().decode(JevResponse.self, from: Data(json.utf8))
    let judgment = try XCTUnwrap(JevQuestions.parse(response, candidates: candidates))
    XCTAssertEqual(judgment.setProbability, 0.88)
    XCTAssertEqual(judgment.matchProbabilities[HistoryFixtures.ambassador1.id], 0.96)
    XCTAssertEqual(judgment.matchProbabilities[HistoryFixtures.youtube.id], 0.04)
  }

  func testLegacyResponseWithoutScopeStillParses() throws {
    let json = """
      {"model":"jev-1.13.0",
       "answers":{"target":{"type":"choice","choice":"c0","confidence":0.9,"probabilities":{"c0":0.9,"none":0.1}}},
       "usage":{"input_tokens":1000,"output_tokens":0}}
      """
    let response = try JSONDecoder().decode(JevResponse.self, from: Data(json.utf8))
    let judgment = try XCTUnwrap(
      JevQuestions.parse(response, candidates: [HistoryFixtures.ambassador1]))
    XCTAssertEqual(judgment.setProbability, 0)
    XCTAssertTrue(judgment.matchProbabilities.isEmpty)
  }
}
