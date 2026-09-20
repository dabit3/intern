import AppKit
import Darwin
import Foundation

/// Runs the chosen candidate. All execution is code; Jev only picks.
enum Executor {
  struct Outcome: Sendable {
    let succeeded: Bool
    let message: String
  }

  @MainActor
  struct Environment {
    var application: (URL) -> URL? = { NSWorkspace.shared.urlForApplication(toOpen: $0) }
    var openApplication: (URL) async -> Outcome = { url in
      await withCheckedContinuation { continuation in
        NSWorkspace.shared.openApplication(at: url, configuration: .init()) { _, error in
          continuation.resume(
            returning: Outcome(
              succeeded: error == nil, message: error?.localizedDescription ?? "Opened"))
        }
      }
    }
    var openURLs: ([URL], URL) async -> Outcome = { urls, application in
      await open(urls, application: application)
    }
    var copy: (String) -> Bool = { text in
      NSPasteboard.general.clearContents()
      return NSPasteboard.general.setString(text, forType: .string)
    }
  }

  @MainActor
  static func perform(_ candidate: Candidate) async -> Outcome {
    await perform(candidate, using: Environment())
  }

  @MainActor
  static func perform(_ candidate: Candidate, using environment: Environment) async -> Outcome {
    guard !Task.isCancelled else { return cancelled }
    if let problem = validationError(candidate) {
      return Outcome(succeeded: false, message: problem)
    }
    switch candidate.payload {
    case .app(let url):
      let outcome = await environment.openApplication(url)
      return outcome.succeeded
        ? Outcome(succeeded: true, message: "Opened \(candidate.title)") : outcome
    case .file(let url), .url(let url):
      return await open([url], using: environment)
    case .group(let members):
      let members = uniqueMembers(members)
      var batches: [(application: URL, urls: [URL])] = []
      for member in members {
        if case .url(let url) = member.payload {
          guard let application = environment.application(url) else { return noApplication }
          if let index = batches.firstIndex(where: { $0.application == application }) {
            batches[index].urls.append(url)
          } else {
            batches.append((application, [url]))
          }
        } else if case .file(let url) = member.payload, environment.application(url) == nil {
          return noApplication
        }
      }
      var failures: [String] = []
      for member in members {
        guard !Task.isCancelled else { return cancelled }
        if case .url = member.payload {
          continue
        } else {
          let outcome = await perform(member, using: environment)
          if !outcome.succeeded { failures.append(outcome.message) }
        }
      }
      for batch in batches {
        guard !Task.isCancelled else { return cancelled }
        let outcome = await environment.openURLs(batch.urls, batch.application)
        if !outcome.succeeded { failures.append(outcome.message) }
      }
      return Outcome(
        succeeded: failures.isEmpty,
        message: failures.isEmpty
          ? "Opened \(members.count) items" : failures.joined(separator: "; "))
    case .webSearch(let query):
      var components = URLComponents(string: "https://www.google.com/search")!
      components.queryItems = [URLQueryItem(name: "q", value: query)]
      guard let url = components.url else {
        return Outcome(succeeded: false, message: "Could not build the search URL.")
      }
      return await open([url], using: environment)
    case .calculation(_, let result):
      let copied = environment.copy(result)
      return Outcome(
        succeeded: copied, message: copied ? "Copied \(result)" : "Could not copy result.")
    case .shortcut(let name):
      return await inBackground {
        command("/usr/bin/shortcuts", ["run", name], success: "Ran shortcut \(name)")
      }
    case .toggle(.doNotDisturb):
      let url = URL(string: "x-apple.systempreferences:com.apple.Focus-Settings.extension")!
      let opened = NSWorkspace.shared.open(url)
      return Outcome(
        succeeded: opened,
        message: opened ? "Opened Focus settings" : "Could not open Focus settings.")
    case .toggle(let toggle):
      return await inBackground { performToggle(toggle) }
    }
  }

  static func validationError(_ candidate: Candidate) -> String? {
    switch candidate.payload {
    case .file(let url), .app(let url):
      guard url.isFileURL, (url.host ?? "").isEmpty || url.host == "localhost",
        FileManager.default.fileExists(atPath: url.path)
      else { return "\(candidate.title) is no longer at its saved location." }
      if case .app = candidate.payload,
        (try? url.resourceValues(forKeys: [.isApplicationKey]).isApplication) != true
      {
        return "\(candidate.title) is not an application."
      }
      return nil
    case .url(let url):
      return ["https", "http"].contains(url.scheme?.lowercased() ?? "")
        && !(url.host ?? "").isEmpty
        && (url.port.map { (1...65_535).contains($0) } ?? true)
        ? nil : "Only HTTP and HTTPS links with a valid host can be opened."
    case .group(let members):
      if let problem = groupValidationError(members) { return problem }
      return members.compactMap(validationError).first
    case .shortcut(let name):
      return name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        ? "This shortcut has no name." : nil
    case .webSearch(let query):
      return query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        ? "Enter a search query." : nil
    default: return nil
    }
  }

  static func copyText(_ candidate: Candidate) -> String? {
    switch candidate.payload {
    case .file(let url), .app(let url): return url.path
    case .url(let url): return url.absoluteString
    case .calculation(_, let result): return result
    case .group(let members):
      guard groupValidationError(members) == nil else { return nil }
      return uniqueMembers(members).compactMap(copyText).joined(separator: "\n")
    default: return nil
    }
  }

  private static func groupValidationError(_ members: [Candidate]) -> String? {
    guard !members.isEmpty, members.count <= Ranker.maximumSetSize,
      members.allSatisfy(\.isOpenable)
    else { return "This group does not contain a valid set of files, apps or links." }
    var identities: [String: Candidate.Payload] = [:]
    for member in members {
      if let payload = identities[member.id], payload != member.payload {
        return "This group contains conflicting items."
      }
      identities[member.id] = member.payload
    }
    return nil
  }

  private static func uniqueMembers(_ members: [Candidate]) -> [Candidate] {
    var seen: Set<URL> = []
    return members.filter { member in
      switch member.payload {
      case .app(let url), .file(let url):
        return seen.insert(url.standardizedFileURL).inserted
      case .url(let url): return seen.insert(url).inserted
      default: return false
      }
    }
  }

  private static var cancelled: Outcome {
    Outcome(succeeded: false, message: "Action cancelled.")
  }

  private static var noApplication: Outcome {
    Outcome(succeeded: false, message: "No application is available to open this item.")
  }

  @MainActor
  private static func open(_ urls: [URL], using environment: Environment) async -> Outcome {
    guard let first = urls.first, let application = environment.application(first) else {
      return noApplication
    }
    guard !Task.isCancelled else { return cancelled }
    return await environment.openURLs(urls, application)
  }

  static func inBackground(_ operation: @escaping @Sendable () -> Outcome) async -> Outcome {
    let worker = Task.detached { operation() }
    return await withTaskCancellationHandler {
      if Task.isCancelled { worker.cancel() }
      return await worker.value
    } onCancel: {
      worker.cancel()
    }
  }

  @MainActor
  private static func open(_ urls: [URL], application: URL?) async -> Outcome {
    guard let application else {
      return Outcome(succeeded: false, message: "No application is available to open this item.")
    }
    return await withCheckedContinuation { continuation in
      NSWorkspace.shared.open(urls, withApplicationAt: application, configuration: .init()) {
        _, error in
        continuation.resume(
          returning: Outcome(
            succeeded: error == nil, message: error?.localizedDescription ?? "Opened"))
      }
    }
  }

  private static func performToggle(_ toggle: SystemToggle) -> Outcome {
    switch toggle {
    case .toggleDarkMode:
      return command(
        "/usr/bin/osascript",
        [
          "-e",
          "tell application \"System Events\" to tell appearance preferences to set dark mode to not dark mode",
        ], success: "Toggled Dark Mode")
    case .wifiOn, .wifiOff:
      guard let device = wifiDevice() else {
        return Outcome(succeeded: false, message: "No Wi-Fi interface found on this Mac")
      }
      return command(
        "/usr/sbin/networksetup", ["-setairportpower", device, toggle == .wifiOn ? "on" : "off"],
        success: toggle == .wifiOn ? "Wi-Fi on" : "Wi-Fi off")
    case .doNotDisturb:
      return Outcome(succeeded: false, message: "Open Focus settings from the launcher.")
    case .sleep:
      return command(
        "/usr/bin/osascript", ["-e", "tell application \"System Events\" to sleep"],
        success: "Sleeping")
    case .lockScreen:
      return command(
        "/System/Library/CoreServices/Menu Extras/User.menu/Contents/Resources/CGSession",
        ["-suspend"], success: "Locking screen")
    case .emptyTrash:
      return command(
        "/usr/bin/osascript", ["-e", "tell application \"Finder\" to empty trash"],
        success: "Emptied Trash")
    case .showHiddenFiles, .hideHiddenFiles:
      let value = toggle == .showHiddenFiles ? "true" : "false"
      let result = command(
        "/usr/bin/defaults", ["write", "com.apple.finder", "AppleShowAllFiles", "-bool", value],
        success: "Updated Finder")
      guard result.succeeded else { return result }
      return command(
        "/usr/bin/killall", ["Finder"],
        success: toggle == .showHiddenFiles ? "Showing hidden files" : "Hiding hidden files")
    }
  }

  /// The BSD device name of the Wi-Fi hardware port, parsed from `networksetup`.
  static func wifiDevice() -> String? {
    guard let output = run("/usr/sbin/networksetup", ["-listallhardwareports"]) else { return nil }
    return parseWifiDevice(output)
  }

  static func parseWifiDevice(_ listing: String) -> String? {
    var sawWifi = false
    for line in listing.split(separator: "\n") {
      if line.hasPrefix("Hardware Port:") {
        sawWifi = line.contains("Wi-Fi") || line.contains("AirPort")
      } else if sawWifi, line.hasPrefix("Device:") {
        return line.dropFirst("Device:".count).trimmingCharacters(in: .whitespaces)
      }
    }
    return nil
  }

  @discardableResult
  static func run(_ executable: String, _ arguments: [String]) -> String? {
    runProcess(executable, arguments).output
  }

  struct ProcessResult: Sendable {
    let output: String?
    let error: String?
  }

  static func runProcess(_ executable: String, _ arguments: [String], timeout: TimeInterval = 30)
    -> ProcessResult
  {
    guard !Task.isCancelled else { return ProcessResult(output: nil, error: cancelled.message) }
    guard timeout.isFinite, timeout > 0 else {
      return ProcessResult(output: nil, error: "Invalid action timeout.")
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardInput = FileHandle.nullDevice
    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr
    defer {
      try? stdout.fileHandleForReading.close()
      try? stderr.fileHandleForReading.close()
      try? stdout.fileHandleForWriting.close()
      try? stderr.fileHandleForWriting.close()
    }
    for pipe in [stdout, stderr] {
      let descriptor = pipe.fileHandleForReading.fileDescriptor
      guard fcntl(descriptor, F_SETFL, O_NONBLOCK) != -1 else {
        return ProcessResult(output: nil, error: "Could not read action output.")
      }
    }
    do {
      try process.run()
    } catch {
      return ProcessResult(output: nil, error: error.localizedDescription)
    }
    try? stdout.fileHandleForWriting.close()
    try? stderr.fileHandleForWriting.close()
    let started = ProcessInfo.processInfo.systemUptime
    var terminationRequested: TimeInterval?
    var failure: String?
    var output = OutputBuffer()
    var errors = OutputBuffer()
    while true {
      let readOutput = output.read(stdout.fileHandleForReading.fileDescriptor)
      let readErrors = errors.read(stderr.fileHandleForReading.fileDescriptor)
      let now = ProcessInfo.processInfo.systemUptime
      if failure == nil {
        if Task.isCancelled {
          failure = cancelled.message
        } else if now - started >= timeout {
          failure = "The action timed out."
        } else {
          failure = output.error ?? errors.error
        }
      }
      if !process.isRunning {
        if failure != nil || (!readOutput && !readErrors) { break }
        continue
      }
      if failure != nil {
        if let terminationRequested {
          if now - terminationRequested >= 0.25 {
            kill(process.processIdentifier, SIGKILL)
          }
        } else {
          process.terminate()
          terminationRequested = now
        }
      }
      var descriptors = [
        pollfd(
          fd: output.ended ? -1 : stdout.fileHandleForReading.fileDescriptor, events: Int16(POLLIN),
          revents: 0),
        pollfd(
          fd: errors.ended ? -1 : stderr.fileHandleForReading.fileDescriptor, events: Int16(POLLIN),
          revents: 0),
      ]
      _ = poll(&descriptors, nfds_t(descriptors.count), 20)
    }
    process.waitUntilExit()
    if let failure { return ProcessResult(output: nil, error: failure) }
    guard process.terminationStatus == 0, process.terminationReason == .exit else {
      let detail = String(decoding: errors.data, as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
      let message =
        detail.isEmpty
        ? "The action exited with status \(process.terminationStatus)."
        : String(detail.prefix(2048))
      return ProcessResult(output: nil, error: message)
    }
    guard let text = String(data: output.data, encoding: .utf8) else {
      return ProcessResult(output: nil, error: "The action returned unreadable output.")
    }
    return ProcessResult(output: text, error: nil)
  }

  private struct OutputBuffer {
    var data = Data()
    var ended = false
    var error: String?

    mutating func read(_ descriptor: Int32) -> Bool {
      guard !ended else { return false }
      var buffer = [UInt8](repeating: 0, count: 16_384)
      let count = Darwin.read(descriptor, &buffer, buffer.count)
      if count > 0 {
        if data.count + count <= 1_048_576 {
          data.append(contentsOf: buffer.prefix(count))
        } else {
          error = "The action produced too much output."
        }
        return true
      }
      if count == 0 {
        ended = true
      } else if errno != EAGAIN && errno != EINTR {
        ended = true
        error = "Could not read action output."
      }
      return false
    }
  }

  static func command(_ executable: String, _ arguments: [String], success: String)
    -> Outcome
  {
    let result = runProcess(executable, arguments)
    return Outcome(
      succeeded: result.output != nil,
      message: result.output != nil ? success : result.error ?? "Could not complete the action.")
  }
}
