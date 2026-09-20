import XCTest

@testable import Intern

final class LatencyStatsTests: XCTestCase {
  func testEmptyStats() {
    let stats = LatencyStats()
    XCTAssertNil(stats.lastMs)
    XCTAssertNil(stats.p50Ms)
    XCTAssertNil(stats.p95Ms)
    XCTAssertEqual(stats.decisionsPerSecond(now: 100), 0)
    XCTAssertEqual(stats.tokensPerDecision, 0)
    XCTAssertEqual(stats.estimatedCostUSD, 0)
  }

  func testPercentilesAndTokens() {
    var stats = LatencyStats()
    for (i, ms) in [120.0, 90, 300, 110, 150, 100, 130, 95, 140, 900].enumerated() {
      stats.recordSuccess(latencyMs: ms, inputTokens: 700, outputTokens: 100, at: Double(i))
    }
    XCTAssertEqual(stats.lastMs, 900)
    XCTAssertEqual(stats.p50Ms, 130)
    XCTAssertEqual(stats.p95Ms, 900)
    XCTAssertEqual(stats.requests, 10)
    XCTAssertEqual(stats.tokensPerDecision, 800)
    XCTAssertEqual(stats.estimatedCostUSD, 7000 * 0.042 / 1_000_000, accuracy: 1e-12)
  }

  func testFailuresAndStaleCountSeparately() {
    var stats = LatencyStats()
    stats.recordSuccess(latencyMs: 100, inputTokens: 1, outputTokens: 1, at: 0)
    stats.recordFailure()
    stats.recordStale()
    XCTAssertEqual(stats.requests, 2)
    XCTAssertEqual(stats.failures, 1)
    XCTAssertEqual(stats.staleDiscarded, 1)
    XCTAssertEqual(stats.lastMs, 100)
  }

  func testDecisionsPerSecondUsesTrailingWindow() {
    var stats = LatencyStats()
    for t in stride(from: 0.0, through: 4.0, by: 0.5) {
      stats.recordSuccess(latencyMs: 100, inputTokens: 1, outputTokens: 0, at: t)
    }
    XCTAssertEqual(stats.decisionsPerSecond(now: 4), 9.0 / 4.0, accuracy: 1e-9)
    XCTAssertEqual(stats.decisionsPerSecond(now: 100), 0)
  }

  func testSampleCap() {
    var stats = LatencyStats()
    for i in 0..<(LatencyStats.maxSamples + 5) {
      stats.recordSuccess(latencyMs: Double(i), inputTokens: 0, outputTokens: 0, at: 0)
    }
    XCTAssertEqual(stats.samplesMs.count, LatencyStats.maxSamples)
    XCTAssertEqual(stats.samplesMs.first, 5)
  }
}

private final class ScanFileManager: FileManager, @unchecked Sendable {
  private let lock = NSLock()
  private var visited: [URL] = []
  let cancelOnVisit: Bool

  init(cancelOnVisit: Bool = false) {
    self.cancelOnVisit = cancelOnVisit
    super.init()
  }

  override var homeDirectoryForCurrentUser: URL {
    URL(fileURLWithPath: "/InternTests")
  }

  var visitedDirectories: [URL] { lock.withLock { visited } }

  override func contentsOfDirectory(
    at url: URL, includingPropertiesForKeys keys: [URLResourceKey]?,
    options mask: FileManager.DirectoryEnumerationOptions = []
  ) throws -> [URL] {
    lock.withLock { visited.append(url) }
    if cancelOnVisit { withUnsafeCurrentTask { $0?.cancel() } }
    return []
  }
}

final class LocalIndexTests: XCTestCase {
  func testCancelledScanDoesNotVisitProtectedFolders() async {
    let manager = ScanFileManager()
    let task = Task.detached {
      withUnsafeCurrentTask { $0?.cancel() }
      return LocalIndex.scanFiles(fileManager: manager, now: Date())
    }
    let files = await task.value
    XCTAssertTrue(files.isEmpty)
    XCTAssertTrue(manager.visitedDirectories.isEmpty)
  }

  func testCancellationDuringFolderAccessStopsBeforeTheNextFolder() async {
    let manager = ScanFileManager(cancelOnVisit: true)
    let task = Task.detached {
      LocalIndex.scanFiles(fileManager: manager, now: Date())
    }
    let files = await task.value
    XCTAssertTrue(files.isEmpty)
    XCTAssertEqual(manager.visitedDirectories.map(\.lastPathComponent), ["Downloads"])
  }

  func testRecencyPhrases() {
    XCTAssertEqual(LocalIndex.recency(0), "modified just now")
    XCTAssertEqual(LocalIndex.recency(30.0 / 1440), "modified 30 min ago")
    XCTAssertEqual(LocalIndex.recency(0.5), "modified 12 h ago")
    XCTAssertEqual(LocalIndex.recency(1.5), "modified yesterday")
    XCTAssertEqual(LocalIndex.recency(7), "modified 7 days ago")
    XCTAssertEqual(LocalIndex.recency(35), "modified 1 month ago")
    XCTAssertEqual(LocalIndex.recency(70), "modified 2 months ago")
    XCTAssertEqual(LocalIndex.recency(400), "modified over a year ago")
  }

  func testFileCandidateFromTemporaryFile() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("Report.PDF")
    try Data("x".utf8).write(to: url)

    let candidate = LocalIndex.fileCandidate(url: url, folder: "Downloads", now: Date())
    XCTAssertEqual(candidate.kind, .openFile)
    XCTAssertEqual(candidate.title, "Report.PDF")
    XCTAssertTrue(candidate.subtitle.hasPrefix("PDF in "))
    XCTAssertTrue(candidate.subtitle.hasSuffix("modified just now"))
    XCTAssertTrue(candidate.keywords.contains("downloaded"))
    XCTAssertTrue(candidate.keywords.contains("pdf"))
    XCTAssertTrue(candidate.keywords.contains("recent"))
    XCTAssertEqual(candidate.payload, .file(url))
  }

  func testFileTypeLabels() {
    XCTAssertEqual(LocalIndex.fileTypeLabel("pdf"), "PDF")
    XCTAssertEqual(LocalIndex.fileTypeLabel(""), "File")
    XCTAssertTrue(LocalIndex.fileTypeWords("pdf").contains("document"))
  }

  func testSystemTogglesArePresentInIndex() {
    let toggles = SystemToggle.allCases.map(\.candidate)
    XCTAssertEqual(toggles.count, SystemToggle.allCases.count)
    XCTAssertTrue(toggles.allSatisfy { $0.kind == .systemToggle })
    XCTAssertTrue(toggles.contains { $0.title == "Toggle Dark Mode" })
    XCTAssertTrue(toggles.contains { $0.title == "Turn Wi-Fi Off" })
  }
}

final class ExecutorTests: XCTestCase {
  func testParseWifiDevice() {
    let listing = """
      Hardware Port: Ethernet Adapter (en3)
      Device: en3
      Ethernet Address: aa:bb

      Hardware Port: Wi-Fi
      Device: en0
      Ethernet Address: cc:dd

      Hardware Port: Thunderbolt Bridge
      Device: bridge0
      """
    XCTAssertEqual(Executor.parseWifiDevice(listing), "en0")
    XCTAssertNil(Executor.parseWifiDevice("Hardware Port: Ethernet\nDevice: en3\n"))
  }
}
