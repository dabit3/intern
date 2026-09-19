import AppKit
import Combine
import SwiftUI

/// Borderless windows refuse key status by default; a launcher must accept it to receive typing.
final class KeyablePanel: NSPanel {
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }
}

/// A floating, non-activating panel that sits above every window and every Space, like Spotlight.
@MainActor
final class LauncherPanelController: NSObject, NSWindowDelegate {
  static let panelWidth: CGFloat = 680
  static let headerHeight: CGFloat = 72
  static let rowHeight: CGFloat = 56
  static let footerHeight: CGFloat = 40
  static let maxRows = 7
  static let emptyHeight: CGFloat = 76

  /// The panel grows and shrinks with its content, like Spotlight, instead of sitting in a fixed box.
  static func height(rows: Int, empty: Bool) -> CGFloat {
    let body = empty ? emptyHeight : rowHeight * CGFloat(min(max(rows, 1), maxRows)) + 12
    return headerHeight + body + footerHeight
  }

  let model: LauncherModel
  private let panel: KeyablePanel
  private var keyMonitor: Any?
  private var subscriptions: Set<AnyCancellable> = []

  init(model: LauncherModel) {
    self.model = model
    panel = KeyablePanel(
      contentRect: NSRect(
        x: 0, y: 0, width: Self.panelWidth, height: Self.height(rows: 0, empty: true)),
      styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView], backing: .buffered,
      defer: false)
    super.init()
    panel.level = .floating
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.isMovableByWindowBackground = true
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
    panel.hidesOnDeactivate = false
    panel.becomesKeyOnlyIfNeeded = false
    panel.delegate = self
    let host = NSHostingView(rootView: LauncherView(model: model))
    host.frame = panel.contentView?.bounds ?? .zero
    host.autoresizingMask = [.width, .height]
    panel.contentView = host
    model.onExecute = { [weak self] in self?.hide() }
    model.$hits.combineLatest(model.$query)
      .map { hits, query in
        Self.height(rows: hits.count, empty: query.trimmingCharacters(in: .whitespaces).isEmpty)
      }
      .removeDuplicates()
      .sink { [weak self] height in self?.resize(to: height) }
      .store(in: &subscriptions)
  }

  /// Keeps the top edge pinned so the query field never jumps while the list changes size.
  private func resize(to height: CGFloat) {
    guard panel.isVisible else { return }
    var frame = panel.frame
    frame.origin.y += frame.height - height
    frame.size.height = height
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.16
      context.timingFunction = CAMediaTimingFunction(name: .easeOut)
      panel.animator().setFrame(frame, display: true)
    }
  }

  var isVisible: Bool { panel.isVisible }

  func toggle() {
    if panel.isVisible { hide() } else { show() }
  }

  func show() {
    model.panelWillShow()
    if let screen = NSScreen.main {
      let frame = screen.visibleFrame
      let height = Self.height(rows: 0, empty: true)
      let top = frame.midY + frame.height * 0.22
      panel.setFrame(
        NSRect(
          x: frame.midX - Self.panelWidth / 2, y: top - height, width: Self.panelWidth,
          height: height),
        display: false)
    }
    panel.makeKeyAndOrderFront(nil)
    installKeyMonitor()
  }

  func hide() {
    panel.orderOut(nil)
    removeKeyMonitor()
    model.reset()
  }

  func windowDidResignKey(_ notification: Notification) {
    hide()
  }

  private func installKeyMonitor() {
    removeKeyMonitor()
    keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      guard let self, self.panel.isVisible else { return event }
      switch event.keyCode {
      case 53:  // Escape
        self.hide()
        return nil
      case 125:  // Down
        self.model.moveSelection(by: 1)
        return nil
      case 126:  // Up
        self.model.moveSelection(by: -1)
        return nil
      case 36, 76:  // Return, keypad Enter
        self.model.executeSelection()
        return nil
      default:
        return event
      }
    }
  }

  private func removeKeyMonitor() {
    if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    keyMonitor = nil
  }
}
