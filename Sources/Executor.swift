import AppKit
import Foundation

/// Runs the chosen candidate. All execution is code; Jev only picks.
enum Executor {
  @MainActor
  static func execute(_ candidate: Candidate) -> String {
    switch candidate.payload {
    case .app(let url):
      NSWorkspace.shared.openApplication(at: url, configuration: .init()) { _, _ in }
      return "Opened \(candidate.title)"
    case .file(let url):
      NSWorkspace.shared.open(url)
      return "Opened \(candidate.title)"
    case .url(let url):
      openInBrowser([url])
      return "Opened \(candidate.title)"
    case .group(let members):
      return executeGroup(members)
    case .webSearch(let query):
      var components = URLComponents(string: "https://www.google.com/search")!
      components.queryItems = [URLQueryItem(name: "q", value: query)]
      if let url = components.url { NSWorkspace.shared.open(url) }
      return "Searching the web for “\(query)”"
    case .calculation(_, let result):
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(result, forType: .string)
      return "Copied \(result)"
    case .shortcut(let name):
      run("/usr/bin/shortcuts", ["run", name])
      return "Running shortcut \(name)"
    case .toggle(let toggle):
      return performToggle(toggle)
    }
  }

  /// Opens every member. Web pages go to the browser in one call so they land as tabs of one
  /// window; everything else runs through the normal single-item path.
  @MainActor
  static func executeGroup(_ members: [Candidate]) -> String {
    var urls: [URL] = []
    var others: [Candidate] = []
    for member in members {
      if case .url(let url) = member.payload { urls.append(url) } else { others.append(member) }
    }
    if !urls.isEmpty { openInBrowser(urls) }
    for other in others { _ = execute(other) }
    return "Opened \(members.count) items"
  }

  static let chromeBundleID = "com.google.Chrome"

  /// History comes from Chrome, so pages reopen there when it is installed; otherwise the
  /// default browser. URLs are passed as values, never through a shell.
  @MainActor
  static func openInBrowser(_ urls: [URL]) {
    if let chrome = NSWorkspace.shared.urlForApplication(withBundleIdentifier: chromeBundleID) {
      NSWorkspace.shared.open(urls, withApplicationAt: chrome, configuration: .init()) {
        _, _ in
      }
    } else {
      for url in urls { NSWorkspace.shared.open(url) }
    }
  }

  static func performToggle(_ toggle: SystemToggle) -> String {
    switch toggle {
    case .toggleDarkMode:
      osascript(
        "tell application \"System Events\" to tell appearance preferences to set dark mode to not dark mode"
      )
      return "Toggled Dark Mode"
    case .wifiOn, .wifiOff:
      guard let device = wifiDevice() else {
        return "No Wi-Fi interface found on this Mac"
      }
      run("/usr/sbin/networksetup", ["-setairportpower", device, toggle == .wifiOn ? "on" : "off"])
      return toggle == .wifiOn ? "Wi-Fi on" : "Wi-Fi off"
    case .doNotDisturb:
      if let url = URL(string: "x-apple.systempreferences:com.apple.Focus-Settings.extension") {
        NSWorkspace.shared.open(url)
      }
      return "Opened Focus settings"
    case .sleep:
      osascript("tell application \"System Events\" to sleep")
      return "Sleeping"
    case .lockScreen:
      run(
        "/System/Library/CoreServices/Menu Extras/User.menu/Contents/Resources/CGSession",
        ["-suspend"])
      return "Locking screen"
    case .emptyTrash:
      osascript("tell application \"Finder\" to empty trash")
      return "Emptied Trash"
    case .showHiddenFiles, .hideHiddenFiles:
      let value = toggle == .showHiddenFiles ? "true" : "false"
      run("/usr/bin/defaults", ["write", "com.apple.finder", "AppleShowAllFiles", "-bool", value])
      run("/usr/bin/killall", ["Finder"])
      return toggle == .showHiddenFiles ? "Showing hidden files" : "Hiding hidden files"
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
  static func osascript(_ script: String) -> String? {
    run("/usr/bin/osascript", ["-e", script])
  }

  @discardableResult
  static func run(_ executable: String, _ arguments: [String]) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(data: data, encoding: .utf8)
  }
}
