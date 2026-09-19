import AppKit
import Combine
import Foundation

@MainActor
final class LauncherModel: ObservableObject {
  /// Below this the panel keeps the full list; at or above it the top hit is shown as ready.
  static let readyThreshold = 0.6
  /// A target this certain is treated as ready even when the readiness judgment hedges.
  static let certainTargetThreshold = 0.9
  /// Jev's "all" probability needed before a group row shows the ready badge.
  static let certainSetThreshold = 0.75

  @Published var query = "" {
    didSet { if query != oldValue { queryChanged() } }
  }
  @Published private(set) var hits: [RankedHit] = []
  @Published var selection = 0
  @Published private(set) var judgment: JevJudgment?
  @Published private(set) var judgmentIsFresh = false
  @Published private(set) var stats = LatencyStats()
  @Published private(set) var inFlight = 0
  @Published private(set) var lastError: String?
  @Published private(set) var status: String?
  @Published private(set) var indexSize = 0

  var onExecute: (() -> Void)?

  private var index: [Candidate] = []
  private var prefiltered = Ranker.Prefiltered(candidates: [], fuzzy: [:])
  private var sequence = 0
  private var newestApplied = 0
  private var context = LaunchContext(
    frontmostApp: "", recentApps: [], clipboardKind: "empty", timeOfDay: "", weekday: "")
  private let client = JevClient()
  private var indexTask: Task<Void, Never>?

  var isReady: Bool {
    guard let judgment, judgmentIsFresh, selection == 0, let top = hits.first else {
      return false
    }
    if top.isGroup {
      // A set is ready when Jev clearly read the query as "all of them"; opening several
      // things at once should never ride on a hedged answer.
      return judgment.setProbability >= Self.certainSetThreshold
    }
    if judgment.ready >= Self.readyThreshold { return true }
    return (top.jevProbability ?? 0) >= Self.certainTargetThreshold
  }

  var hasAPIKey: Bool { JevClient.apiKey() != nil }

  var topHit: RankedHit? { hits.indices.contains(selection) ? hits[selection] : hits.first }

  func panelWillShow() {
    captureContext()
    status = nil
    rebuildIndex()
  }

  func rebuildIndex() {
    indexTask?.cancel()
    indexTask = Task.detached(priority: .userInitiated) { [weak self] in
      let built = LocalIndex.build()
      await self?.indexDidLoad(built.candidates)
    }
  }

  private func indexDidLoad(_ candidates: [Candidate]) {
    index = candidates
    indexSize = candidates.count
    if !query.isEmpty { queryChanged() }
  }

  func reset() {
    query = ""
    hits = []
    selection = 0
    judgment = nil
    judgmentIsFresh = false
    lastError = nil
  }

  func moveSelection(by delta: Int) {
    guard !hits.isEmpty else { return }
    selection = min(max(selection + delta, 0), hits.count - 1)
  }

  func executeSelection() {
    guard let hit = topHit else { return }
    status = Executor.execute(hit.candidate)
    onExecute?()
  }

  private func captureContext() {
    let workspace = NSWorkspace.shared
    let frontmost = workspace.frontmostApplication?.localizedName ?? "Finder"
    let recent = workspace.runningApplications
      .filter { $0.activationPolicy == .regular }
      .compactMap(\.localizedName)
      .filter { $0 != "Launcher" }
      .prefix(8)
    let hour = Calendar.current.component(.hour, from: Date())
    let weekday = Calendar.current.weekdaySymbols[
      Calendar.current.component(.weekday, from: Date()) - 1]
    context = LaunchContext(
      frontmostApp: frontmost, recentApps: Array(recent), clipboardKind: clipboardKind(),
      timeOfDay: LaunchContext.timeOfDay(hour: hour), weekday: weekday)
  }

  private func clipboardKind() -> String {
    let pasteboard = NSPasteboard.general
    guard let types = pasteboard.types, !types.isEmpty else { return "empty" }
    if types.contains(.fileURL) { return "file" }
    if types.contains(.URL) { return "url" }
    if types.contains(.png) || types.contains(.tiff) { return "image" }
    if types.contains(.string) {
      let text = pasteboard.string(forType: .string) ?? ""
      if text.hasPrefix("http://") || text.hasPrefix("https://") { return "url" }
      return text.allSatisfy({ $0.isNumber || " +-*/.,%()".contains($0) }) && !text.isEmpty
        ? "number" : "text"
    }
    return "other"
  }

  // MARK: - Per-keystroke pipeline

  private func queryChanged() {
    sequence += 1
    let seq = sequence
    prefiltered = Ranker.prefilter(query: query, index: index)
    // Carry the previous judgment forward so the list does not flicker back to fuzzy order
    // for the ~150 ms until the fresh answer lands. It is marked stale until then.
    judgmentIsFresh = false
    hits = Ranker.rank(prefiltered, judgment: judgment)
    selection = 0
    guard !prefiltered.candidates.isEmpty else {
      judgment = nil
      return
    }
    let request = JevQuestions.buildRequest(
      query: query, context: context, candidates: prefiltered.candidates,
      window: prefiltered.window)
    let sent = prefiltered
    inFlight += 1
    Task { [client] in
      defer { inFlight -= 1 }
      do {
        let result = try await client.ask(request)
        apply(result, sequence: seq, sent: sent)
      } catch {
        stats.recordFailure()
        lastError = describe(error)
      }
    }
  }

  private func apply(_ result: JevClient.Result, sequence seq: Int, sent: Ranker.Prefiltered) {
    stats.recordSuccess(
      latencyMs: result.latencyMs, inputTokens: result.response.usage.inputTokens,
      outputTokens: result.response.usage.outputTokens, at: Date().timeIntervalSince1970)
    // Answers can land out of order. Only the newest query's answer may drive the list.
    guard seq > newestApplied else {
      stats.recordStale()
      return
    }
    newestApplied = seq
    lastError = nil
    guard let parsed = JevQuestions.parse(result.response, candidates: sent.candidates) else {
      return
    }
    judgment = parsed
    judgmentIsFresh = seq == sequence
    hits = Ranker.rank(prefiltered, judgment: parsed)
    selection = 0
  }

  private func describe(_ error: Error) -> String {
    if let failure = error as? JevClient.Failure {
      switch failure {
      case .missingAPIKey: return "No API key. Set TYPESAFE_API_KEY or add one in Settings."
      case .http(let code): return "HTTP \(code)"
      case .transport(let message): return message
      }
    }
    return error.localizedDescription
  }
}
