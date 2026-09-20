import AppKit
import Combine
import Quartz
import SwiftUI

/// Borderless windows refuse key status by default; a launcher must accept it to receive typing.
final class KeyablePanel: NSPanel {
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }
}

final class PreviewPanel: NSPanel {
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }
}

/// A floating, non-activating panel that sits above every window and every Space, like Spotlight.
@MainActor
final class InternPanelIntern: NSObject, NSWindowDelegate {
  static let panelWidth: CGFloat = 680
  static let headerHeight: CGFloat = 72
  static let scopeHeight: CGFloat = 40
  static let rowHeight: CGFloat = 56
  static let footerHeight: CGFloat = 40
  static let maxRows = 7
  static let emptyHeight: CGFloat = 96
  static let feedbackHeight: CGFloat = 32

  /// The panel grows and shrinks with its content, like Spotlight, instead of sitting in a fixed box.
  static func height(rows: Int, empty: Bool) -> CGFloat {
    let body = empty ? emptyHeight : rowHeight * CGFloat(min(max(rows, 1), maxRows)) + 12
    return headerHeight + scopeHeight + body + footerHeight
  }

  static func height(for model: InternModel) -> CGFloat {
    let overlay = model.confirmation != nil || model.savingWorkspace
    let rows = overlay ? 3 : model.actionsVisible ? 6 : model.hits.count
    return height(rows: rows, empty: !overlay && !model.actionsVisible && model.hits.isEmpty)
      + (model.lastError != nil || model.status != nil || model.isExecuting ? feedbackHeight : 0)
  }

  static func fitting(_ frame: NSRect, in screen: NSRect) -> NSRect {
    var fitted = frame
    fitted.size.height = min(frame.height, screen.height)
    fitted.size.width = min(frame.width, screen.width)
    fitted.origin.x = min(max(frame.minX, screen.minX), screen.maxX - fitted.width)
    fitted.origin.y = min(max(frame.minY, screen.minY), screen.maxY - fitted.height)
    return fitted
  }

  let model: InternModel
  private let panel: KeyablePanel
  private var keyMonitor: AnyCancellable?
  private var subscriptions: Set<AnyCancellable> = []
  private var previewWindow: NSWindow?
  private var isHiding = false
  var terminate: () -> Void = { NSApplication.shared.terminate(nil) }

  init(model: InternModel) {
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
    let host = NSHostingView(rootView: InternView(model: model))
    host.frame = panel.contentView?.bounds ?? .zero
    host.autoresizingMask = [.width, .height]
    panel.contentView = host
    model.onExecute = { [weak self] in self?.hide() }
    model.onExecutionFailure = { [weak self] in
      guard let self, self.panel.isVisible, self.previewWindow == nil else { return }
      self.panel.makeKeyAndOrderFront(nil)
    }
    model.onPreview = { [weak self] url in self?.preview(url) }
    model.objectWillChange
      .receive(on: RunLoop.main)
      .map { [weak model] _ in
        guard let model else { return Self.height(rows: 0, empty: true) }
        return Self.height(for: model)
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
    if let screen = panel.screen { frame = Self.fitting(frame, in: screen.visibleFrame) }
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
      let height = Self.height(for: model)
      let top = frame.midY + frame.height * 0.22
      panel.setFrame(
        Self.fitting(
          NSRect(
            x: frame.midX - Self.panelWidth / 2, y: top - height, width: Self.panelWidth,
            height: height), in: frame),
        display: false)
    }
    panel.makeKeyAndOrderFront(nil)
    installKeyMonitor()
  }

  func hide() {
    guard !isHiding else { return }
    isHiding = true
    removeKeyMonitor()
    let preview = previewWindow
    previewWindow = nil
    preview?.close()
    panel.orderOut(nil)
    model.reset()
    isHiding = false
  }

  func windowDidResignKey(_ notification: Notification) {
    guard !isHiding, !model.isExecuting, let window = notification.object as? NSWindow else {
      return
    }
    if window === previewWindow {
      DispatchQueue.main.async { [weak self] in
        guard let self, let preview = self.previewWindow,
          !self.panel.isKeyWindow, !preview.isKeyWindow, !self.model.isExecuting
        else { return }
        self.hide()
      }
    } else if window === panel, previewWindow == nil {
      hide()
    }
  }

  func windowWillClose(_ notification: Notification) {
    guard let window = notification.object as? NSWindow, window === previewWindow else { return }
    previewWindow = nil
    if !isHiding, panel.isVisible { panel.makeKeyAndOrderFront(nil) }
  }

  private func preview(_ url: URL) {
    let window = PreviewPanel(
      contentRect: NSRect(x: 0, y: 0, width: 640, height: 560),
      styleMask: [.titled, .closable, .resizable, .nonactivatingPanel], backing: .buffered,
      defer: false)
    window.isReleasedWhenClosed = false
    window.hidesOnDeactivate = false
    window.becomesKeyOnlyIfNeeded = false
    window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
    window.delegate = self
    window.level = .floating
    window.title = url.lastPathComponent
    let preview = QLPreviewView(frame: window.contentView?.bounds ?? .zero, style: .normal)!
    preview.autoresizingMask = [.width, .height]
    preview.previewItem = url as NSURL
    window.contentView = preview
    window.center()
    let previous = previewWindow
    previewWindow = window
    previous?.close()
    window.makeKeyAndOrderFront(nil)
  }

  private func installKeyMonitor() {
    removeKeyMonitor()
    let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      guard let self else { return event }
      return self.handleKeyEvent(event)
    }
    if let monitor { keyMonitor = AnyCancellable { NSEvent.removeMonitor(monitor) } }
  }

  func handleKeyEvent(_ event: NSEvent) -> NSEvent? {
    guard panel.isVisible, let window = event.window else { return event }
    let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
    if window === previewWindow {
      if (event.keyCode == 53 && modifiers.isEmpty)
        || (event.keyCode == 13 && modifiers == .command)
      {
        if !event.isARepeat { previewWindow?.close() }
        return nil
      }
      return event
    }
    guard window === panel else { return event }
    if let input = panel.firstResponder as? NSTextInputClient, input.hasMarkedText() {
      return event
    }
    if modifiers == .command, event.keyCode == 12 || event.keyCode == 43 {
      guard !event.isARepeat else { return nil }
      if event.keyCode == 12 { terminate() } else { model.requestSettings() }
      return nil
    }
    if modifiers.isEmpty, event.keyCode == 53 {
      if !event.isARepeat, !model.cancelOverlay() { hide() }
      return nil
    }
    if modifiers.isEmpty, event.keyCode == 36 || event.keyCode == 76 {
      guard !event.isARepeat else { return nil }
      if model.confirmation != nil {
        model.executeSelection()
      } else if model.savingWorkspace {
        model.saveWorkspace()
      } else if model.actionsVisible {
        model.performSelectedAction()
      } else {
        model.executeSelection()
      }
      return nil
    }
    guard !model.savingWorkspace, model.confirmation == nil else { return event }
    if modifiers == .command || modifiers == [.command, .shift] {
      let action: InternAction?
      switch (event.keyCode, modifiers) {
      case (40, .command):
        if !event.isARepeat, model.topHit != nil { model.actionsVisible.toggle() }
        return nil
      case (35, .command): action = .pin
      case (16, .command): action = .preview
      case (15, .command): action = .reveal
      case (8, [.command, .shift]): action = .copy
      case (49, [.command, .shift]), (49, .command): action = .member
      default: return event
      }
      if !event.isARepeat, let action, model.availableActions.contains(action) {
        model.performAction(action)
      }
      return nil
    }
    if event.keyCode == 48, modifiers.isEmpty || modifiers == .shift,
      !model.actionsVisible
    {
      if !event.isARepeat { model.cycleScope(backward: modifiers == .shift) }
      return nil
    }
    if modifiers.isEmpty, event.keyCode == 125 || event.keyCode == 126 {
      let delta = event.keyCode == 125 ? 1 : -1
      if model.actionsVisible {
        model.moveActionSelection(by: delta)
      } else {
        model.moveSelection(by: delta)
      }
      return nil
    }
    return event
  }

  private func removeKeyMonitor() {
    keyMonitor?.cancel()
    keyMonitor = nil
  }
}
