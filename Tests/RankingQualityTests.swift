import XCTest

@testable import Intern

final class RankingQualityTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_789_819_200)

  private func app(_ title: String) -> Candidate {
    Candidate(
      id: "app:\(title)", title: title, subtitle: "Application", kind: .openApp,
      keywords: ["app", "application"],
      payload: .app(URL(fileURLWithPath: "/Applications/\(title).app")))
  }

  private func file(
    _ title: String, modified: Double = 3_600, opened: Double? = nil, added: Double? = nil
  ) -> Candidate {
    Candidate(
      id: "file:\(title)", title: title, subtitle: "Downloads", kind: .openFile,
      keywords: ["file", "pdf", "downloaded", "download"],
      payload: .file(URL(fileURLWithPath: "/fixtures/\(title)")),
      modifiedAt: now.addingTimeInterval(-modified),
      lastOpenedAt: opened.map { now.addingTimeInterval(-$0) },
      addedAt: added.map { now.addingTimeInterval(-$0) })
  }

  private var crowded: [Candidate] {
    (0..<450).map {
      file("A\($0).pdf", modified: 3_600 + Double($0), opened: 7_200, added: 10_800)
    }
  }

  private func hits(
    _ query: String, _ index: [Candidate], scope: SearchScope = .all,
    boosts: [String: Double] = [:]
  ) -> [RankedHit] {
    Ranker.rank(
      Ranker.prefilter(query: query, index: index, now: now, scope: scope, boosts: boosts),
      judgment: nil)
  }

  private func link(
    _ url: String, _ title: String, visited: Double, visits: Int = 1
  ) -> Candidate {
    let entry = ChromeHistory.Entry(
      url: URL(string: url)!, title: title, lastVisit: now.addingTimeInterval(-visited),
      visitCount: visits)
    return ChromeHistory.candidate(for: entry, now: now)
  }

  private let stripe = "https://dashboard.stripe.com/acct_1Om98nD4cNvH28G6"

  func testSiteLevelQueriesPreferTheHubOverTheLastVisitedDeepLink() {
    let hub = link("\(stripe)/dashboard", "Dashboard · Stripe", visited: 2 * 86_400, visits: 120)
    let deep = link(
      "\(stripe)/coupons/ljMyDEpk?starting_after=promo_1UE8XhD4cNvH28G6wduAN7aq",
      "Coupons · Stripe", visited: 3_600, visits: 2)
    let payments = link("\(stripe)/payments", "Payments · Stripe", visited: 1_800, visits: 10)
    for query in ["stripe dashboard", "stripe dash", "stripe"] {
      XCTAssertEqual(hits(query, [deep, payments, hub]).first?.id, hub.id, query)
    }
    XCTAssertEqual(
      Array(hits("stripe", [deep, payments, hub]).map(\.id).prefix(3)),
      [hub.id, payments.id, deep.id])
    XCTAssertEqual(Ranker.depth(hub), 2)
    XCTAssertEqual(Ranker.depth(deep), 5)
  }

  func testDeepLinksStillWinWhenTheirOwnWordsMatch() {
    let hub = link("\(stripe)/dashboard", "Dashboard · Stripe", visited: 2 * 86_400, visits: 120)
    let deep = link(
      "\(stripe)/coupons/ljMyDEpk?starting_after=promo_1UE8XhD4cNvH28G6wduAN7aq",
      "Coupons · Stripe", visited: 3_600, visits: 2)
    XCTAssertEqual(hits("stripe coupons", [hub, deep]).first?.id, deep.id)
    XCTAssertEqual(hits("coupons", [hub, deep]).first?.id, deep.id)
  }

  func testTimeWindowQueriesStayNewestFirstAndOtherRowsKeepTheirPlaces() {
    let hub = link("\(stripe)/dashboard", "Dashboard · Stripe", visited: 2 * 86_400, visits: 120)
    let deep = link(
      "\(stripe)/coupons/ljMyDEpk?starting_after=promo_1UE8XhD4cNvH28G6wduAN7aq",
      "Coupons · Stripe", visited: 3_600, visits: 2)
    XCTAssertEqual(
      hits("stripe links from this week", [hub, deep]).map(\.id).prefix(2).map { $0 },
      [deep.id, hub.id])
    let notes = file("stripe-notes.pdf", modified: 3 * 3_600)
    let mixed = hits("stripe", [deep, notes, hub]).map(\.id)
    XCTAssertEqual(Array(mixed.prefix(3)), [hub.id, notes.id, deep.id])
  }

  func testExactTitleSurvivesCrowdedKeywordMatchesAndBoosts() {
    let target = app("Notes")
    let distractors = (0..<450).map { file("Notes \($0).pdf") }
    let boosts = Dictionary(uniqueKeysWithValues: distractors.map { ($0.id, 0.35) })
    for query in ["Notes", "open Notes"] {
      XCTAssertEqual(hits(query, distractors + [target], boosts: boosts).first?.id, target.id)
    }
  }

  func testNormalizedNamesAndInitials() {
    for (query, target) in [
      ("cafe", file("Café.pdf")),
      ("resume", file("Résumé.pdf")),
      ("q3-roadmap-review", file("Q3 Roadmap Review.pdf")),
      ("vsc", app("Visual Studio Code")),
      ("vs code", app("Visual Studio Code")),
      ("goog chr", app("Google Chrome")),
      ("wi‑fi on", SystemToggle.wifiOn.candidate),
    ] {
      XCTAssertEqual(hits(query, crowded + [target]).first?.id, target.id, query)
    }
  }

  func testSingleEditTyposStillRecallApps() {
    for (query, title) in [
      ("safrai", "Safari"), ("chorme", "Google Chrome"), ("calender", "Calendar"),
      ("termnal", "Terminal"), ("safarii", "Safari"),
    ] {
      let target = app(title)
      XCTAssertEqual(hits(query, crowded + [target]).first?.id, target.id, query)
    }
    XCTAssertEqual(Fuzzy.score(query: "zz", candidate: app("Safari")), 0)
  }

  func testMeaningfulTitleOutranksGenericFileTerms() {
    let target = file("Annual-Research-Summary.pdf", modified: 90_000)
    for query in ["research pdf", "the research pdf I downloaded"] {
      XCTAssertEqual(hits(query, crowded + [target]).first?.id, target.id, query)
    }
    XCTAssertFalse(
      hits("unfindableword pdf", crowded).contains { $0.candidate.kind == .openFile })
  }

  func testNewestRelevantFilesSurviveCrowdedCorpusAndFinalSort() {
    let downloaded = file("Quarterly-Roadmap-Review-Final.pdf", modified: 3_000_000, added: 30)
    let opened = file("Annual-Research-Summary.pdf", modified: 6_000_000, opened: 45)
    let edited = file("Engineering-Architecture-Proposal.pdf", modified: 10, added: 900_000)
    let index = crowded + [downloaded, opened, edited]
    for (query, target) in [
      ("the pdf I just downloaded", downloaded), ("latest pdf", edited),
      ("the last pdf I opened", opened), ("the pdf I most recently modified", edited),
      ("pdf I downloaded in the last hour", downloaded),
      ("pdf I opened in the past day", opened),
    ] {
      let result = hits(query, index)
      XCTAssertEqual(result.first?.id, target.id, query)
      XCTAssertLessThanOrEqual(result.count, JevQuestions.maxCandidates)
    }
  }

  func testRequestedTypeIsAConstraintRatherThanAPartialMatch() {
    let pdf = file("Quarterly-Roadmap.pdf", modified: 100)
    let text = Candidate(
      id: "text", title: "Quarterly-Roadmap.txt", subtitle: "", kind: .openFile,
      keywords: ["file", "text"], payload: .file(URL(fileURLWithPath: "/fixtures/notes.txt")),
      modifiedAt: now.addingTimeInterval(-1))
    XCTAssertEqual(
      hits("roadmap pdf", [text, pdf], scope: .files).map(\.id), [pdf.id])
  }

  func testExplicitToggleDirectionIsNotAStopword() {
    let index = SystemToggle.allCases.map(\.candidate)
    for (query, toggle) in [
      ("wifi on", SystemToggle.wifiOn), ("wifi off", .wifiOff),
      ("show hidden files", .showHiddenFiles), ("hide hidden files", .hideHiddenFiles),
    ] {
      XCTAssertEqual(hits(query, index).first?.id, toggle.candidate.id, query)
    }
  }

  func testSemanticAppRolesHaveRecallWithoutSearchingEveryApplication() {
    let index = [app("Safari"), app("Google Chrome"), app("Terminal"), app("Visual Studio Code")]
    for (query, expected) in [
      ("web browser", app("Safari")), ("code editor", app("Visual Studio Code")),
      ("command line", app("Terminal")),
    ] {
      XCTAssertTrue(hits(query, crowded + index).contains { $0.id == expected.id }, query)
    }
    XCTAssertFalse(hits("unrelated zzzz", index).contains { $0.candidate.kind == .openApp })
  }

  func testDirectWebsiteEntryAndUnsafeSchemeRejection() {
    for query in ["example.com", "https://example.com/path?q=one#two", "http://localhost:8080"] {
      let result = hits(query, [])
      guard case .url(let url) = result.first?.candidate.payload else {
        XCTFail("No direct URL for \(query)")
        continue
      }
      XCTAssertTrue(["http", "https"].contains(url.scheme ?? ""))
      XCTAssertEqual(result.last?.id, Ranker.webSearchID)
    }
    for query in [
      "javascript:alert(1)", "file:///etc/passwd", "example.com search",
      "https://user:password@example.com", "notes.pdf",
    ] {
      XCTAssertFalse(hits(query, []).contains { $0.candidate.kind == .openURL }, query)
    }
    XCTAssertTrue(hits("example.com", [], scope: .files).isEmpty)
  }

  func testWorkspaceDoesNotLeakIntoAppOrLinkScopes() {
    for member in [app("Safari"), HistoryFixtures.youtube] {
      let workspace = Candidate(
        id: "workspace:\(member.id)", title: member.title, subtitle: "", kind: member.kind,
        payload: .group([member, Fixtures.roadmap]))
      XCTAssertFalse(SearchScope.apps.includes(workspace))
      XCTAssertFalse(SearchScope.links.includes(workspace))
      XCTAssertTrue(SearchScope.workspaces.includes(workspace))
    }
    let spoof = Candidate(
      id: "workspace:spoof", title: "Spoof", subtitle: "", kind: .openApp,
      payload: .app(URL(fileURLWithPath: "/Applications/Spoof.app")))
    XCTAssertFalse(SearchScope.workspaces.includes(spoof))
  }

  func testDuplicateIDsCannotConsumeShortlistOrCreateASingleMemberGroup() {
    let target = file("Research.pdf")
    let other = file("Research Notes.pdf")
    let filtered = Ranker.prefilter(
      query: "research", index: Array(repeating: target, count: 40) + [other], now: now)
    XCTAssertEqual(Set(filtered.candidates.map(\.id)).count, filtered.candidates.count)
    XCTAssertTrue(filtered.candidates.contains { $0.id == other.id })
    let duplicate = Ranker.Prefiltered(candidates: [target, target], fuzzy: [target.id: 1])
    let judgment = JevJudgment(
      targetProbabilities: [:], noneProbability: 0, targetConfidence: 1, action: .openFile,
      actionProbabilities: [:], actionConfidence: 1, ready: 0,
      setProbability: 1, matchProbabilities: [target.id: 1])
    XCTAssertTrue(Ranker.setMembers(duplicate, judgment: judgment).isEmpty)
    XCTAssertEqual(Ranker.rank(duplicate, judgment: nil).count, 1)
  }

  func testAliasBoostCannotDisplaceExactNameOrIgnoreType() {
    let target = app("Safari")
    let alias = app("Chrome")
    XCTAssertEqual(
      hits("Safari", [alias, target], boosts: [alias.id: 100]).first?.id, target.id)
    XCTAssertFalse(
      hits("latest pdf", [alias], boosts: [alias.id: 0.35]).contains { $0.id == alias.id })
    XCTAssertFalse(
      hits("zzzz", [alias], boosts: [alias.id: .infinity]).contains { $0.id == alias.id })
  }

  func testUnknownDatedItemsDoNotPassAWindow() {
    let unknown = Candidate(
      id: "unknown", title: "Research.pdf", subtitle: "", kind: .openFile,
      payload: .file(URL(fileURLWithPath: "/fixtures/Research.pdf")))
    XCTAssertTrue(hits("research pdf today", [unknown], scope: .files).isEmpty)
  }

  func testExactNamesWithStructuredWordsStayEligible() {
    for target in [
      file("Yesterday.pdf", modified: 90 * 86_400),
      file("Last Opened.pdf", modified: 90 * 86_400),
      app("Photos"), app("Pages"),
    ] {
      XCTAssertEqual(hits(target.title, crowded + [target]).first?.id, target.id)
    }
  }

  func testAllIntentKeepsMembersTogetherWhileSingularIntentKeepsBestTarget() {
    let first = file("First.pdf")
    let second = file("Second.pdf")
    let outsider = app("Safari")
    let filtered = Ranker.Prefiltered(
      candidates: [outsider, first, second],
      fuzzy: [outsider.id: 1, first.id: 0.5, second.id: 0.5])
    for probability in [0.95, 0.05] {
      let judgment = JevJudgment(
        targetProbabilities: [outsider.id: 0.9], noneProbability: 0, targetConfidence: 1,
        action: .openFile, actionProbabilities: [:], actionConfidence: 1, ready: 0,
        setProbability: probability, matchProbabilities: [first.id: 0.95, second.id: 0.95])
      let result = Ranker.rank(filtered, judgment: judgment)
      if probability > 0.5 {
        XCTAssertEqual(result.first?.id, Ranker.groupID)
        XCTAssertTrue(result[1].inSet)
        XCTAssertTrue(result[2].inSet)
      } else {
        XCTAssertEqual(result.first?.id, outsider.id)
        XCTAssertFalse(result.contains(where: \.isGroup))
      }
    }
  }

  func testFutureFileDatesAreNotClampedIntoToday() {
    let future = file("Future.pdf", modified: -3_600)
    XCTAssertTrue(hits("pdf today", [future], scope: .files).isEmpty)
  }

  func testRecencyOrderSurvivesEqualLocalScores() {
    let recent = file("Z.pdf", modified: 1)
    let old = file("A.pdf", modified: 3_600)
    XCTAssertEqual(hits("pdf", [old, recent]).first?.id, recent.id)
  }

  func testVisitTimestampAdvancesAndLegacyCandidatesStillDecode() throws {
    let legacy = Candidate(
      id: "legacy", title: "Legacy visit", subtitle: "", kind: .openURL,
      payload: .url(URL(string: "https://example.com/legacy")!), ageDays: 0.01)
    let decoded = try JSONDecoder().decode(Candidate.self, from: JSONEncoder().encode(legacy))
    XCTAssertNil(decoded.visitedAt)
    XCTAssertEqual(decoded.age(for: .modified, now: now), legacy.ageDays)
    let dated = Candidate(
      id: legacy.id, title: legacy.title, subtitle: legacy.subtitle, kind: legacy.kind,
      keywords: legacy.keywords, payload: legacy.payload, ageDays: 0,
      visitedAt: now.addingTimeInterval(-60))
    XCTAssertEqual(dated.age(for: .modified, now: now)! * 86_400, 60, accuracy: 0.001)
    let tomorrow = now.addingTimeInterval(86_400)
    XCTAssertEqual(dated.age(for: .modified, now: tomorrow)! * 86_400, 86_460, accuracy: 0.001)
    XCTAssertFalse(
      Ranker.prefilter(query: "links today", index: [dated], now: tomorrow).candidates.contains {
        $0.id == dated.id
      })
    XCTAssertEqual(
      try JSONDecoder().decode(Candidate.self, from: JSONEncoder().encode(dated)).visitedAt,
      dated.visitedAt)
  }
}

final class RankingTimeQualityTests: XCTestCase {
  private var calendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
    calendar.firstWeekday = 2
    return calendar
  }

  private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0) -> Date {
    calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
  }

  func testNamedPrefixesUseCapturedWindowAndCalendarBoundaries() throws {
    let now = date(2026, 9, 20, 15)
    for query in ["yesterday", "from yesterday", "on yesterday"] {
      let window = try XCTUnwrap(TimeWindow.parse(query, now: now, calendar: calendar))
      XCTAssertEqual(window.since, date(2026, 9, 19), query)
      XCTAssertEqual(window.until, date(2026, 9, 20), query)
    }
    let since = try XCTUnwrap(TimeWindow.parse("since yesterday", now: now, calendar: calendar))
    XCTAssertEqual(since.since, date(2026, 9, 19))
    XCTAssertNil(since.until)
    let week = try XCTUnwrap(TimeWindow.parse("last week", now: now, calendar: calendar))
    XCTAssertEqual(week.since, date(2026, 9, 7))
    XCTAssertEqual(week.until, date(2026, 9, 14))
    let month = try XCTUnwrap(TimeWindow.parse("last month", now: now, calendar: calendar))
    XCTAssertEqual(month.since, date(2026, 8, 1))
    XCTAssertEqual(month.until, date(2026, 9, 1))
  }

  func testYesterdayRespectsDaylightSavingAndExclusiveEnd() throws {
    let now = date(2026, 3, 9, 12)
    let window = try XCTUnwrap(TimeWindow.parse("yesterday", now: now, calendar: calendar))
    XCTAssertEqual(window.since, date(2026, 3, 8))
    XCTAssertEqual(window.until, date(2026, 3, 9))
    let atStart = now.timeIntervalSince(window.since) / 86_400
    let atEnd = now.timeIntervalSince(try XCTUnwrap(window.until)) / 86_400
    XCTAssertTrue(window.contains(ageDays: atStart, now: now))
    XCTAssertFalse(window.contains(ageDays: atEnd, now: now))
  }

  func testInvalidAndFutureAgesAreExcluded() throws {
    let now = date(2026, 9, 20, 15)
    let window = try XCTUnwrap(TimeWindow.parse("today", now: now, calendar: calendar))
    for age in [-0.1, Double.nan, .infinity, -.infinity] {
      XCTAssertFalse(window.contains(ageDays: age, now: now))
    }
    XCTAssertTrue(window.contains(ageDays: 0, now: now))
  }

  func testEarlierInvalidRelativePhraseDoesNotHideRealWindow() throws {
    let now = date(2026, 9, 20, 15)
    for query in [
      "the last pdf I opened in the past hour", "recently opened files in the past hour",
    ] {
      let window = try XCTUnwrap(TimeWindow.parse(query, now: now, calendar: calendar))
      XCTAssertEqual(window.since, now.addingTimeInterval(-3_600))
    }
    let month = try XCTUnwrap(
      TimeWindow.parse("past one month", now: date(2026, 3, 31, 15), calendar: calendar))
    XCTAssertEqual(month.since, date(2026, 2, 28, 15))
  }

  func testAgoAndDayPartsHaveActualBounds() throws {
    let now = date(2026, 9, 20, 21)
    let ago = try XCTUnwrap(
      TimeWindow.parse("files from a few days ago", now: now, calendar: calendar))
    XCTAssertEqual(ago.since, date(2026, 9, 17))
    XCTAssertEqual(ago.until, date(2026, 9, 18))
    let morning = try XCTUnwrap(
      TimeWindow.parse("this morning", now: now, calendar: calendar))
    XCTAssertEqual(morning.since, date(2026, 9, 20))
    XCTAssertEqual(morning.until, date(2026, 9, 20, 12))
    let night = try XCTUnwrap(TimeWindow.parse("last night", now: now, calendar: calendar))
    XCTAssertEqual(night.since, date(2026, 9, 19, 18))
    XCTAssertEqual(night.until, date(2026, 9, 20, 6))
  }

  func testInvalidCountsDoNotSilentlyBecomeOne() {
    let now = date(2026, 9, 20, 15)
    for query in ["last 0 days", "last 999999999999999999999 days"] {
      XCTAssertNil(TimeWindow.parse(query, now: now, calendar: calendar), query)
    }
  }
}
