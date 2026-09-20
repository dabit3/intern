import Foundation

enum SearchScope: String, CaseIterable, Identifiable {
  case all = "All"
  case files = "Files"
  case apps = "Apps"
  case links = "Links"
  case workspaces = "Workspaces"

  var id: String { rawValue }

  func includes(_ candidate: Candidate) -> Bool {
    switch self {
    case .all: return true
    case .files:
      if case .file = candidate.payload { return candidate.kind == .openFile }
      return false
    case .apps:
      if case .app = candidate.payload { return candidate.kind == .openApp }
      return false
    case .links:
      if case .url = candidate.payload { return candidate.kind == .openURL }
      return false
    case .workspaces:
      if case .group = candidate.payload { return candidate.id.hasPrefix("workspace:") }
      return false
    }
  }
}

enum FileRecency: String {
  case modified, opened, added

  init(query: String) {
    let words = Set(Fuzzy.tokens(query))
    if !words.isDisjoint(with: ["opened", "used", "working", "worked"]) {
      self = .opened
    } else if !words.isDisjoint(with: ["downloaded", "download", "added"]) {
      self = .added
    } else {
      self = .modified
    }
  }
}
