import XCTest

@testable import Intern

private actor JudgmentQueue {
  struct Pending {
    let request: JevRequest
    let continuation: CheckedContinuation<JevClient.Result, Error>
  }

  private var pending: [Pending] = []

  func ask(_ request: JevRequest) async throws -> JevClient.Result {
    try await withCheckedThrowingContinuation {
      pending.append(Pending(request: request, continuation: $0))
    }
  }

  var count: Int { pending.count }

  func finish(_ index: Int, title: String) {
    guard pending.indices.contains(index) else { return }
    let pending = pending.remove(at: index)
    let shortID =
      pending.request.state.candidates.first { $0.title == title }?.id ?? "none"
    let response = JevResponse(
      model: "test",
      answers: [
        "target": .init(
          type: "choice", choice: shortID, confidence: 1,
          probabilities: [shortID: 1], noul: nil),
        "ready": .init(
          type: "noul", choice: nil, confidence: nil, probabilities: nil, noul: 1),
      ], usage: .init(inputTokens: 10, outputTokens: 0))
    pending.continuation.resume(returning: .init(response: response, latencyMs: 10))
  }

  func finishMalformed() {
    guard !pending.isEmpty else { return }
    pending.removeFirst().continuation.resume(
      returning: .init(
        response: .init(
          model: "test", answers: [:], usage: .init(inputTokens: 10, outputTokens: 0)),
        latencyMs: 10))
  }

  func fail(_ failure: JevClient.Failure) {
    guard !pending.isEmpty else { return }
    pending.removeFirst().continuation.resume(throwing: failure)
  }
}

@MainActor
final class StateQualityTests: XCTestCase {
  private func defaults() throws -> (UserDefaults, String) {
    let suite = "StateQualityTests.\(UUID())"
    return (try XCTUnwrap(UserDefaults(suiteName: suite)), suite)
  }

  private func waitUntil(_ condition: () async -> Bool) async {
    for _ in 0..<100 {
      if await condition() { return }
      try? await Task.sleep(for: .milliseconds(10))
    }
    XCTFail("Timed out waiting for test state")
  }

  func testFreshIndexMetadataWinsOverPersistedCandidateMetadata() throws {
    let (defaults, suite) = try defaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(true, forKey: "localOnly")
    defaults.set(false, forKey: "includeSpotlight")
    let url = URL(string: "https://example.com/article")!
    let stale = Candidate(
      id: "url:\(url.absoluteString)", title: "Old title", subtitle: "visited 1 month ago",
      kind: .openURL, keywords: ["example"], payload: .url(url), ageDays: 30)
    let fresh = Candidate(
      id: stale.id, title: "Current title", subtitle: "visited just now",
      kind: .openURL, keywords: ["example"], payload: .url(url), ageDays: 0)
    PersonalLibrary(defaults: defaults).record(stale, query: "example")

    let model = InternModel(defaults: defaults)
    model.replaceIndex([fresh])
    model.query = "example"

    XCTAssertEqual(model.hits.first { $0.id == fresh.id }?.candidate, fresh)
  }

  func testDisablingHistoryHidesOrdinaryLinksButKeepsExplicitPinsAndWorkspaces() throws {
    let (defaults, suite) = try defaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(true, forKey: "localOnly")
    defaults.set(false, forKey: "includeSpotlight")
    let link = Candidate(
      id: "url:example", title: "Example", subtitle: "example.com", kind: .openURL,
      payload: .url(URL(string: "https://example.com")!))
    let library = PersonalLibrary(defaults: defaults)
    library.record(link, query: "example")
    let pinned = Candidate(
      id: "url:pinned", title: "Pinned example", subtitle: "pinned.example.com", kind: .openURL,
      payload: .url(URL(string: "https://pinned.example.com")!))
    library.togglePin(pinned)
    XCTAssertTrue(library.saveWorkspace(name: "Links", members: [link, Fixtures.safari]))
    let workspaceID = try XCTUnwrap(library.snapshot.workspaces.first?.id)
    let model = InternModel(defaults: defaults)
    model.replaceIndex([link])

    defaults.set(false, forKey: "includeChromeHistory")
    model.preferencesChanged()
    model.query = "example"

    XCTAssertFalse(model.hits.contains { $0.id == link.id })
    XCTAssertTrue(model.hits.contains { $0.id == pinned.id })
    model.scope = .workspaces
    model.query = "Links"
    XCTAssertTrue(model.hits.contains { $0.id == workspaceID })
  }

  func testDeletingWorkspaceEvictsEveryCachedCopy() throws {
    let (defaults, suite) = try defaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(true, forKey: "localOnly")
    defaults.set(false, forKey: "includeSpotlight")
    let library = PersonalLibrary(defaults: defaults)
    XCTAssertTrue(
      library.saveWorkspace(name: "Research", members: [Fixtures.safari, Fixtures.roadmap]))
    let workspace = try XCTUnwrap(library.snapshot.workspaces.first)
    let model = InternModel(defaults: defaults)
    model.replaceIndex([workspace.candidate])
    model.query = "Research"
    XCTAssertEqual(model.topHit?.id, workspace.id)

    model.deleteWorkspace()

    XCTAssertFalse(model.hits.contains { $0.id == workspace.id })
    XCTAssertFalse(
      PersonalLibrary(defaults: defaults).snapshot.workspaces.contains { $0.id == workspace.id })
  }

  func testAPIKeyChangeCancelsAndReissuesCurrentJudgment() async throws {
    let (defaults, suite) = try defaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(false, forKey: "includeSpotlight")
    let queue = JudgmentQueue()
    let model = InternModel(defaults: defaults, ask: { try await queue.ask($0) })
    model.replaceIndex(Fixtures.index)
    model.query = "dark"
    await waitUntil { await queue.count == 1 }

    defaults.set("replacement-key", forKey: JevClient.apiKeyDefaultsKey)
    model.preferencesChanged()
    await waitUntil { await queue.count == 2 }

    await queue.finish(0, title: Fixtures.darkMode.title)
    await waitUntil { model.stats.staleDiscarded == 1 }
    XCTAssertNil(model.judgment)
    await queue.finish(0, title: Fixtures.darkMode.title)
    await waitUntil { model.judgmentIsFresh }
    XCTAssertEqual(model.stats.requests, 1)
  }

  func testStaleSuccessDoesNotPolluteLatencyOrTokenStatistics() async throws {
    let (defaults, suite) = try defaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(false, forKey: "includeSpotlight")
    let queue = JudgmentQueue()
    let model = InternModel(defaults: defaults, ask: { try await queue.ask($0) })
    model.replaceIndex(Fixtures.index)
    model.query = "dark"
    await waitUntil { await queue.count == 1 }
    model.replaceIndex(Fixtures.index + [Fixtures.invoice])
    await waitUntil { await queue.count == 2 }

    await queue.finish(0, title: Fixtures.darkMode.title)
    await waitUntil { model.stats.staleDiscarded == 1 }
    XCTAssertEqual(model.stats.requests, 0)
    XCTAssertEqual(model.stats.inputTokens, 0)
    await queue.finish(0, title: Fixtures.darkMode.title)
    await waitUntil { model.judgmentIsFresh }
    XCTAssertEqual(model.stats.requests, 1)
    XCTAssertEqual(model.stats.inputTokens, 10)
  }

  func testResetClearsEditorAndAllowsNewExecutionBeforeOldCompletion() async throws {
    let (defaults, suite) = try defaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(true, forKey: "localOnly")
    defaults.set(false, forKey: "includeSpotlight")
    var completions: [CheckedContinuation<Executor.Outcome, Never>] = []
    var executed: [String] = []
    let model = InternModel(
      defaults: defaults,
      execute: { candidate in
        executed.append(candidate.id)
        return await withCheckedContinuation { completions.append($0) }
      })
    model.replaceIndex([Fixtures.safari, Fixtures.slack])
    model.query = "safari"
    model.executeSelection()
    await waitUntil { completions.count == 1 }
    model.workspaceName = "unfinished"
    model.savingWorkspace = true

    model.reset()
    XCTAssertFalse(model.isExecuting)
    XCTAssertFalse(model.savingWorkspace)
    XCTAssertEqual(model.workspaceName, "")
    model.replaceIndex([Fixtures.safari, Fixtures.slack])
    model.query = "slack"
    model.executeSelection()
    await waitUntil { completions.count == 2 }
    guard completions.count == 2 else {
      for completion in completions {
        completion.resume(returning: .init(succeeded: false, message: "Test cleanup"))
      }
      return
    }
    completions[0].resume(returning: .init(succeeded: true, message: "Opened Safari"))
    await Task.yield()
    XCTAssertTrue(model.isExecuting)
    completions[1].resume(returning: .init(succeeded: true, message: "Opened Slack"))
    await waitUntil { !model.isExecuting }
    XCTAssertEqual(executed, [Fixtures.safari.id, Fixtures.slack.id])
  }

  func testMissingFileRevealReportsValidationFailure() throws {
    let (defaults, suite) = try defaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(true, forKey: "localOnly")
    defaults.set(false, forKey: "includeSpotlight")
    let missing = Candidate(
      id: "file:missing", title: "Missing.pdf", subtitle: "PDF", kind: .openFile,
      payload: .file(URL(fileURLWithPath: "/missing-\(UUID()).pdf")))
    let model = InternModel(defaults: defaults)
    model.replaceIndex([missing])
    model.query = "missing"
    model.revealSelection()
    XCTAssertNotNil(model.lastError)
  }

  func testFailedMissingFileExecutionClearsReadinessAndEvictsTheRow() async throws {
    let (defaults, suite) = try defaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(false, forKey: "includeSpotlight")
    let missing = Candidate(
      id: "file:missing", title: "Missing.pdf", subtitle: "PDF", kind: .openFile,
      payload: .file(URL(fileURLWithPath: "/missing-\(UUID()).pdf")))
    let queue = JudgmentQueue()
    let model = InternModel(
      defaults: defaults,
      execute: { _ in .init(succeeded: false, message: "Missing file") },
      ask: { try await queue.ask($0) })
    model.replaceIndex([missing])
    model.query = "missing"
    await waitUntil { await queue.count == 1 }
    await queue.finish(0, title: missing.title)
    await waitUntil { model.isReady }

    model.executeSelection()
    await waitUntil { model.lastError != nil }

    XCTAssertFalse(model.isReady)
    XCTAssertNil(model.judgment)
    XCTAssertFalse(model.hits.contains { $0.id == missing.id })
  }

  func testRecoverableExecutionFailureClearsReadinessButKeepsRetryAvailable() async throws {
    let (defaults, suite) = try defaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(false, forKey: "includeSpotlight")
    let link = Candidate(
      id: "url:example", title: "Example", subtitle: "example.com", kind: .openURL,
      payload: .url(URL(string: "https://example.com")!))
    let queue = JudgmentQueue()
    var attempts = 0
    let model = InternModel(
      defaults: defaults,
      execute: { _ in
        attempts += 1
        return .init(succeeded: attempts > 1, message: "Browser temporarily unavailable")
      },
      ask: { try await queue.ask($0) })
    model.replaceIndex([link])
    model.query = "example"
    await waitUntil { await queue.count == 1 }
    await queue.finish(0, title: link.title)
    await waitUntil { model.isReady }

    model.executeSelection()
    await waitUntil { model.lastError != nil }
    XCTAssertFalse(model.isReady)
    XCTAssertTrue(model.hits.contains { $0.id == link.id })
    model.executeSelection()
    await waitUntil { attempts == 2 && !model.isExecuting }
    XCTAssertNil(model.lastError)
  }

  func testReplacingIndexClearsOldConfidenceWhileNewJudgmentIsPending() async throws {
    let (defaults, suite) = try defaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(false, forKey: "includeSpotlight")
    let queue = JudgmentQueue()
    let model = InternModel(defaults: defaults, ask: { try await queue.ask($0) })
    model.replaceIndex(Fixtures.index)
    model.query = "dark"
    await waitUntil { await queue.count == 1 }
    await queue.finish(0, title: Fixtures.darkMode.title)
    await waitUntil { model.judgmentIsFresh }

    model.replaceIndex(Fixtures.index + [Fixtures.invoice])

    XCTAssertNil(model.judgment)
    XCTAssertFalse(model.isReady)
    XCTAssertTrue(model.hits.allSatisfy { $0.jevProbability == nil })
    await waitUntil { await queue.count == 1 }
    await queue.finish(0, title: Fixtures.darkMode.title)
    await waitUntil { model.judgmentIsFresh }
  }

  func testMalformedRefreshKeepsLocalOrderingAndClearsOnlineConfidence() async throws {
    let (defaults, suite) = try defaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(false, forKey: "includeSpotlight")
    let queue = JudgmentQueue()
    let model = InternModel(defaults: defaults, ask: { try await queue.ask($0) })
    model.replaceIndex(Fixtures.index)
    model.query = "wifi"
    let localOrder = model.hits.map(\.id)
    await waitUntil { await queue.count == 1 }
    await queue.finish(0, title: Fixtures.wifiOff.title)
    await waitUntil { model.judgmentIsFresh }
    model.replaceIndex(Fixtures.index)
    await waitUntil { await queue.count == 1 }

    await queue.finishMalformed()
    await waitUntil { model.inFlight == 0 }

    XCTAssertNil(model.judgment)
    XCTAssertFalse(model.isReady)
    XCTAssertEqual(model.hits.map(\.id), localOrder)
    XCTAssertTrue(model.lastError?.contains("Local results") == true)
  }

  func testOversizedUTF8QueryNeverRequestsOnlineRanking() async throws {
    let (defaults, suite) = try defaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(false, forKey: "includeSpotlight")
    let queue = JudgmentQueue()
    let model = InternModel(defaults: defaults, ask: { try await queue.ask($0) })
    model.replaceIndex(Fixtures.index)
    model.query = String(repeating: "é", count: 1_025)
    await Task.yield()

    let requests = await queue.count
    XCTAssertEqual(requests, 0)
    XCTAssertEqual(model.inFlight, 0)
    XCTAssertEqual(
      model.lastError, "Query is too long for online ranking. Local results are available.")
    XCTAssertTrue(model.hits.contains { $0.id == Ranker.webSearchID })
    await queue.finishMalformed()
  }

  func testPendingRankingDoesNotKeepReleasedModelAlive() async throws {
    let (defaults, suite) = try defaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(false, forKey: "includeSpotlight")
    let queue = JudgmentQueue()
    var model: InternModel? = InternModel(defaults: defaults, ask: { try await queue.ask($0) })
    weak var weakModel = model
    model?.replaceIndex(Fixtures.index)
    model?.query = "dark"
    await waitUntil { await queue.count == 1 }

    model = nil

    XCTAssertNil(weakModel)
    weakModel = nil
    await queue.finish(0, title: Fixtures.darkMode.title)
  }

  func testFreshFileMetadataPreservesLauncherLastOpenedEvidence() throws {
    let (defaults, suite) = try defaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(true, forKey: "localOnly")
    defaults.set(false, forKey: "includeSpotlight")
    let file = Candidate(
      id: "file:report", title: "Fresh report.pdf", subtitle: "Fresh metadata", kind: .openFile,
      payload: .file(URL(fileURLWithPath: "/fixtures/report.pdf")))
    let opened = Date()
    let library = PersonalLibrary(defaults: defaults)
    library.record(file, query: "report", now: opened)
    let model = InternModel(defaults: defaults)
    model.replaceIndex([file])

    model.query = "report I opened"

    let result = try XCTUnwrap(model.hits.first { $0.id == file.id }?.candidate)
    XCTAssertEqual(result.title, file.title)
    XCTAssertEqual(result.lastOpenedAt, opened)
  }

  func testAPIKeyChangedWhileHiddenClearsPreviousCooldown() async throws {
    let (defaults, suite) = try defaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(false, forKey: "includeSpotlight")
    let queue = JudgmentQueue()
    let model = InternModel(
      defaults: defaults, buildIndex: { _ in LocalIndex(candidates: Fixtures.index) },
      ask: { try await queue.ask($0) })
    model.replaceIndex(Fixtures.index)
    model.query = "dark"
    await waitUntil { await queue.count == 1 }
    await queue.fail(.rateLimited(60))
    await waitUntil { model.inFlight == 0 }
    model.reset()
    defaults.set("replacement-key", forKey: JevClient.apiKeyDefaultsKey)

    model.panelWillShow()
    await waitUntil { !model.isIndexing }
    model.query = "dark"
    await waitUntil { await queue.count == 1 }
    await queue.finish(0, title: Fixtures.darkMode.title)
    await waitUntil { model.judgmentIsFresh }
    model.reset()
  }

  func testLocalOnlyEnabledBeforeQueuedTaskStartsPreventsAnyRequest() async throws {
    let (defaults, suite) = try defaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(false, forKey: "includeSpotlight")
    let queue = JudgmentQueue()
    let model = InternModel(defaults: defaults, ask: { try await queue.ask($0) })
    model.replaceIndex(Fixtures.index)
    model.query = "dark"

    defaults.set(true, forKey: "localOnly")
    model.preferencesChanged()
    await Task.yield()
    let count = await queue.count

    XCTAssertEqual(count, 0)
    XCTAssertEqual(model.inFlight, 0)
    XCTAssertNil(model.judgment)
    await queue.finishMalformed()
  }

  func testDeletingWorkspaceRejectsItsPendingOnlineJudgment() async throws {
    let (defaults, suite) = try defaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(false, forKey: "includeSpotlight")
    let library = PersonalLibrary(defaults: defaults)
    XCTAssertTrue(
      library.saveWorkspace(name: "Research", members: [Fixtures.safari, Fixtures.roadmap]))
    let workspace = try XCTUnwrap(library.snapshot.workspaces.first)
    let queue = JudgmentQueue()
    let model = InternModel(defaults: defaults, ask: { try await queue.ask($0) })
    model.query = "Research"
    await waitUntil { await queue.count == 1 }

    model.deleteWorkspace()
    await waitUntil { await queue.count == 2 }
    await queue.finish(0, title: workspace.name)
    await waitUntil { model.stats.staleDiscarded == 1 }

    XCTAssertNil(model.judgment)
    XCTAssertFalse(model.isReady)
    XCTAssertFalse(model.hits.contains { $0.id == workspace.id })
    await queue.finishMalformed()
    await waitUntil { model.inFlight == 0 }
  }
}

@MainActor
final class PersistenceQualityTests: XCTestCase {
  func testCorruptEntriesAreDroppedWithoutDiscardingValidState() throws {
    let suite = "PersistenceQualityTests.\(UUID())"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let unsafe = Candidate(
      id: "url:unsafe", title: "Unsafe", subtitle: "", kind: .openURL,
      payload: .url(URL(string: "javascript:alert(1)")!))
    let snapshot = PersonalLibrary.Snapshot(
      records: [
        "wrong-key": .init(
          candidate: Fixtures.safari, count: -5, lastOpened: nil, pinned: true,
          queries: ["  My Browser  ", "my browser", ""]),
        unsafe.id: .init(candidate: unsafe, pinned: true),
      ],
      workspaces: [
        .init(id: "bad", name: "Unsafe", members: [unsafe, Fixtures.safari]),
        .init(
          id: "workspace:valid", name: "  Work  ",
          members: [Fixtures.safari, Fixtures.roadmap, Fixtures.safari]),
      ])
    defaults.set(try JSONEncoder().encode(snapshot), forKey: PersonalLibrary.storageKey)

    let restored = PersonalLibrary(defaults: defaults)

    XCTAssertEqual(Set(restored.snapshot.records.keys), [Fixtures.safari.id])
    XCTAssertEqual(restored.snapshot.records[Fixtures.safari.id]?.count, 0)
    XCTAssertEqual(restored.snapshot.records[Fixtures.safari.id]?.queries, ["my browser"])
    XCTAssertEqual(restored.snapshot.workspaces.map(\.id), ["workspace:valid"])
    XCTAssertEqual(restored.snapshot.workspaces.first?.name, "Work")
    XCTAssertEqual(restored.snapshot.workspaces.first?.members.count, 2)
  }

  func testMalformedRecordDoesNotEraseOtherDecodableRecords() throws {
    let suite = "PersistenceQualityTests.\(UUID())"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let record = try XCTUnwrap(
      String(
        data: JSONEncoder().encode(
          PersonalLibrary.Record(candidate: Fixtures.safari, pinned: true)), encoding: .utf8))
    let data = Data(
      """
      {"records":{"valid":\(record),"broken":{"candidate":{"id":123}}},"workspaces":[]}
      """.utf8)
    defaults.set(data, forKey: PersonalLibrary.storageKey)

    let restored = PersonalLibrary(defaults: defaults)

    XCTAssertTrue(restored.isPinned(Fixtures.safari))
    XCTAssertEqual(restored.snapshot.records.count, 1)
  }

  func testUnsafeURLsCannotBePinnedRecordedOrSaved() throws {
    let suite = "PersistenceQualityTests.\(UUID())"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let unsafe = Candidate(
      id: "url:unsafe", title: "Unsafe", subtitle: "", kind: .openURL,
      payload: .url(URL(string: "javascript:alert(1)")!))
    let library = PersonalLibrary(defaults: defaults)

    library.togglePin(unsafe)
    library.record(unsafe, query: "unsafe")

    XCTAssertFalse(library.isPinned(unsafe))
    XCTAssertNil(library.snapshot.records[unsafe.id])
    XCTAssertFalse(library.saveWorkspace(name: "Unsafe", members: [unsafe, Fixtures.safari]))
  }

  func testSavedWorkspacePinAndUsageSurviveSanitization() throws {
    let suite = "PersistenceQualityTests.\(UUID())"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let library = PersonalLibrary(defaults: defaults)
    XCTAssertTrue(
      library.saveWorkspace(name: "Work", members: [Fixtures.safari, Fixtures.roadmap]))
    let workspace = try XCTUnwrap(library.snapshot.workspaces.first?.candidate)
    library.togglePin(workspace)
    library.record(workspace, query: "work")

    let restored = PersonalLibrary(defaults: defaults)

    XCTAssertTrue(restored.isPinned(workspace))
    XCTAssertEqual(restored.snapshot.records[workspace.id]?.queries, ["work"])
    XCTAssertEqual(restored.snapshot.records[workspace.id]?.count, 1)
  }

  func testPersistedRelativeURLAgesBecomeUnknownIncludingWorkspaceMembers() throws {
    let suite = "PersistenceQualityTests.\(UUID())"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let link = Candidate(
      id: "url:example", title: "Example", subtitle: "Visited today", kind: .openURL,
      payload: .url(URL(string: "https://example.com")!), ageDays: 0)
    let library = PersonalLibrary(defaults: defaults)
    library.record(link, query: "example")
    XCTAssertTrue(library.saveWorkspace(name: "Work", members: [link, Fixtures.safari]))
    let restored = PersonalLibrary(defaults: defaults)
    let candidates = restored.candidates()
    let restoredLink = try XCTUnwrap(candidates.first { $0.id == link.id })
    XCTAssertNil(restoredLink.ageDays)
    XCTAssertNil(restoredLink.visitedAt)
    XCTAssertFalse(restoredLink.subtitle.contains("today"))
    let workspace = try XCTUnwrap(candidates.first { $0.id.hasPrefix("workspace:") })
    guard case .group(let members) = workspace.payload else {
      return XCTFail("Missing workspace members")
    }
    XCTAssertNil(members.first { $0.id == link.id }?.ageDays)
    XCTAssertNil(members.first { $0.id == link.id }?.visitedAt)
  }

  func testPersistedURLVisitTimestampsSurviveAndAgeWithTime() throws {
    let suite = "PersistenceQualityTests.\(UUID())"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let visited = Date(timeIntervalSince1970: 1_700_000_000)
    let link = Candidate(
      id: "url:example", title: "Example", subtitle: "Visited today", kind: .openURL,
      payload: .url(URL(string: "https://example.com")!), ageDays: 0, visitedAt: visited)
    let library = PersonalLibrary(defaults: defaults)
    library.record(link, query: "example")
    XCTAssertTrue(library.saveWorkspace(name: "Work", members: [link, Fixtures.safari]))
    let restored = PersonalLibrary(defaults: defaults)
    let candidates = restored.candidates()
    let restoredLink = try XCTUnwrap(candidates.first { $0.id == link.id })
    let workspace = try XCTUnwrap(candidates.first { $0.id.hasPrefix("workspace:") })
    guard case .group(let members) = workspace.payload else {
      return XCTFail("Missing workspace members")
    }
    let restoredMember = try XCTUnwrap(members.first { $0.id == link.id })

    for candidate in [restoredLink, restoredMember] {
      XCTAssertEqual(candidate.visitedAt, visited)
      XCTAssertNil(candidate.ageDays)
      XCTAssertEqual(candidate.age(for: .modified, now: visited.addingTimeInterval(172_800)), 2)
      XCTAssertFalse(candidate.subtitle.contains("today"))
    }
  }

  func testLongQueriesCannotCreateFalseLearnedMatchesFromTruncatedAliases() throws {
    let suite = "PersistenceQualityTests.\(UUID())"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let library = PersonalLibrary(defaults: defaults)
    let commonPrefix = String(repeating: "research ", count: 25)
    library.record(Fixtures.safari, query: commonPrefix + "browser")

    let boost = try XCTUnwrap(
      library.boosts(query: commonPrefix + "spreadsheet")[Fixtures.safari.id])

    XCTAssertLessThanOrEqual(boost, 0.14)
    XCTAssertTrue(library.snapshot.records[Fixtures.safari.id]?.queries.isEmpty == true)
  }
}
