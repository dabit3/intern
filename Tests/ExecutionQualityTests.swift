import Foundation
import XCTest

@testable import Intern

final class ExecutionQualityTests: XCTestCase {
  func testUnicodeOperatorsAndWhitespace() {
    for (expression, expected) in [
      ("2 − 1", 1.0), ("−3 × 4 ÷ 2", -6), ("2\t+\n3", 5),
      ("√(81) + 1", 10), ("+2 + +3", 5),
    ] {
      XCTAssertEqual(Calculator.evaluate(expression)?.value, expected, expression)
    }
  }

  func testScientificNotationAndImplicitMultiplication() {
    for (expression, expected) in [
      ("1e3 + 2", 1002.0), ("2.5E-3 * 4", 0.01), ("2(3+4)", 14),
      ("(2+3)(4+5)", 45), ("calc 42", 42), ("= 1e-8", 1e-8),
      ("1e3", 1000),
    ] {
      XCTAssertEqual(Calculator.evaluate(expression)?.value, expected, expression)
    }
  }

  func testPrecedenceAndPercentagesRemainConsistent() {
    for (expression, expected) in [
      ("-2^2", -4.0), ("(-2)^2", 4), ("2^3^2", 512), ("2^-2", 0.25),
      ("(20+30)% * 80", 40), ("15\tpercent\nof\t240", 36), ("sqrt ( 81 )", 9),
      ("3 / 2 * 4", 6), ("200+10%", 200.1), ("√81", 9),
    ] {
      XCTAssertEqual(Calculator.evaluate(expression)?.value, expected, expression)
    }
  }

  func testLongOrDeepExpressionsFailWithoutStackExhaustion() {
    for expression in [
      String(repeating: "(", count: 1000) + "1+1" + String(repeating: ")", count: 1000),
      String(repeating: "-", count: 1000) + "1",
      String(repeating: "1^", count: 1000) + "1",
      String(repeating: "1+", count: 100_000) + "1",
      String(repeating: "√", count: 1000) + "1",
    ] {
      XCTAssertNil(Calculator.evaluate(expression))
    }
    XCTAssertEqual(Calculator.evaluate(String(repeating: "1+", count: 1000) + "1")?.value, 1001)
  }

  func testRejectsMalformedNumbersAndNonfiniteIntermediateValues() {
    for expression in [
      "1 2 + 3", "1,2 + 3", "1,,000+2", "1,000,00+2", "1.2.3+4",
      "1e+ + 2", "1e309^0", "(10^1000)^0", "0/0", "sqrt(-1)", "2**3",
    ] {
      XCTAssertNil(Calculator.evaluate(expression), expression)
    }
    XCTAssertEqual(Calculator.evaluate("1,234.5 + 2,000")?.value, 3234.5)
  }

  func testFormattingPreservesTinyNonzeroResultsAndBoundsLargeResults() {
    let tiny = Calculator.format(0.00000001)
    XCTAssertEqual(Double(tiny), 0.00000001)
    let large = Calculator.format(Double.greatestFiniteMagnitude)
    XCTAssertLessThan(large.count, 30)
    XCTAssertTrue(Double(large)?.isFinite == true)
    XCTAssertEqual(Calculator.format(.infinity), "Undefined")
    XCTAssertEqual(Calculator.format(.nan), "Undefined")
    XCTAssertEqual(Calculator.format(-0.0), "0")
    XCTAssertEqual(
      Double(Calculator.format(Double.leastNonzeroMagnitude)), Double.leastNonzeroMagnitude)
  }

  func testRejectsInvalidLinkAuthorities() {
    for raw in [
      "https:///missing-host", "https://", "http://?query", "file:///tmp/note",
      "https://example.com:99999", "https://example.com:0",
    ] {
      let candidate = link(raw)
      XCTAssertNotNil(Executor.validationError(candidate), raw)
    }
  }

  func testCopyDoesNotFlattenInvalidOrEmptyGroups() {
    let valid = link("https://example.com")
    let conflict = Candidate(
      id: valid.id, title: "Conflict", subtitle: "", kind: .openURL,
      payload: .url(URL(string: "https://example.org")!))
    for members in [
      [], [valid, SystemToggle.sleep.candidate], [valid, conflict],
      Array(repeating: valid, count: 26),
    ] {
      XCTAssertNil(Executor.copyText(Ranker.groupCandidate(members)))
    }
    let nested = Ranker.groupCandidate([Ranker.groupCandidate([link("https://example.com")])])
    XCTAssertNil(Executor.copyText(nested))
  }

  func testCopyDeduplicatesRepeatedGroupTargets() {
    let first = link("https://example.com/path")
    let alias = Candidate(
      id: "alias", title: "Alias", subtitle: "", kind: .openURL, payload: first.payload)
    XCTAssertEqual(
      Executor.copyText(Ranker.groupCandidate([first, alias])), "https://example.com/path")
  }

  func testCommandDoesNotWaitForDescendantsHoldingPipeOpen() {
    let start = Date()
    XCTAssertEqual(Executor.run("/bin/sh", ["-c", "/bin/sleep 2 & printf done"]), "done")
    XCTAssertLessThan(Date().timeIntervalSince(start), 1)
  }

  func testCancelledTaskDoesNotStartCommand() async {
    let worker = Task.detached {
      withUnsafeCurrentTask { $0?.cancel() }
      return Executor.run("/usr/bin/printf", ["should not run"])
    }
    let output = await worker.value
    XCTAssertNil(output)
  }

  @MainActor
  func testLinksAndSearchUseTheRegisteredDefaultHandler() async throws {
    let handler = URL(fileURLWithPath: "/fixture/DefaultBrowser.app")
    var resolved: [URL] = []
    var opened: [[URL]] = []
    var environment = Executor.Environment()
    environment.application = {
      resolved.append($0)
      return handler
    }
    environment.openURLs = { urls, application in
      XCTAssertEqual(application, handler)
      opened.append(urls)
      return Executor.Outcome(succeeded: true, message: "Opened")
    }
    let target = link("https://example.com")
    let linkOutcome = await Executor.perform(target, using: environment)
    XCTAssertTrue(linkOutcome.succeeded)
    let query = "swift & mac + \"你好\" # docs"
    let search = Candidate(
      id: "search", title: "Search", subtitle: "", kind: .webSearch, payload: .webSearch(query))
    let searchOutcome = await Executor.perform(search, using: environment)
    XCTAssertTrue(searchOutcome.succeeded)
    XCTAssertEqual(resolved.count, 2)
    XCTAssertEqual(opened.count, 2)
    let searchURL = try XCTUnwrap(opened.last?.first)
    XCTAssertEqual(
      URLComponents(url: searchURL, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, query
    )
  }

  @MainActor
  func testMixedURLGroupDeduplicatesAndUsesEachSchemesHandler() async {
    let http = URL(fileURLWithPath: "/fixture/HTTPBrowser.app")
    let https = URL(fileURLWithPath: "/fixture/HTTPSBrowser.app")
    let first = link("https://example.com/one")
    let duplicate = Candidate(
      id: "alias", title: "Alias", subtitle: "", kind: .openURL, payload: first.payload)
    var opened: [(URL, [URL])] = []
    var environment = Executor.Environment()
    environment.application = { $0.scheme == "http" ? http : https }
    environment.openURLs = { urls, application in
      opened.append((application, urls))
      return Executor.Outcome(succeeded: true, message: "Opened")
    }
    let result = await Executor.perform(
      Ranker.groupCandidate([
        first, link("http://example.com/two"), duplicate, link("https://example.com/three"),
      ]), using: environment)
    XCTAssertTrue(result.succeeded)
    XCTAssertEqual(result.message, "Opened 3 items")
    XCTAssertEqual(opened.map(\.0), [https, http])
    XCTAssertEqual(opened.map { $0.1.count }, [2, 1])
  }

  @MainActor
  func testInvalidWorkspaceOrMissingHandlerOpensNothing() async {
    var environment = Executor.Environment()
    environment.application = { _ in nil }
    environment.openURLs = { _, _ in
      XCTFail("An invalid group must not open anything")
      return Executor.Outcome(succeeded: true, message: "Opened")
    }
    environment.openApplication = { _ in
      XCTFail("An invalid group must not launch applications")
      return Executor.Outcome(succeeded: true, message: "Opened")
    }
    let valid = link("https://example.com")
    let conflict = Candidate(
      id: valid.id, title: "Conflict", subtitle: "", kind: .openURL,
      payload: .url(URL(string: "https://example.org")!))
    for members in [
      [], [valid, link("https://")], [valid, SystemToggle.sleep.candidate],
      [valid, Ranker.groupCandidate([valid])], [valid, conflict], [valid],
      Array(repeating: valid, count: 26),
    ] {
      let result = await Executor.perform(Ranker.groupCandidate(members), using: environment)
      XCTAssertFalse(result.succeeded)
    }
  }

  @MainActor
  func testWorkspaceReportsOpenFailuresAndCancellationStopsLaterMembers() async {
    var environment = Executor.Environment()
    environment.application = { url in URL(fileURLWithPath: "/fixture/\(url.scheme!).app") }
    environment.openURLs = { _, _ in
      Executor.Outcome(succeeded: false, message: "Fixture OS error")
    }
    let group = Ranker.groupCandidate([link("http://example.com"), link("https://example.org")])
    let failure = await Executor.perform(group, using: environment)
    XCTAssertFalse(failure.succeeded)
    XCTAssertTrue(failure.message.contains("Fixture OS error"))
    var opens = 0
    environment.openURLs = { _, _ in
      opens += 1
      withUnsafeCurrentTask { $0?.cancel() }
      return Executor.Outcome(succeeded: true, message: "Opened")
    }
    let worker = Task { await Executor.perform(group, using: environment) }
    let cancelled = await worker.value
    XCTAssertFalse(cancelled.succeeded)
    XCTAssertEqual(opens, 1)
  }

  @MainActor
  func testFileAndApplicationRoutingUsesSafeFixtures() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appendingPathComponent("notes.txt")
    try Data("Fixture".utf8).write(to: file)
    let document = Candidate(
      id: "document", title: "Notes", subtitle: "", kind: .openFile, payload: .file(file))
    let impostor = Candidate(
      id: "impostor", title: "Not an app", subtitle: "", kind: .openApp, payload: .app(file))
    XCTAssertNil(Executor.validationError(document))
    XCTAssertNotNil(Executor.validationError(impostor))
    let application = URL(fileURLWithPath: "/System/Applications/TextEdit.app")
    let app = Candidate(
      id: "application", title: "TextEdit", subtitle: "", kind: .openApp, payload: .app(application)
    )
    XCTAssertNil(Executor.validationError(app))
    var files: [URL] = []
    var apps: [URL] = []
    var environment = Executor.Environment()
    environment.application = { _ in application }
    environment.openURLs = { urls, handler in
      XCTAssertEqual(handler, application)
      files += urls
      return Executor.Outcome(succeeded: true, message: "Opened")
    }
    environment.openApplication = {
      apps.append($0)
      return Executor.Outcome(succeeded: true, message: "Opened")
    }
    let opened = await Executor.perform(Ranker.groupCandidate([document, app]), using: environment)
    XCTAssertTrue(opened.succeeded)
    XCTAssertEqual(files, [file])
    XCTAssertEqual(apps, [application])
    try FileManager.default.removeItem(at: file)
    let missing = await Executor.perform(
      Ranker.groupCandidate([app, document]), using: environment)
    XCTAssertFalse(missing.succeeded)
    XCTAssertEqual(apps.count, 1, "Preflight must fail before opening the first valid app")
  }

  @MainActor
  func testCalculationCopyReportsPasteboardFailure() async {
    let calculation = Candidate(
      id: "calc", title: "1e-8", subtitle: "", kind: .calculate,
      payload: .calculation(expression: "1/100000000", result: "1e-8"))
    var environment = Executor.Environment()
    environment.copy = {
      XCTAssertEqual($0, "1e-8")
      return false
    }
    let result = await Executor.perform(calculation, using: environment)
    XCTAssertFalse(result.succeeded)
    XCTAssertEqual(result.message, "Could not copy result.")
  }

  func testPipesDrainBothStreamsWithoutDeadlock() {
    let result = Executor.runProcess(
      "/bin/sh",
      [
        "-c",
        "i=0; while [ $i -lt 20000 ]; do printf 'stdout line\\n'; printf 'stderr line\\n' >&2; i=$((i+1)); done",
      ],
      timeout: 10)
    XCTAssertNil(result.error)
    XCTAssertEqual(result.output?.count, 240_000)
  }

  func testTimeoutKillsAProcessThatIgnoresTermination() {
    let start = Date()
    let result = Executor.runProcess(
      "/bin/sh", ["-c", "trap '' TERM; while :; do :; done"], timeout: 0.15)
    XCTAssertNil(result.output)
    XCTAssertEqual(result.error, "The action timed out.")
    XCTAssertLessThan(Date().timeIntervalSince(start), 2)
  }

  func testCancellationStopsAnAlreadyRunningCommand() async throws {
    let start = Date()
    let worker = Task.detached {
      Executor.runProcess("/bin/sh", ["-c", "trap '' TERM; while :; do :; done"], timeout: 5)
    }
    try await Task.sleep(for: .milliseconds(150))
    worker.cancel()
    let result = await worker.value
    XCTAssertNil(result.output)
    XCTAssertEqual(result.error, "Action cancelled.")
    XCTAssertLessThan(Date().timeIntervalSince(start), 2)
  }

  func testAsyncCommandWrapperForwardsCancellation() async throws {
    let worker = Task {
      await Executor.inBackground {
        Executor.command("/bin/sleep", ["5"], success: "Wrong")
      }
    }
    try await Task.sleep(for: .milliseconds(150))
    let start = Date()
    worker.cancel()
    let result = await worker.value
    XCTAssertFalse(result.succeeded)
    XCTAssertEqual(result.message, "Action cancelled.")
    XCTAssertLessThan(Date().timeIntervalSince(start), 2)
  }

  func testCommandFailuresPreserveDiagnosticsAndExitStatus() {
    let diagnostic = Executor.command(
      "/bin/sh", ["-c", "printf 'Fixture permission denied' >&2; exit 7"], success: "Wrong")
    XCTAssertFalse(diagnostic.succeeded)
    XCTAssertEqual(diagnostic.message, "Fixture permission denied")
    let status = Executor.runProcess("/bin/sh", ["-c", "exit 23"])
    XCTAssertEqual(status.error, "The action exited with status 23.")
    let launch = Executor.runProcess("/not-a-real-executable-\(UUID())", [])
    XCTAssertNil(launch.output)
    XCTAssertNotNil(launch.error)
    let unreadable = Executor.runProcess("/usr/bin/printf", ["\\377"])
    XCTAssertNil(unreadable.output)
    XCTAssertEqual(unreadable.error, "The action returned unreadable output.")
  }

  func testCommandClosesInputAndBoundsOutput() {
    XCTAssertEqual(Executor.run("/bin/cat", []), "")
    let result = Executor.runProcess("/usr/bin/yes", [], timeout: 3)
    XCTAssertNil(result.output)
    XCTAssertEqual(result.error, "The action produced too much output.")
  }

  private func link(_ raw: String) -> Candidate {
    Candidate(
      id: raw, title: raw, subtitle: "", kind: .openURL, payload: .url(URL(string: raw)!))
  }
}
