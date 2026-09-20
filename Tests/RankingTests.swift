import XCTest

@testable import Intern

enum Fixtures {
  static let darkMode = Candidate(
    id: "toggle:dark", title: "Toggle Dark Mode",
    subtitle: "Switch appearance between light and dark",
    kind: .systemToggle, keywords: ["dark", "appearance", "theme"],
    payload: .toggle(.toggleDarkMode))
  static let wifiOff = Candidate(
    id: "toggle:wifioff", title: "Turn Wi-Fi Off", subtitle: "Disable the Wi-Fi radio",
    kind: .systemToggle, keywords: ["wifi", "off"], payload: .toggle(.wifiOff))
  static let wifiOn = Candidate(
    id: "toggle:wifion", title: "Turn Wi-Fi On", subtitle: "Enable the Wi-Fi radio",
    kind: .systemToggle, keywords: ["wifi", "on"], payload: .toggle(.wifiOn))
  static let sleep = Candidate(
    id: "toggle:sleep", title: "Sleep", subtitle: "Put the Mac to sleep now", kind: .systemToggle,
    payload: .toggle(.sleep))
  static let safari = Candidate(
    id: "app:safari", title: "Safari", subtitle: "Application", kind: .openApp,
    payload: .app(URL(fileURLWithPath: "/Applications/Safari.app")))
  static let slack = Candidate(
    id: "app:slack", title: "Slack", subtitle: "Application", kind: .openApp,
    payload: .app(URL(fileURLWithPath: "/Applications/Slack.app")))
  static let roadmap = Candidate(
    id: "file:roadmap", title: "Q3-Roadmap-Review.pdf",
    subtitle: "PDF in ~/Downloads · modified just now",
    kind: .openFile, keywords: ["downloads", "downloaded", "pdf", "recent"],
    payload: .file(URL(fileURLWithPath: "/tmp/Q3-Roadmap-Review.pdf")), ageDays: 0.001)
  static let invoice = Candidate(
    id: "file:invoice", title: "invoice-2026-08.pdf",
    subtitle: "PDF in ~/Downloads · modified 1 month ago",
    kind: .openFile, keywords: ["downloads", "downloaded", "pdf"],
    payload: .file(URL(fileURLWithPath: "/tmp/invoice-2026-08.pdf")), ageDays: 31)

  static let index = [darkMode, wifiOff, wifiOn, sleep, safari, slack, roadmap, invoice]
}

final class FuzzyTests: XCTestCase {
  func testExactAndPrefixBeatSubsequence() {
    let exact = Fuzzy.score(query: "sleep", candidate: Fixtures.sleep)
    let prefix = Fuzzy.score(query: "sle", candidate: Fixtures.sleep)
    let subsequence = Fuzzy.score(query: "slp", candidate: Fixtures.sleep)
    XCTAssertGreaterThan(exact, prefix)
    XCTAssertGreaterThan(prefix, subsequence)
    XCTAssertGreaterThan(subsequence, 0)
  }

  func testUnrelatedScoresZero() {
    XCTAssertEqual(Fuzzy.score(query: "zzz", candidate: Fixtures.safari), 0)
  }

  func testStopwordsAreIgnored() {
    let withStopwords = Fuzzy.score(query: "the pdf I just downloaded", candidate: Fixtures.roadmap)
    let bare = Fuzzy.score(query: "pdf downloaded", candidate: Fixtures.roadmap)
    XCTAssertGreaterThan(withStopwords, 0)
    XCTAssertEqual(withStopwords, bare, accuracy: 0.05)
  }

  func testInitialsMatch() {
    XCTAssertGreaterThan(Fuzzy.score(query: "tdm", candidate: Fixtures.darkMode), 0)
  }

  func testSubsequenceContiguity() {
    XCTAssertEqual(Fuzzy.subsequenceContiguity("abc", in: "abc"), 1)
    XCTAssertNil(Fuzzy.subsequenceContiguity("abd", in: "abc"))
    XCTAssertEqual(Fuzzy.subsequenceContiguity("ac", in: "abbbbc"), 0)
    XCTAssertEqual(Fuzzy.subsequenceContiguity("abc", in: "abxc"), 0.5)
  }
}

final class RankerTests: XCTestCase {
  func testPrefilterAddsWebSearchLastAndCalculationFirst() {
    let plain = Ranker.prefilter(query: "dark", index: Fixtures.index)
    XCTAssertEqual(plain.candidates.first?.id, Fixtures.darkMode.id)
    XCTAssertEqual(plain.candidates.last?.id, Ranker.webSearchID)
    XCTAssertFalse(plain.candidates.contains { $0.id == Ranker.calculationID })

    let math = Ranker.prefilter(query: "calc 15% of 240", index: Fixtures.index)
    XCTAssertEqual(math.candidates.first?.id, Ranker.calculationID)
    XCTAssertEqual(math.candidates.first?.title, "= 36")
  }

  func testPrefilterCapsAtLimitPlusSynthetic() {
    let many = (0..<50).map { i in
      Candidate(
        id: "app:\(i)", title: "Note \(i)", subtitle: "Application", kind: .openApp,
        payload: .app(URL(fileURLWithPath: "/Applications/Note\(i).app")))
    }
    let result = Ranker.prefilter(query: "note", index: many)
    XCTAssertEqual(result.candidates.count, Ranker.prefilterLimit + 1)
    XCTAssertLessThanOrEqual(result.candidates.count, JevQuestions.maxCandidates)
  }

  func testEmptyQueryYieldsNothing() {
    XCTAssertTrue(Ranker.prefilter(query: "   ", index: Fixtures.index).candidates.isEmpty)
  }

  func testWithoutJudgmentOrderIsFuzzy() {
    let prefiltered = Ranker.prefilter(query: "wifi", index: Fixtures.index)
    let hits = Ranker.rank(prefiltered, judgment: nil)
    XCTAssertEqual(hits.map(\.score), hits.map(\.fuzzy))
    XCTAssertTrue(hits.allSatisfy { $0.jevProbability == nil })
    XCTAssertEqual(hits.map(\.score), hits.map(\.score).sorted(by: >))
  }

  func testJudgmentReordersAmbiguousQuery() {
    let prefiltered = Ranker.prefilter(query: "wifi", index: Fixtures.index)
    let judgment = JevJudgment(
      targetProbabilities: [Fixtures.wifiOff.id: 0.1, Fixtures.wifiOn.id: 0.85],
      noneProbability: 0.05, targetConfidence: 0.75, action: .systemToggle,
      actionProbabilities: [.systemToggle: 0.9, .webSearch: 0.1], actionConfidence: 0.8, ready: 0.7)
    let hits = Ranker.rank(prefiltered, judgment: judgment)
    XCTAssertEqual(hits.first?.id, Fixtures.wifiOn.id)
    XCTAssertEqual(hits.first?.jevProbability, 0.85)
    let expected =
      Ranker.targetWeight * 0.85 + Ranker.actionWeight * 0.9
      + Ranker.fuzzyWeight * (prefiltered.fuzzy[Fixtures.wifiOn.id] ?? 0)
    XCTAssertEqual(hits.first?.score ?? 0, expected, accuracy: 1e-9)
  }
}
