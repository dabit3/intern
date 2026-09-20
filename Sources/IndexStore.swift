import Foundation

/// Keeps the last built index on disk so the launcher answers instantly after launch, before the
/// background rebuild finishes. Items whose files have disappeared are dropped when loading.
struct IndexStore: Sendable {
  let url: URL

  static var standard: IndexStore {
    let fileManager = FileManager.default
    let support =
      fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? fileManager.temporaryDirectory
    let folder = Bundle.main.bundleIdentifier ?? "Intern"
    return IndexStore(
      url: support.appendingPathComponent(folder).appendingPathComponent("index.json"))
  }

  func load(fileManager: FileManager = .default) -> [Candidate]? {
    guard let data = try? Data(contentsOf: url),
      let candidates = try? JSONDecoder().decode([Candidate].self, from: data)
    else { return nil }
    return candidates.filter { candidate in
      guard let path = candidate.fileURL?.path else { return true }
      return fileManager.fileExists(atPath: path)
    }
  }

  func save(_ candidates: [Candidate], fileManager: FileManager = .default) {
    guard let data = try? JSONEncoder().encode(candidates) else { return }
    try? fileManager.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    try? data.write(to: url, options: [.atomic])
  }
}
