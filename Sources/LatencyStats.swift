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
    requests == 0 ? 0 : (Double(inputTokens) + Double(outputTokens)) / Double(requests)
  }

  mutating func recordSuccess(
    latencyMs: Double, inputTokens: Int, outputTokens: Int, at time: TimeInterval
  ) {
    requests += 1
    self.inputTokens = Self.addTokens(inputTokens, to: self.inputTokens)
    self.outputTokens = Self.addTokens(outputTokens, to: self.outputTokens)
    if latencyMs.isFinite, latencyMs >= 0 {
      samplesMs.append(latencyMs)
      if samplesMs.count > Self.maxSamples { samplesMs.removeFirst() }
    }
    if time.isFinite {
      completionTimes.append(time)
      let newest = completionTimes.max() ?? time
      completionTimes.removeAll { $0 < newest - Self.rateWindowSeconds }
      if completionTimes.count > Self.maxSamples { completionTimes.removeFirst() }
    }
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
    guard now.isFinite else { return 0 }
    let recent = completionTimes.filter { $0 >= now - Self.rateWindowSeconds && $0 <= now }
    guard let first = recent.min(), recent.count > 1 else { return Double(recent.count) }
    let span = max(now - first, 1)
    return Double(recent.count) / span
  }

  func percentile(_ p: Double) -> Double? {
    guard !samplesMs.isEmpty, p.isFinite else { return nil }
    let sorted = samplesMs.sorted()
    let rank = Int((Double(sorted.count - 1) * min(100, max(0, p)) / 100).rounded())
    return sorted[min(max(rank, 0), sorted.count - 1)]
  }

  private static func addTokens(_ value: Int, to total: Int) -> Int {
    let (sum, overflow) = total.addingReportingOverflow(max(0, value))
    return overflow ? Int.max : sum
  }
}
