import Combine
import Foundation

@MainActor
final class PersonalLibrary: ObservableObject {
  struct Record: Codable, Equatable {
    var candidate: Candidate
    var count = 0
    var lastOpened: Date?
    var pinned = false
    var queries: [String] = []
  }

  struct Workspace: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var members: [Candidate]

    var candidate: Candidate {
      Candidate(
        id: id, title: name,
        subtitle:
          "\(members.count) items · \(members.prefix(3).map(\.title).joined(separator: ", ")) · Saved workspace",
        kind: .openFile, keywords: ["workspace", "project", "session"] + members.map(\.title),
        payload: .group(members))
    }
  }

  struct Snapshot: Codable, Equatable {
    var records: [String: Record] = [:]
    var workspaces: [Workspace] = []

    private enum CodingKeys: String, CodingKey {
      case records, workspaces
    }

    init(records: [String: Record] = [:], workspaces: [Workspace] = []) {
      self.records = records
      self.workspaces = workspaces
    }

    init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      records =
        (try? container.decode([String: Lossy<Record>].self, forKey: .records))?
        .compactMapValues(\.value) ?? [:]
      workspaces =
        (try? container.decode([Lossy<Workspace>].self, forKey: .workspaces))?
        .compactMap(\.value) ?? []
    }
  }

  private struct Lossy<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: Decoder) throws {
      value = try? decoder.singleValueContainer().decode(Value.self)
    }
  }

  static let storageKey = "launcher.library.v1"
  @Published private(set) var snapshot: Snapshot
  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    let decoded =
      defaults.data(forKey: Self.storageKey)
      .flatMap { try? JSONDecoder().decode(Snapshot.self, from: $0) } ?? Snapshot()
    snapshot = Self.sanitize(decoded)
    if snapshot != decoded {
      save()
    }
  }

  func isPinned(_ candidate: Candidate) -> Bool {
    snapshot.records[candidate.id]?.pinned == true
  }

  func togglePin(_ candidate: Candidate) {
    guard let candidate = persistableCandidate(candidate) else { return }
    var record = snapshot.records[candidate.id] ?? Record(candidate: candidate)
    record.candidate = candidate
    record.pinned.toggle()
    snapshot.records[candidate.id] = record
    save()
  }

  func record(_ candidate: Candidate, query: String, now: Date = Date()) {
    if case .group(let members) = candidate.payload {
      for member in members { record(member, query: "", now: now) }
      if !candidate.id.hasPrefix("workspace:") { return }
    }
    guard let candidate = persistableCandidate(candidate) else { return }
    var record = snapshot.records[candidate.id] ?? Record(candidate: candidate)
    record.candidate = candidate
    record.count = min(1_000_000, record.count + 1)
    record.lastOpened = now
    let normalized = Self.normalize(query)
    if !normalized.isEmpty {
      record.queries.removeAll { $0 == normalized }
      record.queries.insert(normalized, at: 0)
      record.queries = Array(record.queries.prefix(8))
    }
    snapshot.records[candidate.id] = record
    save()
  }

  @discardableResult
  func saveWorkspace(name: String, members: [Candidate]) -> Bool {
    let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    var seen = Set<String>()
    let members = members.filter { Self.isSafe($0) && seen.insert($0.id).inserted }
    guard !name.isEmpty, members.count >= 2, members.count <= Ranker.maximumSetSize,
      snapshot.workspaces.count < 20
    else { return false }
    snapshot.workspaces.append(
      Workspace(
        id: "workspace:\(UUID().uuidString)", name: String(name.prefix(80)), members: members))
    save()
    return true
  }

  func deleteWorkspace(id: String) {
    snapshot.workspaces.removeAll { $0.id == id }
    snapshot.records.removeValue(forKey: id)
    save()
  }

  func clearHistory() {
    snapshot.records = snapshot.records.filter { $0.value.pinned }.mapValues {
      Record(candidate: $0.candidate, pinned: true)
    }
    save()
  }

  func candidates(now: Date = Date()) -> [Candidate] {
    let items = snapshot.records.values.compactMap { record -> Candidate? in
      guard !record.candidate.id.hasPrefix("workspace:") else { return nil }
      if let url = record.candidate.fileURL {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        if record.candidate.kind == .openFile {
          let fresh = LocalIndex.fileCandidate(
            url: url, folder: url.deletingLastPathComponent().lastPathComponent, now: now,
            readSpotlightMetadata: false)
          let opened = [record.candidate.lastOpenedAt, record.lastOpened].compactMap { $0 }.max()
          var detail = fresh.subtitle
          if let date = opened {
            detail +=
              " · "
              + LocalIndex.recency(max(0, now.timeIntervalSince(date)) / 86_400)
              .replacingOccurrences(of: "modified", with: "opened")
          }
          return Candidate(
            id: fresh.id, title: fresh.title, subtitle: detail, kind: fresh.kind,
            keywords: fresh.keywords, payload: fresh.payload, ageDays: fresh.ageDays,
            modifiedAt: fresh.modifiedAt,
            lastOpenedAt: opened,
            addedAt: fresh.addedAt ?? record.candidate.addedAt)
        }
      }
      return Self.withoutHistoricalAge(record.candidate)
    }
    return items + snapshot.workspaces.map { Self.withoutHistoricalAge($0.candidate) }
  }

  func home(candidates: [Candidate], scope: SearchScope) -> [RankedHit] {
    candidates.filter { candidate in
      scope.includes(candidate)
        && (snapshot.records[candidate.id] != nil || candidate.id.hasPrefix("workspace:"))
    }
    .sorted {
      let lhs = snapshot.records[$0.id]
      let rhs = snapshot.records[$1.id]
      if (lhs?.pinned ?? false) != (rhs?.pinned ?? false) { return lhs?.pinned == true }
      if lhs?.lastOpened != rhs?.lastOpened {
        return (lhs?.lastOpened ?? .distantPast) > (rhs?.lastOpened ?? .distantPast)
      }
      return $0.title < $1.title
    }
    .prefix(8)
    .map {
      RankedHit(
        candidate: $0, fuzzy: 0, jevProbability: nil, matchProbability: nil, inSet: false, score: 0)
    }
  }

  func boosts(query: String, now: Date = Date()) -> [String: Double] {
    let normalized = Self.normalize(query)
    return snapshot.records.mapValues { record in
      if !normalized.isEmpty, record.queries.contains(normalized) { return 0.35 }
      let age = now.timeIntervalSince(record.lastOpened ?? .distantPast) / 86_400
      return (record.pinned ? 0.04 : 0) + 0.06 * exp(-max(0, age) / 7)
        + min(0.04, Double(record.count) * 0.005)
    }
  }

  static func normalize(_ query: String) -> String {
    let normalized = Fuzzy.tokens(query).joined(separator: " ")
    return normalized.count <= 160 ? normalized : ""
  }

  private static func sanitize(_ decoded: Snapshot) -> Snapshot {
    var workspaceIDs = Set<String>()
    let workspaces = Array(
      decoded.workspaces.compactMap { workspace -> Workspace? in
        guard workspace.id.hasPrefix("workspace:"), workspaceIDs.insert(workspace.id).inserted
        else {
          return nil
        }
        let name = workspace.name.trimmingCharacters(in: .whitespacesAndNewlines)
        var memberIDs = Set<String>()
        let members = workspace.members.filter {
          isSafe($0) && memberIDs.insert($0.id).inserted
        }
        guard !name.isEmpty, members.count >= 2, members.count <= Ranker.maximumSetSize else {
          return nil
        }
        return Workspace(
          id: workspace.id, name: String(name.prefix(80)), members: members)
      }.prefix(20))
    let workspaceCandidates = Dictionary(
      uniqueKeysWithValues: workspaces.map { ($0.id, $0.candidate) })
    var records: [String: Record] = [:]
    for original in decoded.records.values {
      var record = original
      if record.candidate.id.hasPrefix("workspace:") {
        guard let workspace = workspaceCandidates[record.candidate.id] else { continue }
        record.candidate = workspace
      } else if !isSafe(record.candidate) {
        continue
      }
      record.count = min(max(0, record.count), 1_000_000)
      record.queries = Array(
        record.queries.map(normalize).filter { !$0.isEmpty }.uniqued().prefix(8))
      if let existing = records[record.candidate.id] {
        record.pinned = record.pinned || existing.pinned
        record.count = min(1_000_000, record.count + existing.count)
        record.lastOpened = [record.lastOpened, existing.lastOpened].compactMap { $0 }.max()
        record.queries = Array((record.queries + existing.queries).uniqued().prefix(8))
      }
      records[record.candidate.id] = record
    }
    records = Dictionary(
      uniqueKeysWithValues: records.sorted(by: recordOrder).prefix(200).map { ($0.key, $0.value) })
    return Snapshot(records: records, workspaces: workspaces)
  }

  private static func withoutHistoricalAge(_ candidate: Candidate) -> Candidate {
    switch candidate.payload {
    case .url(let url):
      return Candidate(
        id: candidate.id, title: candidate.title, subtitle: "\(url.host ?? "") · Saved link",
        kind: candidate.kind, keywords: candidate.keywords, payload: candidate.payload,
        visitedAt: candidate.visitedAt)
    case .group(let members):
      return Candidate(
        id: candidate.id, title: candidate.title, subtitle: candidate.subtitle,
        kind: candidate.kind, keywords: candidate.keywords,
        payload: .group(members.map(withoutHistoricalAge)))
    default:
      return candidate
    }
  }

  private func persistableCandidate(_ candidate: Candidate) -> Candidate? {
    if candidate.id.hasPrefix("workspace:") {
      return snapshot.workspaces.first { $0.id == candidate.id }?.candidate
    }
    return Self.isSafe(candidate) ? candidate : nil
  }

  private static func recordOrder(
    _ lhs: Dictionary<String, Record>.Element, _ rhs: Dictionary<String, Record>.Element
  ) -> Bool {
    if lhs.value.pinned != rhs.value.pinned { return lhs.value.pinned }
    return (lhs.value.lastOpened ?? .distantPast) > (rhs.value.lastOpened ?? .distantPast)
  }

  private static func isSafe(_ candidate: Candidate) -> Bool {
    switch candidate.payload {
    case .app(let url), .file(let url):
      return !candidate.id.isEmpty && url.isFileURL
    case .url(let url):
      return !candidate.id.isEmpty
        && ["http", "https"].contains(url.scheme?.lowercased() ?? "") && url.host != nil
    default:
      return false
    }
  }

  private func save() {
    let retained = snapshot.records.sorted(by: Self.recordOrder).prefix(200)
    snapshot.records = Dictionary(uniqueKeysWithValues: retained.map { ($0.key, $0.value) })
    if let data = try? JSONEncoder().encode(snapshot) {
      defaults.set(data, forKey: Self.storageKey)
    }
  }
}

extension Sequence where Element: Hashable {
  fileprivate func uniqued() -> [Element] {
    var seen = Set<Element>()
    return filter { seen.insert($0).inserted }
  }
}
