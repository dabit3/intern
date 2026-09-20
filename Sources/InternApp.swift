import AppKit
import SwiftUI

@main
struct InternApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
  @Environment(\.openSettings) private var openSettings

  var body: some Scene {
    MenuBarExtra("Intern", systemImage: "bolt.fill") {
      Button(delegate.hotKeyError == nil ? "Toggle Intern  ⌥Space" : "Toggle Intern") {
        delegate.togglePanel()
      }
      if let error = delegate.hotKeyError {
        Text("Option-Space unavailable").help(error)
      }
      Divider()
      Button("Settings…") {
        delegate.prepareForSettings()
        openSettings()
        delegate.raiseSettings()
      }
      Button("Quit Intern") { NSApplication.shared.terminate(nil) }
    }
    Settings {
      SettingsView(model: delegate.model, hotKeyError: delegate.hotKeyError)
        .background(SettingsWindowReader { delegate.attachSettingsWindow($0) })
    }
  }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
  let model = InternModel()
  private var panel: InternPanelIntern?
  private var hotKey: HotKey?
  private weak var settingsWindow: NSWindow?
  @Published private(set) var hotKeyError: String?

  func applicationDidFinishLaunching(_ notification: Notification) {
    guard NSClassFromString("XCTestCase") == nil else { return }
    panel = InternPanelIntern(model: model)
    hotKey = HotKey { [weak self] in self?.togglePanel() }
    hotKeyError = hotKey?.registrationError
    if ProcessInfo.processInfo.arguments.contains("--show") {
      togglePanel()
    }
  }

  func togglePanel() {
    panel?.toggle()
  }

  func prepareForSettings() {
    panel?.hide()
    NSApplication.shared.activate()
  }

  func attachSettingsWindow(_ window: NSWindow) {
    settingsWindow = window
    raiseSettings()
  }

  func raiseSettings() {
    guard let settingsWindow else { return }
    NSApplication.shared.activate()
    settingsWindow.deminiaturize(nil)
    settingsWindow.makeKeyAndOrderFront(nil)
  }
}

private struct SettingsWindowReader: NSViewRepresentable {
  let onWindow: (NSWindow) -> Void

  final class WindowView: NSView {
    var onWindow: ((NSWindow) -> Void)?

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      guard let window else { return }
      DispatchQueue.main.async { [weak self, weak window] in
        guard let self, let window, self.window === window else { return }
        self.onWindow?(window)
      }
    }
  }

  func makeNSView(context: Context) -> WindowView {
    let view = WindowView()
    view.onWindow = onWindow
    return view
  }

  func updateNSView(_ nsView: WindowView, context: Context) {
    nsView.onWindow = onWindow
  }
}

struct SettingsView: View {
  @ObservedObject var model: InternModel
  var hotKeyError: String? = nil
  @AppStorage(JevClient.apiKeyDefaultsKey) private var apiKey = ""
  @AppStorage("includeSpotlight") private var includeSpotlight = true
  @AppStorage("includeChromeHistory") private var includeHistory = true
  @AppStorage("localOnly") private var localOnly = false
  @State private var historyCleared = false

  var body: some View {
    Form {
      if let hotKeyError {
        Section("Keyboard shortcut") {
          Text(hotKeyError)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      Section("TypeSafe") {
        SecureField("API key", text: $apiKey)
        Text(
          ProcessInfo.processInfo.environment["TYPESAFE_API_KEY"] == nil
            ? "TYPESAFE_API_KEY is not set in the environment; the key above is used instead."
            : "TYPESAFE_API_KEY is set in the environment and takes precedence."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }
      Section("Search and privacy") {
        Toggle("Search files with Spotlight", isOn: $includeSpotlight)
        Toggle("Include Chrome browsing history", isOn: $includeHistory)
        Toggle("Keep searches on this Mac", isOn: $localOnly)
        Text(
          "Local mode disables online ranking. Otherwise only your query, context and a short list of candidate metadata are sent. File contents and clipboard text stay on this Mac."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }
      Section("Personal library") {
        Text(
          "Successful opens teach the launcher your preferences. Pins and saved workspaces appear before you type."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        Button(historyCleared ? "Launch history cleared" : "Clear launch history") {
          model.clearHistory()
          historyCleared = true
        }
        Text("Keeps your pins and saved workspaces. Does not change Chrome history.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Section("Permissions") {
        Text(
          "Dark Mode, Sleep and Empty Trash send Apple Events to System Events / Finder. macOS asks for Automation permission the first time."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
    .frame(width: 480)
    .padding()
    .onChange(of: includeSpotlight) { _, _ in model.preferencesChanged() }
    .onChange(of: includeHistory) { _, _ in model.preferencesChanged() }
    .onChange(of: localOnly) { _, _ in model.preferencesChanged() }
  }
}
