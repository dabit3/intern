import XCTest

@testable import Intern

final class IntegrationQualityTests: XCTestCase {
  func testUncertainWebJudgmentPreservesStrongLocalMatch() throws {
    let local = Ranker.prefilter(query: "safrai", index: [Fixtures.safari])
    let judgment = JevJudgment(
      targetProbabilities: [Fixtures.safari.id: 0.4, Ranker.webSearchID: 0.44],
      noneProbability: 0.16, targetConfidence: 0.16, action: .webSearch,
      actionProbabilities: [.openApp: 0.14, .webSearch: 0.82, .unclear: 0.04],
      actionConfidence: 0.79, ready: 0.3)
    XCTAssertEqual(Ranker.rank(local, judgment: judgment).first?.id, Fixtures.safari.id)
    let certainSearch = JevJudgment(
      targetProbabilities: [Fixtures.safari.id: 0.02, Ranker.webSearchID: 0.98],
      noneProbability: 0, targetConfidence: 0.98, action: .webSearch,
      actionProbabilities: [.webSearch: 1], actionConfidence: 1, ready: 1)
    XCTAssertEqual(Ranker.rank(local, judgment: certainSearch).first?.id, Ranker.webSearchID)
  }

  func testRoundedOnlineProbabilitiesAreNormalizedWithoutAcceptingIncompleteAnswers() throws {
    for probabilities in [
      ["c0": 0.93, "c1": 0.04, "c2": 0.02, "none": 0],
      ["c0": 0.93, "c1": 0.04, "c2": 0.04, "none": 0],
    ] {
      let response = JevResponse(
        model: "test",
        answers: [
          "target": .init(
            type: "choice", choice: "c0", confidence: 0.91,
            probabilities: probabilities, noul: nil)
        ], usage: .init(inputTokens: 0, outputTokens: 0))
      let judgment = try XCTUnwrap(
        JevQuestions.parse(
          response, candidates: [Fixtures.roadmap, Fixtures.safari, Fixtures.sleep]))
      XCTAssertEqual(judgment.targetProbabilities.values.reduce(0, +), 1, accuracy: 0.000001)
      XCTAssertEqual(
        judgment.targetProbabilities[Fixtures.roadmap.id] ?? 0,
        0.93 / probabilities.values.reduce(0, +), accuracy: 0.000001)
    }
    let incomplete = JevResponse(
      model: "test",
      answers: [
        "target": .init(
          type: "choice", choice: "c0", confidence: 0.91,
          probabilities: ["c0": 0.93], noul: nil)
      ], usage: .init(inputTokens: 0, outputTokens: 0))
    XCTAssertNil(JevQuestions.parse(incomplete, candidates: [Fixtures.roadmap]))
  }

  func testOnlineRecencyOrderSeparatesEvidenceBasesAndPreservesTies() {
    let now = Date(timeIntervalSince1970: 1_790_000_000)
    let files = [446.0, 421, 421, 0].enumerated().map { index, age in
      Candidate(
        id: "file:\(index)", title: "\(index).pdf", subtitle: "Added 7 min ago", kind: .openFile,
        payload: .file(URL(fileURLWithPath: "/fixtures/\(index).pdf")),
        modifiedAt: now,
        addedAt: index == 3 ? nil : now.addingTimeInterval(-age))
    }
    let request = JevQuestions.buildRequest(
      query: "the pdf I just downloaded",
      context: .init(
        frontmostApp: "Finder", recentApps: [], clipboardKind: "empty",
        timeOfDay: "afternoon", weekday: "Saturday"),
      candidates: files, now: now)
    XCTAssertEqual(request.state.candidates.map { $0.recency?.newestRank }, [3, 1, 1, 1])
    XCTAssertEqual(
      request.state.candidates.map { $0.recency?.basis },
      [
        "added", "added", "added", "modified",
      ])
  }

  func testRepeatedWordsRetainTheirFuzzyWeightWithoutRepeatingMatchingWork() {
    let candidate = Candidate(
      id: "app", title: "Safari", subtitle: "Application", kind: .openApp,
      payload: .app(URL(fileURLWithPath: "/Applications/Safari.app")))
    let query = Fuzzy.Query(String(repeating: "Safari ", count: 400))
    XCTAssertEqual(query.weightedMeaningful.count, 1)
    XCTAssertEqual(query.weightedMeaningful.first?.count, 400)
    XCTAssertEqual(Fuzzy.score(query: query, candidate: candidate), 0.9, accuracy: 0.0001)
    XCTAssertEqual(
      Fuzzy.score(query: "Safari Safari unknown", candidate: candidate), 0.3, accuracy: 0.0001)
    XCTAssertEqual(
      Fuzzy.score(query: String(repeating: "a", count: 100_000), candidate: candidate), 0)
  }

  func testExactLocalFilenamePrecedesWebsiteInterpretation() {
    for name in ["Proposal.docx", "Budget.xlsx", "Archive.zip", "personal.site"] {
      let candidate = Candidate(
        id: name, title: name, subtitle: "Document", kind: .openFile,
        payload: .file(URL(fileURLWithPath: "/fixtures/\(name)")))
      let filtered = Ranker.prefilter(query: name, index: [candidate])
      XCTAssertEqual(Ranker.rank(filtered, judgment: nil).first?.id, candidate.id, name)
    }
  }

  func testCommonDocumentExtensionsDoNotCreateWebsiteCandidates() {
    for name in ["Proposal.docx", "Budget.xlsx", "Archive.zip", "Installer.dmg"] {
      let filtered = Ranker.prefilter(query: name, index: [])
      XCTAssertFalse(filtered.candidates.contains { $0.kind == .openURL }, name)
    }
    XCTAssertTrue(
      Ranker.prefilter(query: "https://personal.zip", index: []).candidates.contains {
        $0.kind == .openURL
      })
  }

  func testOnlineVisitEvidenceUsesTheSameAdvancingAgeAsRetrieval() {
    let now = Date(timeIntervalSince1970: 1_790_000_000)
    let candidate = Candidate(
      id: "visited", title: "Docs", subtitle: "example.com", kind: .openURL,
      payload: .url(URL(string: "https://example.com")!), ageDays: 0,
      visitedAt: now.addingTimeInterval(-3_600))
    let context = LaunchContext(
      frontmostApp: "Finder", recentApps: [], clipboardKind: "empty",
      timeOfDay: "afternoon", weekday: "Saturday")
    let request = JevQuestions.buildRequest(
      query: "last page visited", context: context, candidates: [candidate], now: now)
    XCTAssertEqual(request.state.candidates.first?.recency?.secondsAgo, 3_600)
    XCTAssertEqual(request.state.candidates.first?.recency?.basis, "visited")
  }

  func testIndexedHistoryExpiresFromRelativeWindows() {
    let now = Date(timeIntervalSince1970: 1_790_000_000)
    let entry = ChromeHistory.Entry(
      url: URL(string: "https://example.com")!, title: "Research article",
      lastVisit: now.addingTimeInterval(-120), visitCount: 1)
    let candidate = ChromeHistory.candidate(for: entry, now: now)
    XCTAssertEqual(candidate.visitedAt, entry.lastVisit)
    let later = now.addingTimeInterval(2 * 86_400)
    XCTAssertFalse(
      Ranker.prefilter(query: "links visited in the last hour", index: [candidate], now: later)
        .candidates.contains { $0.id == candidate.id })
  }
}
