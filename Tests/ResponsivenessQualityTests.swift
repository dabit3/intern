import XCTest

@testable import Intern

private actor RequestLog {
  private(set) var queries: [String] = []

  func ask(_ request: JevRequest) async throws -> JevClient.Result {
    queries.append(request.state.query)
    let first = request.state.candidates.first?.id ?? "none"
    let response = JevResponse(
      model: "test",
      answers: [
        "target": .init(
          type: "choice", choice: first, confidence: 1, probabilities: [first: 1], noul: nil),
        "ready": .init(type: "noul", choice: nil, confidence: nil, probabilities: nil, noul: 1),
      ], usage: .init(inputTokens: 10, outputTokens: 0))
    return .init(response: response, latencyMs: 5)
  }
}

/// The behaviors behind "instant and steady": scoring without allocation, debounced requests,
/// judgments that survive refinement, habits that win, and an index that is warm at launch.
@MainActor
final class ResponsivenessQualityTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_789_819_200)

  private func app(_ title: String) -> Candidate {
    Candidate(
      id: "app:\(title)", title: title, subtitle: "Application", kind: .openApp,
      keywords: ["app", "application"],
      payload: .app(URL(fileURLWithPath: "/Applications/\(title).app")))
  }

  private func defaults() throws -> (UserDefaults, String) {
    let suite = "ResponsivenessQualityTests.\(UUID())"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defaults.set(false, forKey: "includeSpotlight")
    return (defaults, suite)
  }

  private func waitUntil(_ condition: () async -> Bool) async {
    for _ in 0..<150 {
      if await condition() { return }
      try? await Task.sleep(for: .milliseconds(10))
    }
    XCTFail("Timed out waiting for test state")
  }

  private func local(_ query: String, _ index: [Candidate], boosts: [String: Double] = [:])
    -> [RankedHit]
  {
    Ranker.rank(
      Ranker.prefilter(query: query, index: index, now: now, boosts: boosts), judgment: nil)
  }

  // MARK: Scoring

  func testPreparedDocumentsScoreExactlyLikeCandidates() {
    let queries = ["saf", "safrai", "tdm", "the pdf i just downloaded", "wi-fi on", "q3 roadmap"]
    for candidate in Fixtures.index {
      let document = Fuzzy.Document(candidate)
      for query in queries {
        let prepared = Fuzzy.Query(query)
        XCTAssertEqual(
          Fuzzy.score(query: prepared, candidate: candidate),
          Fuzzy.score(query: prepared, document: document), "\(query) → \(candidate.title)")
      }
    }
  }

  func testByteLevelHelpersMatchTheirStringCounterparts() {
    XCTAssertTrue(Fuzzy.isSingleEdit(Array("safrai".utf8), Array("safari".utf8)))
    XCTAssertTrue(Fuzzy.isSingleEdit(Array("safarii".utf8), Array("safari".utf8)))
    XCTAssertTrue(Fuzzy.isSingleEdit(Array("safri".utf8), Array("safari".utf8)))
    XCTAssertFalse(Fuzzy.isSingleEdit(Array("safari".utf8), Array("safari".utf8)))
    XCTAssertFalse(Fuzzy.isSingleEdit(Array("sofiri".utf8), Array("safari".utf8)))
    XCTAssertEqual(Fuzzy.subsequenceContiguity(Array("abc".utf8), in: Array("abxc".utf8)), 0.5)
    XCTAssertNil(Fuzzy.subsequenceContiguity(Array("abd".utf8), in: Array("abc".utf8)))
  }

  func testTypingAFillerWordDoesNotEmptyTheList() {
    let settled = local("the pdf i just", Fixtures.index).map(\.id)
    for draft in ["the pdf i j", "the pdf i ju", "the pdf i jus"] {
      XCTAssertEqual(local(draft, Fixtures.index).map(\.id), settled, draft)
    }
    XCTAssertTrue(settled.contains(Fixtures.roadmap.id))
    XCTAssertTrue(Fuzzy.isStopwordPrefix("ju"))
    XCTAssertFalse(Fuzzy.isStopwordPrefix("just"))
    XCTAssertFalse(Fuzzy.isStopwordPrefix("roadm"))
  }

  func testStartingTheNameBeatsStartingALaterWord() {
    let remote = app("Chrome Remote Desktop")
    let google = app("Google Chrome")
    XCTAssertEqual(local("chr", [google, remote]).first?.id, remote.id)
    XCTAssertEqual(local("goo", [google, remote]).first?.id, google.id)
  }

  func testHabitsWinTiesAndLearnedAliasesWinOutright() {
    let safari = app("Safari")
    let sable = app("Sable")
    XCTAssertEqual(local("sa", [safari, sable]).first?.id, sable.id)
    XCTAssertEqual(
      local("sa", [safari, sable], boosts: [safari.id: 0.12]).first?.id, safari.id)
    let spark = app("Spark")
    XCTAssertFalse(local("mail", [spark, safari]).contains { $0.id == spark.id })
    XCTAssertEqual(
      local("mail", [spark, safari], boosts: [spark.id: Ranker.maximumBoost]).first?.id, spark.id)
    XCTAssertFalse(
      local("mail", [spark, safari], boosts: [spark.id: 0.2]).contains { $0.id == spark.id })
  }

  func testTypingTheStartOfALearnedShortQueryLiftsItsItem() throws {
    let (defaults, suite) = try defaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let library = PersonalLibrary(defaults: defaults)
    library.record(Fixtures.safari, query: "saf", now: now.addingTimeInterval(-40 * 86_400))
    library.record(Fixtures.roadmap, query: "my research browser", now: now)
    XCTAssertGreaterThanOrEqual(
      library.boosts(query: "sa", now: now)[Fixtures.safari.id] ?? 0, 0.25)
    XCTAssertEqual(
      library.boosts(query: "saf", now: now)[Fixtures.safari.id], Ranker.maximumBoost)
    XCTAssertLessThan(library.boosts(query: "s", now: now)[Fixtures.safari.id] ?? 0, 0.25)
    XCTAssertLessThan(library.boosts(query: "my", now: now)[Fixtures.roadmap.id] ?? 0, 0.25)
  }

  func testExactNameIsNeverDemotedByTheOnlineReading() {
    let slack = app("Slack")
    let notes = Candidate(
      id: "file:slack-notes", title: "slack-notes.pdf", subtitle: "Downloads", kind: .openFile,
      keywords: ["pdf"], payload: .file(URL(fileURLWithPath: "/fixtures/slack-notes.pdf")))
    let prefiltered = Ranker.prefilter(query: "slack", index: [slack, notes], now: now)
    let judgment = JevJudgment(
      targetProbabilities: [notes.id: 0.95, slack.id: 0.05], noneProbability: 0,
      targetConfidence: 0.95, action: .openFile, actionProbabilities: [.openFile: 0.9],
      actionConfidence: 0.9, ready: 0.9)
    let hits = Ranker.rank(prefiltered, judgment: judgment)
    XCTAssertEqual(hits.first?.id, slack.id)
    XCTAssertEqual(hits.first?.jevProbability, 0.05)
    XCTAssertGreaterThan(hits[1].score, hits[0].score)
  }

  func testStaleJudgmentOnlyNudgesAndNeverOffersAGroup() {
    let prefiltered = Ranker.prefilter(query: "pdf downloaded", index: Fixtures.index, now: now)
    let judgment = JevJudgment(
      targetProbabilities: [Fixtures.invoice.id: 0.9, Fixtures.roadmap.id: 0.1],
      noneProbability: 0, targetConfidence: 0.9, action: .openFile,
      actionProbabilities: [.openFile: 1], actionConfidence: 1, ready: 0.9, setProbability: 0.9,
      matchProbabilities: [Fixtures.invoice.id: 0.9, Fixtures.roadmap.id: 0.9])
    let fresh = Ranker.rank(prefiltered, judgment: judgment, fresh: true)
    let stale = Ranker.rank(prefiltered, judgment: judgment, fresh: false)
    XCTAssertEqual(fresh.first?.id, Ranker.groupID)
    XCTAssertFalse(stale.contains { $0.id == Ranker.groupID })
    let freshInvoice = fresh.first { $0.id == Fixtures.invoice.id }?.score ?? 0
    let staleInvoice = stale.first { $0.id == Fixtures.invoice.id }?.score ?? 0
    let localInvoice =
      local("pdf downloaded", Fixtures.index).first { $0.id == Fixtures.invoice.id }?.score ?? 0
    XCTAssertGreaterThan(freshInvoice, staleInvoice)
    XCTAssertGreaterThan(staleInvoice, localInvoice)
    XCTAssertEqual(stale.first { $0.id == Fixtures.invoice.id }?.jevProbability, 0.9)
  }

  // MARK: Model

  func testKeystrokesWithinTheDebounceWindowSendOneRequestForTheFinalDraft() async throws {
    let (defaults, suite) = try defaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let log = RequestLog()
    let model = InternModel(defaults: defaults) { try await log.ask($0) }
    model.replaceIndex(Fixtures.index)
    model.query = "s"
    XCTAssertFalse(model.hits.isEmpty)
    for draft in ["sa", "saf", "safa", "safar", "safari"] {
      model.query = draft
      XCTAssertEqual(model.topHit?.id, Fixtures.safari.id, draft)
    }
    XCTAssertEqual(model.inFlight, 0)
    await waitUntil { model.judgmentIsFresh }
    let queries = await log.queries
    XCTAssertEqual(queries, ["safari"])
    XCTAssertEqual(model.stats.requests, 1)
  }

  func testRefiningAQueryKeepsItsJudgmentAsStaleUntilTheNextAnswer() async throws {
    let (defaults, suite) = try defaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let log = RequestLog()
    let model = InternModel(defaults: defaults) { try await log.ask($0) }
    model.replaceIndex(Fixtures.index)
    model.query = "dark"
    await waitUntil { model.judgmentIsFresh }
    XCTAssertTrue(model.isReady)

    model.query = "dark m"
    XCTAssertNotNil(model.judgment)
    XCTAssertFalse(model.judgmentIsFresh)
    XCTAssertFalse(model.isReady)
    XCTAssertNotNil(model.hits.first?.jevProbability)
    await waitUntil { model.judgmentIsFresh }
    XCTAssertTrue(model.isReady)

    model.query = "wifi"
    XCTAssertNil(model.judgment)
    XCTAssertTrue(model.hits.allSatisfy { $0.jevProbability == nil })
    let queries = await log.queries
    XCTAssertEqual(queries, ["dark", "dark m"])
  }

  func testReadinessRequiresJevAndTheLocalOrderToAgree() async throws {
    let (defaults, suite) = try defaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let slack = app("Slack")
    let notes = Candidate(
      id: "file:slack-notes", title: "slack-notes.pdf", subtitle: "Downloads", kind: .openFile,
      keywords: ["pdf"], payload: .file(URL(fileURLWithPath: "/fixtures/slack-notes.pdf")))
    let model = InternModel(defaults: defaults) { request in
      let target = request.state.candidates.first { $0.title == notes.title }?.id ?? "none"
      let response = JevResponse(
        model: "test",
        answers: [
          "target": .init(
            type: "choice", choice: target, confidence: 1, probabilities: [target: 1], noul: nil),
          "ready": .init(type: "noul", choice: nil, confidence: nil, probabilities: nil, noul: 1),
        ], usage: .init(inputTokens: 10, outputTokens: 0))
      return .init(response: response, latencyMs: 5)
    }
    model.replaceIndex([slack, notes])
    model.query = "slack"
    await waitUntil { model.judgmentIsFresh }
    XCTAssertEqual(model.topHit?.id, slack.id)
    XCTAssertFalse(model.isReady)
  }

  func testStoredIndexAnswersBeforeTheFirstRebuildFinishes() async throws {
    let (defaults, suite) = try defaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "IndexStore-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = IndexStore(url: directory.appendingPathComponent("nested/index.json"))
    let present = try XCTUnwrap(Bundle(for: Self.self).executableURL)
    let kept = Candidate(
      id: "file:\(present.path)", title: present.lastPathComponent, subtitle: "Test",
      kind: .openFile, payload: .file(present))
    let gone = Candidate(
      id: "file:/nonexistent/\(UUID().uuidString).pdf", title: "gone.pdf", subtitle: "Test",
      kind: .openFile,
      payload: .file(URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString).pdf")))
    store.save([Fixtures.safari, kept, gone])
    XCTAssertEqual(store.load()?.map(\.id), [Fixtures.safari.id, kept.id])

    var builds = 0
    let model = InternModel(
      defaults: defaults,
      buildIndex: { _ in
        builds += 1
        try? await Task.sleep(for: .seconds(5))
        return LocalIndex(candidates: [])
      },
      indexStore: store)
    await waitUntil { model.indexSize == 2 }
    model.query = "safari"
    XCTAssertEqual(model.topHit?.id, Fixtures.safari.id)
    XCTAssertEqual(builds, 0)
  }
}
