import Foundation

/// Rolling round-trip statistics for the footer. Pure value type so it is trivially testable.
struct LatencyStats: Equatable, Sendable {
  /// Published price for jev-1.13: $0.042 per million input tokens; output tokens are free.
  static let usdPerInputToken = 0.042 / 1_000_000
  static let maxSamples = 1_000
  static let rateWindowSeconds = 10.0

  private(set) var samplesMs: [Double] = []
  private(set) var completionTimes: [TimeInterval] = []
  private(set) var requests = 0
  private(set) var failures = 0
  private(set) var staleDiscarded = 0
  private(set) var inputTokens = 0
  private(set) var outputTokens = 0

  var lastMs: Double? { samplesMs.last }
  var p50Ms: Double? { percentile(50) }
  var p95Ms: Double? { percentile(95) }
  var estimatedCostUSD: Double { Double(inputTokens) * Self.usdPerInputToken }
  var tokensPerDecision: Double {
    requests == 0 ? 0 : Double(inputTokens + outputTokens) / Double(requests)
  }

  mutating func recordSuccess(
    latencyMs: Double, inputTokens: Int, outputTokens: Int, at time: TimeInterval
  ) {
    requests += 1
    self.inputTokens += inputTokens
    self.outputTokens += outputTokens
    samplesMs.append(latencyMs)
    if samplesMs.count > Self.maxSamples { samplesMs.removeFirst() }
    completionTimes.append(time)
    completionTimes.removeAll { $0 < time - Self.rateWindowSeconds }
  }

  mutating func recordFailure() {
    requests += 1
    failures += 1
  }

  mutating func recordStale() {
    staleDiscarded += 1
  }

  /// Decisions completed per second over the trailing window.
  func decisionsPerSecond(now: TimeInterval) -> Double {
    let recent = completionTimes.filter { $0 >= now - Self.rateWindowSeconds }
    guard let first = recent.first, recent.count > 1 else { return Double(recent.count) }
    let span = max(now - first, 1)
    return Double(recent.count) / span
  }

  func percentile(_ p: Double) -> Double? {
    guard !samplesMs.isEmpty else { return nil }
    let sorted = samplesMs.sorted()
    let rank = Int((Double(sorted.count - 1) * p / 100).rounded())
    return sorted[min(max(rank, 0), sorted.count - 1)]
  }
}
