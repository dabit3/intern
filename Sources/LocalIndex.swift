import Darwin
import Foundation
import UniformTypeIdentifiers

/// Builds the local candidate index: application bundles, recent user files, system toggles,
/// user Shortcuts and Chrome history. Pure code, no model involved. Rebuilt in the background
/// when the panel opens.
struct LocalIndex: Sendable {
  var candidates: [Candidate]

  static let appDirectories = [
    "/Applications", "/System/Applications", "/System/Applications/Utilities",
    "/System/Volumes/Preboot/Cryptexes/App/System/Applications",
  ]
  static let systemApps = ["/System/Library/CoreServices/Finder.app"]
  static let fileDirectories = ["Downloads", "Desktop", "Documents"]
  static let maxFilesPerDirectory = 400
  static let maxScannedEntries = 4_000
  static let maxScanDepth = 8

  static func build(
    fileManager: FileManager = .default, now: Date = Date(), includeHistory: Bool = true
  ) -> LocalIndex {
    guard !Task.isCancelled else { return LocalIndex(candidates: []) }
    var candidates: [Candidate] = []
    candidates.append(contentsOf: scanApps(fileManager: fileManager))
    candidates.append(contentsOf: scanFiles(fileManager: fileManager, now: now))
    guard !Task.isCancelled else { return LocalIndex(candidates: candidates) }
    candidates.append(contentsOf: SystemToggle.allCases.map(\.candidate))
    candidates.append(contentsOf: scanShortcuts())
    if includeHistory, !Task.isCancelled {
      candidates.append(
        contentsOf: ChromeHistory.candidates(
          from: ChromeHistory.load(fileManager: fileManager, now: now), now: now))
    }
    return LocalIndex(candidates: candidates)
  }

  static func scanApps(fileManager: FileManager) -> [Candidate] {
    var seen = Set<String>()
    var apps: [Candidate] = []
    for directory in appDirectories + [
      fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path
    ] {
      guard !Task.isCancelled else { break }
      let root = URL(fileURLWithPath: directory)
      for url in scanURLs(root: root, fileManager: fileManager, appsOnly: true) {
        guard !Task.isCancelled else { break }
        appendApp(url, seen: &seen, apps: &apps)
      }
    }
    for path in systemApps {
      guard !Task.isCancelled else { break }
      if fileManager.fileExists(atPath: path) {
        appendApp(URL(fileURLWithPath: path), seen: &seen, apps: &apps)
      }
    }
    return apps
  }

  private struct AppMetadata: Decodable {
    struct URLType: Decodable {
      let schemes: [String]?
      enum CodingKeys: String, CodingKey { case schemes = "CFBundleURLSchemes" }
    }
    struct DocumentType: Decodable {
      let role: String?
      let contentTypes: [String]?
      enum CodingKeys: String, CodingKey {
        case role = "CFBundleTypeRole"
        case contentTypes = "LSItemContentTypes"
      }
    }
    let identifier: String?
    let category: String?
    let urlTypes: [URLType]?
    let documentTypes: [DocumentType]?
    enum CodingKeys: String, CodingKey {
      case identifier = "CFBundleIdentifier"
      case category = "LSApplicationCategoryType"
      case urlTypes = "CFBundleURLTypes"
      case documentTypes = "CFBundleDocumentTypes"
    }
  }

  private static func appendApp(_ url: URL, seen: inout Set<String>, apps: inout [Candidate]) {
    let url = url.standardizedFileURL.resolvingSymlinksInPath()
    let data = try? Data(contentsOf: url.appendingPathComponent("Contents/Info.plist"))
    let metadata = data.flatMap { try? PropertyListDecoder().decode(AppMetadata.self, from: $0) }
    let identity = metadata?.identifier.flatMap { $0.isEmpty ? nil : $0 } ?? url.path
    guard seen.insert(identity).inserted else { return }
    var keywords = ["app", "application"]
    if let category = metadata?.category,
      category.hasPrefix("public.app-category.")
    {
      keywords += category.dropFirst("public.app-category.".count).split(separator: "-").map(
        String.init)
    }
    let schemes = Set(
      (metadata?.urlTypes ?? []).flatMap { $0.schemes ?? [] }.map {
        $0.lowercased()
      })
    if schemes.contains("http"), schemes.contains("https") { keywords += ["browser", "web"] }
    if schemes.contains("mailto") { keywords += ["email", "mail"] }
    for document in metadata?.documentTypes ?? []
    where document.role == "Editor" {
      if (document.contentTypes ?? []).contains(where: {
        UTType($0)?.conforms(to: .sourceCode) == true
      }) {
        keywords += ["code", "editor", "development"]
        break
      }
    }
    apps.append(
      Candidate(
        id: "app:\(url.path)", title: url.deletingPathExtension().lastPathComponent,
        subtitle: "Application", kind: .openApp, keywords: keywords, payload: .app(url)))
  }

  private static func scanURLs(root: URL, fileManager: FileManager, appsOnly: Bool) -> [URL] {
    if (try? root.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true {
      return []
    }
    let keys: Set<URLResourceKey> = [
      .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .isHiddenKey, .isPackageKey,
    ]
    var directories = [(root, 0)]
    var next = 0
    var inspected = 0
    var urls: [URL] = []
    while next < directories.count, inspected < maxScannedEntries, !Task.isCancelled {
      let (directory, depth) = directories[next]
      next += 1
      guard
        let children = try? fileManager.contentsOfDirectory(
          at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
      else { continue }
      for url in children {
        guard inspected < maxScannedEntries, !Task.isCancelled else { break }
        inspected += 1
        let name = url.lastPathComponent.lowercased()
        guard !name.hasPrefix("."), name != "library", name != "node_modules",
          let values = try? url.resourceValues(forKeys: keys),
          values.isHidden != true, values.isSymbolicLink != true
        else { continue }
        let isApp = url.pathExtension.lowercased() == "app"
        if isApp {
          if appsOnly, values.isDirectory == true { urls.append(url) }
          continue
        }
        if !appsOnly, values.isRegularFile == true || values.isDirectory == true {
          urls.append(url)
        }
        if values.isDirectory == true, values.isPackage != true, depth < maxScanDepth {
          directories.append((url, depth + 1))
        }
      }
    }
    return urls
  }

  static func scanFiles(fileManager: FileManager, now: Date) -> [Candidate] {
    let home = fileManager.homeDirectoryForCurrentUser
    var files: [Candidate] = []
    var seen = Set<String>()
    for folder in fileDirectories {
      guard !Task.isCancelled else { break }
      let root = home.appendingPathComponent(folder)
      if let values = try? root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
        values.isDirectory == true, values.isSymbolicLink != true
      {
        let candidate = fileCandidate(url: root, folder: folder, now: now)
        if seen.insert(candidate.id).inserted { files.append(candidate) }
      }
      let urls = scanURLs(root: root, fileManager: fileManager, appsOnly: false)
      guard !Task.isCancelled else { break }
      var candidates: [Candidate] = []
      for url in urls {
        guard !Task.isCancelled else { break }
        candidates.append(fileCandidate(url: url, folder: folder, now: now))
      }
      for candidate in recentFiles(candidates) {
        guard !Task.isCancelled else { break }
        if seen.insert(candidate.id).inserted { files.append(candidate) }
      }
    }
    return files
  }

  static func recentFiles(_ candidates: [Candidate]) -> [Candidate] {
    candidates.sorted {
      let lhs =
        [$0.modifiedAt, $0.addedAt, $0.lastOpenedAt].compactMap { $0 }.max() ?? .distantPast
      let rhs =
        [$1.modifiedAt, $1.addedAt, $1.lastOpenedAt].compactMap { $0 }.max() ?? .distantPast
      return lhs == rhs ? $0.id < $1.id : lhs > rhs
    }.prefix(maxFilesPerDirectory).map { $0 }
  }

  static func fileCandidate(
    url: URL, folder: String, now: Date, metadata: NSMetadataItem? = nil
  ) -> Candidate {
    let url = url.standardizedFileURL
    let values = try? url.resourceValues(forKeys: [
      .isDirectoryKey, .contentModificationDateKey, .addedToDirectoryDateKey,
    ])
    let isDirectory = values?.isDirectory ?? false
    let modified = values?.contentModificationDate
    let item = metadata ?? NSMetadataItem(url: url)
    let lastOpened = item?.value(forAttribute: "kMDItemLastUsedDate") as? Date
    let added =
      item?.value(forAttribute: "kMDItemDateAdded") as? Date ?? values?.addedToDirectoryDate
    let ageDays = modified.map { max(0, now.timeIntervalSince($0)) / 86_400 }
    let ext = url.pathExtension.lowercased()
    var keywords = [folder.lowercased(), "file"]
    if folder == "Downloads" || url.deletingLastPathComponent().pathComponents.contains("Downloads")
    {
      keywords.append(contentsOf: ["downloads", "downloaded", "download"])
    }
    if isDirectory {
      keywords.append("folder")
    } else if !ext.isEmpty {
      keywords.append(ext)
      keywords.append(contentsOf: fileTypeWords(ext))
    }
    if let ageDays, ageDays < 1 {
      keywords.append(contentsOf: ["recent", "latest", "new", "today"])
    }
    if !isDirectory, fileTypeWords(ext).contains("image"),
      url.lastPathComponent.lowercased().contains("screenshot")
        || url.lastPathComponent.lowercased().contains("screen shot")
    {
      keywords.append("screenshot")
    }
    let parent = url.deletingLastPathComponent().path
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let location = parent.hasPrefix(home + "/") ? "~" + parent.dropFirst(home.count) : parent
    var subtitle = "\(isDirectory ? "Folder" : fileTypeLabel(ext)) in \(location)"
    if let lastOpened {
      subtitle +=
        " · "
        + recency(max(0, now.timeIntervalSince(lastOpened)) / 86_400)
        .replacingOccurrences(of: "modified", with: "opened")
    }
    if let added {
      subtitle +=
        " · "
        + recency(max(0, now.timeIntervalSince(added)) / 86_400)
        .replacingOccurrences(of: "modified", with: "added")
    }
    if let ageDays { subtitle += " · \(recency(ageDays))" }
    return Candidate(
      id: "file:\(url.path)", title: url.lastPathComponent, subtitle: subtitle, kind: .openFile,
      keywords: keywords, payload: .file(url), ageDays: ageDays, modifiedAt: modified,
      lastOpenedAt: lastOpened, addedAt: added)
  }

  static func fileTypeWords(_ ext: String) -> [String] {
    switch ext.lowercased() {
    case "pdf": return ["document", "paper"]
    case "doc", "docx", "pages", "odt": return ["document", "text"]
    case "ppt", "pptx", "key", "odp": return ["presentation", "slides", "deck"]
    case "png", "jpg", "jpeg", "gif", "heic", "webp", "tif", "tiff", "svg", "avif":
      return ["image", "picture", "photo"]
    case "mov", "mp4", "m4v", "mkv", "webm": return ["video", "movie", "recording"]
    case "mp3", "m4a", "wav", "aiff", "flac", "aac": return ["audio", "music", "recording"]
    case "zip", "tar", "gz", "bz2", "xz", "7z", "rar": return ["archive", "compressed"]
    case "dmg", "pkg": return ["installer"]
    case "md", "txt", "rtf", "rtfd": return ["document", "text", "notes"]
    case "csv", "xls", "xlsx", "numbers", "ods": return ["spreadsheet", "data"]
    case "swift", "ts", "js", "py": return ["code", "source"]
    default: return []
    }
  }

  static func fileTypeLabel(_ ext: String) -> String {
    ext.isEmpty ? "File" : ext.uppercased()
  }

  /// A human-readable recency phrase. Jev reads recency far better as words than as timestamps.
  static func recency(_ ageDays: Double) -> String {
    let minutes = ageDays * 24 * 60
    if minutes < 2 { return "modified just now" }
    if minutes < 60 { return "modified \(Int(minutes)) min ago" }
    if ageDays < 1 { return "modified \(Int(minutes / 60)) h ago" }
    if ageDays < 2 { return "modified yesterday" }
    if ageDays < 30 { return "modified \(plural(Int(ageDays), "day")) ago" }
    if ageDays < 365 { return "modified \(plural(Int(ageDays / 30), "month")) ago" }
    return "modified over a year ago"
  }

  private static func plural(_ count: Int, _ unit: String) -> String {
    count == 1 ? "1 \(unit)" : "\(count) \(unit)s"
  }

  static func scanShortcuts(
    executableURL: URL = URL(fileURLWithPath: "/usr/bin/shortcuts"),
    arguments: [String] = ["list"], timeout: TimeInterval = 2
  ) -> [Candidate] {
    guard !Task.isCancelled else { return [] }
    let process = Process()
    process.executableURL = executableURL
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    defer {
      try? pipe.fileHandleForReading.close()
      try? pipe.fileHandleForWriting.close()
    }
    let descriptor = pipe.fileHandleForReading.fileDescriptor
    guard fcntl(descriptor, F_SETFL, O_NONBLOCK) != -1 else { return [] }
    do { try process.run() } catch { return [] }
    try? pipe.fileHandleForWriting.close()
    defer {
      if process.isRunning { kill(process.processIdentifier, SIGKILL) }
      process.waitUntilExit()
    }
    let deadline = ProcessInfo.processInfo.systemUptime + timeout
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 8_192)
    while true {
      guard !Task.isCancelled, ProcessInfo.processInfo.systemUptime < deadline else { return [] }
      let count = read(descriptor, &buffer, buffer.count)
      if count > 0 {
        guard data.count + count <= 262_144 else { return [] }
        data.append(contentsOf: buffer.prefix(count))
      } else {
        if count < 0, errno != EAGAIN, errno != EINTR { return [] }
        if !process.isRunning { break }
        Thread.sleep(forTimeInterval: 0.01)
      }
    }
    process.waitUntilExit()
    guard process.terminationStatus == 0, let output = String(data: data, encoding: .utf8) else {
      return []
    }
    var seen = Set<String>()
    return output.split(separator: "\n").map(String.init).filter {
      !$0.isEmpty && seen.insert($0).inserted
    }.prefix(200).map {
      name in
      Candidate(
        id: "shortcut:\(name)", title: name, subtitle: "Shortcut", kind: .runShortcut,
        keywords: ["shortcut", "automation"], payload: .shortcut(name))
    }
  }
}

actor LocalIndexScanner {
  static let shared = LocalIndexScanner()

  func build(includeHistory: Bool) -> LocalIndex {
    LocalIndex.build(includeHistory: includeHistory)
  }
}
