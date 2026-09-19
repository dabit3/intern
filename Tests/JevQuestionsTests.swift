import XCTest

@testable import Launcher

final class JevQuestionsTests: XCTestCase {
  let context = LaunchContext(
    frontmostApp: "Finder", recentApps: ["Safari", "Xcode"], clipboardKind: "text",
    timeOfDay: "afternoon", weekday: "Thursday")

  func testRequestIsOneFanOutWithThreeQuestions() throws {
    let request = JevQuestions.buildRequest(
      query: "wifi off", context: context, candidates: [Fixtures.wifiOff, Fixtures.wifiOn])
    XCTAssertEqual(request.model, "jev-latest")
    XCTAssertEqual(
      Set(request.questions.keys),
      ["target", "action", "ready", "scope", "match_c0", "match_c1"])
    XCTAssertEqual(request.questions["target"]?.type, "choice")
    XCTAssertEqual(request.questions["action"]?.type, "choice")
    XCTAssertEqual(request.questions["ready"]?.type, "noul")
    XCTAssertEqual(request.questions["scope"]?.type, "choice")
    XCTAssertEqual(request.questions["match_c0"]?.type, "noul")

    let json =
      try JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any]
    let state = json?["state"] as? [String: Any]
    XCTAssertEqual(state?["query"] as? String, "wifi off")
    let candidates = state?["candidates"] as? [[String: Any]]
    XCTAssertEqual(candidates?.map { $0["id"] as? String }, ["c0", "c1"])
    let ctx = state?["context"] as? [String: Any]
    XCTAssertEqual(ctx?["frontmost_app"] as? String, "Finder")
    XCTAssertEqual(ctx?["clipboard_kind"] as? String, "text")

    let questions = json?["questions"] as? [String: Any]
    let target = questions?["target"] as? [String: Any]
    let criteria = target?["criteria"] as? [String: String]
    XCTAssertEqual(Set(criteria?.keys.map { $0 } ?? []), ["c0", "c1", JevQuestions.noneOption])
    let action = questions?["action"] as? [String: Any]
    XCTAssertEqual(
      Set((action?["criteria"] as? [String: String])?.keys.map { $0 } ?? []),
      Set(ActionKind.allCases.map(\.rawValue)))
    let ready = questions?["ready"] as? [String: Any]
    XCTAssertEqual(
      Set((ready?["criteria"] as? [String: String])?.keys.map { $0 } ?? []), ["true", "false"])
  }

  func testRequestNeverSendsMoreThanMaxCandidates() {
    let many = (0..<40).map { i in
      Candidate(
        id: "app:\(i)", title: "App \(i)", subtitle: "Application", kind: .openApp,
        payload: .app(URL(fileURLWithPath: "/Applications/App\(i).app")))
    }
    let request = JevQuestions.buildRequest(query: "app", context: context, candidates: many)
    XCTAssertEqual(request.state.candidates.count, JevQuestions.maxCandidates)
  }

  func testParseMapsShortIdsBackToCandidates() throws {
    let raw = """
      {"model":"jev-1.13.0","answers":{
        "target":{"type":"choice","choice":"c1","confidence":0.7,
                  "probabilities":{"none":0.05,"c0":0.1,"c1":0.85}},
        "action":{"type":"choice","choice":"system_toggle","confidence":0.8,
                  "probabilities":{"system_toggle":0.9,"web_search":0.1}},
        "ready":{"type":"noul","noul":0.66}},
       "usage":{"input_tokens":700,"output_tokens":120}}
      """
    let response = try JSONDecoder().decode(JevResponse.self, from: Data(raw.utf8))
    let judgment = JevQuestions.parse(response, candidates: [Fixtures.wifiOff, Fixtures.wifiOn])
    XCTAssertEqual(judgment?.targetProbabilities[Fixtures.wifiOn.id], 0.85)
    XCTAssertEqual(judgment?.targetProbabilities[Fixtures.wifiOff.id], 0.1)
    XCTAssertEqual(judgment?.noneProbability, 0.05)
    XCTAssertEqual(judgment?.action, .systemToggle)
    XCTAssertEqual(judgment?.actionProbabilities[.webSearch], 0.1)
    XCTAssertEqual(judgment?.ready, 0.66)
    XCTAssertEqual(response.usage.inputTokens, 700)
  }

  func testParseToleratesMissingAnswers() throws {
    let raw = """
      {"model":"jev-1.13.0","answers":{
        "target":{"type":"choice","choice":"none","confidence":0.4,"probabilities":{"none":0.6,"c0":0.4}}},
       "usage":{"input_tokens":10,"output_tokens":1}}
      """
    let response = try JSONDecoder().decode(JevResponse.self, from: Data(raw.utf8))
    let judgment = JevQuestions.parse(response, candidates: [Fixtures.sleep])
    XCTAssertEqual(judgment?.action, .unclear)
    XCTAssertEqual(judgment?.ready, 0)
    XCTAssertEqual(judgment?.targetProbabilities[Fixtures.sleep.id], 0.4)
  }

  func testParseReturnsNilWithoutTargetAnswer() throws {
    let raw = """
      {"model":"jev-1.13.0","answers":{"ready":{"type":"noul","noul":0.2}},
       "usage":{"input_tokens":10,"output_tokens":1}}
      """
    let response = try JSONDecoder().decode(JevResponse.self, from: Data(raw.utf8))
    XCTAssertNil(JevQuestions.parse(response, candidates: [Fixtures.sleep]))
  }

  func testTimeOfDayBuckets() {
    XCTAssertEqual(LaunchContext.timeOfDay(hour: 6), "morning")
    XCTAssertEqual(LaunchContext.timeOfDay(hour: 13), "afternoon")
    XCTAssertEqual(LaunchContext.timeOfDay(hour: 19), "evening")
    XCTAssertEqual(LaunchContext.timeOfDay(hour: 2), "night")
  }
}
