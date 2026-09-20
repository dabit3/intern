import XCTest

@testable import Intern

/// End-to-end probes against the real API over the real local index. Skipped unless
/// `TYPESAFE_API_KEY` is set and `JEV_LIVE=1`, so the default suite stays offline.
final class LiveJevTests: XCTestCase {
  let context = LaunchContext(
    frontmostApp: "Finder", recentApps: ["Finder"], clipboardKind: "empty", timeOfDay: "evening",
    weekday: "Thursday")

  override func setUpWithError() throws {
    try XCTSkipUnless(
      JevClient.apiKey() != nil && ProcessInfo.processInfo.environment["JEV_LIVE"] == "1",
      "set TYPESAFE_API_KEY and JEV_LIVE=1 to run live probes")
  }

  private func judge(_ query: String, index: [Candidate]) async throws -> (
    [RankedHit], JevJudgment, Ranker.Prefiltered, Int, Double
  ) {
    let prefiltered = Ranker.prefilter(query: query, index: index)
    let request = JevQuestions.buildRequest(
      query: query, context: context, candidates: prefiltered.candidates,
      window: prefiltered.window)
    let start = Date()
    let result = try await JevClient().ask(request)
    let ms = Date().timeIntervalSince(start) * 1000
    let judgment = try XCTUnwrap(
      JevQuestions.parse(result.response, candidates: prefiltered.candidates))
    let hits = Ranker.rank(prefiltered, judgment: judgment)
    return (hits, judgment, prefiltered, result.response.usage.inputTokens, ms)
  }

  private func report(
    _ query: String, _ hits: [RankedHit], _ judgment: JevJudgment, _ tokens: Int, _ ms: Double
  ) {
    print(
      "\n▶ \(query)  [\(tokens) tokens, \(Int(ms)) ms, all=\(String(format: "%.2f", judgment.setProbability)) ready=\(String(format: "%.2f", judgment.ready))]"
    )
    for hit in hits.prefix(8) {
      let mark = hit.inSet ? "*" : " "
      let target = hit.jevProbability.map { String(format: "%.2f", $0) } ?? "  - "
      let match = hit.matchProbability.map { String(format: "%.2f", $0) } ?? "  - "
      print("  \(mark) t=\(target) m=\(match)  \(hit.candidate.title) — \(hit.candidate.subtitle)")
    }
  }

  func testAmbassadorLinksInPast24HoursFormASet() async throws {
    let index = LocalIndex.build().candidates
    let query = "open devin ambassador links i've visited in the past 24 hours"
    let (hits, judgment, prefiltered, tokens, ms) = try await judge(query, index: index)
    report(query, hits, judgment, tokens, ms)
    XCTAssertNotNil(prefiltered.window)
    XCTAssertFalse(
      prefiltered.candidates.contains { $0.id.contains("ref=tw") },
      "3-day-old visit excluded in code")
    let top = try XCTUnwrap(hits.first)
    XCTAssertTrue(top.isGroup, "expected the group row on top")
    guard case .group(let members) = top.candidate.payload else { return XCTFail() }
    XCTAssertEqual(members.count, 3)
    XCTAssertTrue(members.allSatisfy { $0.title.localizedCaseInsensitiveContains("ambassador") })
    let certain = await MainActor.run { InternModel.certainSetThreshold }
    XCTAssertGreaterThanOrEqual(judgment.setProbability, certain)
  }

  func testSinglePDFStaysSingle() async throws {
    let index = LocalIndex.build().candidates
    let query = "the pdf I just downloaded"
    let (hits, judgment, _, tokens, ms) = try await judge(query, index: index)
    report(query, hits, judgment, tokens, ms)
    let top = try XCTUnwrap(hits.first)
    XCTAssertFalse(top.isGroup)
    XCTAssertEqual(top.candidate.kind, .openFile)
    XCTAssertLessThan(judgment.setProbability, Ranker.setThreshold)
    XCTAssertFalse(hits.contains(where: \.isGroup), "singular query should not offer a group")
  }

  func testRecentFilesFormAGroup() async throws {
    let index = LocalIndex.build().candidates
    let query = "the files I downloaded in the last hour"
    let (hits, judgment, _, tokens, ms) = try await judge(query, index: index)
    report(query, hits, judgment, tokens, ms)
    let group = try XCTUnwrap(hits.first(where: \.isGroup), "expected a group row")
    XCTAssertEqual(group.candidate.kind, .openFile)
    guard case .group(let members) = group.candidate.payload else { return XCTFail() }
    XCTAssertTrue(members.allSatisfy { ($0.ageDays ?? 1) <= 1.0 / 24 })
    XCTAssertGreaterThanOrEqual(members.count, 2)
  }

  func testUnrelatedPagesAreNotInTheSet() async throws {
    let index = LocalIndex.build().candidates
    let query = "pages about typesafe I read today"
    let (hits, judgment, _, tokens, ms) = try await judge(query, index: index)
    report(query, hits, judgment, tokens, ms)
    let members = hits.filter(\.inSet).map(\.candidate.title)
    XCTAssertFalse(members.contains { $0.contains("lofi") || $0.contains("Hacker News") })
    XCTAssertTrue(
      hits.contains { $0.candidate.title.contains("TypeSafe") && ($0.matchProbability ?? 0) > 0.5 },
      "the TypeSafe docs visit should survive the prefilter and be judged a match")
  }

  func testSingleWordQueriesStillWork() async throws {
    let index = LocalIndex.build().candidates
    for (query, kind) in [("dark", ActionKind.systemToggle), ("wifi off", .systemToggle)] {
      let (hits, judgment, _, tokens, ms) = try await judge(query, index: index)
      report(query, hits, judgment, tokens, ms)
      XCTAssertEqual(hits.first?.candidate.kind, kind)
      XCTAssertFalse(hits.first?.isGroup ?? true)
    }
  }
}
