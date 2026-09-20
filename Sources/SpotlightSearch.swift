import Foundation

@MainActor
final class SpotlightSearch {
  private var query: NSMetadataQuery?
  private var observers: [NSObjectProtocol] = []
  private var timeout: Task<Void, Never>?
  private var completion: (([Candidate]) -> Void)?
  private var generation = 0

  func search(_ text: String, completion: @escaping ([Candidate]) -> Void) {
    stop()
    let generation = generation
    let query = NSMetadataQuery()
    query.searchScopes = [NSMetadataQueryUserHomeScope]
    query.predicate = Self.predicate(for: text)
    let dateKey: String
    switch FileRecency(query: text) {
    case .opened: dateKey = "kMDItemLastUsedDate"
    case .added: dateKey = "kMDItemDateAdded"
    case .modified: dateKey = "kMDItemFSContentChangeDate"
    }
    query.sortDescriptors = [NSSortDescriptor(key: dateKey, ascending: false)]
    self.query = query
    self.completion = completion
    observers = [
      NotificationCenter.default.addObserver(
        forName: .NSMetadataQueryDidFinishGathering, object: query, queue: .main
      ) { [weak self] _ in
        Task { @MainActor in self?.finish(generation: generation) }
      }
    ]
    guard query.start() else {
      finish(generation: generation)
      return
    }
    timeout = Task { [weak self] in
      try? await Task.sleep(for: .seconds(1))
      guard !Task.isCancelled else { return }
      self?.finish(generation: generation)
    }
  }

  func stop() {
    generation += 1
    timeout?.cancel()
    timeout = nil
    query?.stop()
    query = nil
    for observer in observers { NotificationCenter.default.removeObserver(observer) }
    observers = []
    completion = nil
  }

  private func finish(generation: Int) {
    guard generation == self.generation, let query else { return }
    query.disableUpdates()
    var candidates: [Candidate] = []
    var seen = Set<String>()
    let now = Date()
    for index in 0..<min(query.resultCount, 600) {
      guard let item = query.result(at: index) as? NSMetadataItem,
        let path = item.value(forAttribute: NSMetadataItemPathKey) as? String,
        Self.allowed(path: path)
      else { continue }
      let url = URL(fileURLWithPath: path)
      guard FileManager.default.fileExists(atPath: path) else { continue }
      let candidate = LocalIndex.fileCandidate(
        url: url, folder: url.deletingLastPathComponent().lastPathComponent,
        now: now, metadata: item)
      if seen.insert(candidate.id).inserted { candidates.append(candidate) }
      if candidates.count == 150 { break }
    }
    let callback = completion
    stop()
    callback?(candidates)
  }

  static func allowed(path: String, home: String = NSHomeDirectory()) -> Bool {
    let root = URL(fileURLWithPath: home).standardizedFileURL
    let url = URL(fileURLWithPath: path).standardizedFileURL
    return allowedComponents(url: url, root: root)
      && allowedComponents(url: url.resolvingSymlinksInPath(), root: root.resolvingSymlinksInPath())
  }

  private static func allowedComponents(url: URL, root: URL) -> Bool {
    guard url.path.hasPrefix(root.path + "/") else { return false }
    let components = url.path.dropFirst(root.path.count + 1).split(separator: "/")
    return !components.contains {
      let name = $0.lowercased()
      return name.hasPrefix(".") || name.hasSuffix(".app") || name == "library"
        || name == "node_modules"
    }
  }

  static func predicate(for text: String, now: Date = Date()) -> NSPredicate {
    let window = TimeWindow.parse(text, now: now)
    let remainder = window?.remainder ?? text
    let ignored = Fuzzy.stopwords.union([
      "last", "latest", "recent", "recently", "opened", "used", "modified", "edited",
      "downloaded", "download", "downloads", "added", "file", "files", "document", "documents",
    ])
    let typeWords = [
      "pdf": "com.adobe.pdf", "paper": "com.adobe.pdf",
      "image": "public.image", "photo": "public.image", "picture": "public.image",
      "video": "public.movie", "movie": "public.movie",
      "spreadsheet": "public.spreadsheet", "folder": "public.folder",
      "presentation": "public.presentation", "slide": "public.presentation",
      "deck": "public.presentation", "audio": "public.audio", "music": "public.audio",
      "archive": "public.archive", "text": "public.text",
    ]
    let tokens = Fuzzy.tokens(remainder).map {
      $0.hasSuffix("s") && typeWords[String($0.dropLast())] != nil ? String($0.dropLast()) : $0
    }
    let types = Set(tokens.compactMap { typeWords[$0] })
    let words = tokens.filter { !ignored.contains($0) && typeWords[$0] == nil && $0.count >= 2 }
    var predicates: [NSPredicate] = [
      NSCompoundPredicate(orPredicateWithSubpredicates: [
        NSPredicate(format: "kMDItemContentTypeTree == %@", "public.data"),
        NSPredicate(format: "kMDItemContentTypeTree == %@", "public.directory"),
      ])
    ]
    if !types.isEmpty {
      predicates.append(
        anyOf(
          types.sorted().map {
            NSPredicate(format: "kMDItemContentTypeTree == %@", $0)
          }))
    }
    if !words.isEmpty {
      let names = words.prefix(6).map {
        NSPredicate(format: "kMDItemFSName CONTAINS[cd] %@", $0)
      }
      predicates.append(NSCompoundPredicate(andPredicateWithSubpredicates: Array(names)))
    }
    if FileRecency(query: text) == .opened {
      predicates.append(NSPredicate(format: "kMDItemLastUsedDate != nil"))
    }
    if let window {
      let dateKey: String
      switch FileRecency(query: text) {
      case .opened: dateKey = "kMDItemLastUsedDate"
      case .added: dateKey = "kMDItemDateAdded"
      case .modified: dateKey = "kMDItemFSContentChangeDate"
      }
      func dates(_ key: String) -> NSPredicate {
        NSCompoundPredicate(andPredicateWithSubpredicates: [
          NSPredicate(format: "%K >= %@", key, window.since as NSDate),
          NSPredicate(format: "%K <= %@", key, (window.until ?? now) as NSDate),
        ])
      }
      if FileRecency(query: text) == .added {
        predicates.append(
          anyOf([
            dates(dateKey),
            NSCompoundPredicate(andPredicateWithSubpredicates: [
              NSPredicate(format: "kMDItemDateAdded == nil"), dates("kMDItemFSContentChangeDate"),
            ]),
          ]))
      } else {
        predicates.append(dates(dateKey))
      }
    }
    return predicates.count == 1
      ? predicates[0] : NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
  }

  private static func anyOf(_ predicates: [NSPredicate]) -> NSPredicate {
    if predicates.count == 1 { return predicates[0] }
    return NSCompoundPredicate(orPredicateWithSubpredicates: predicates)
  }
}
