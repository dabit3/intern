import AppKit
import XCTest

@testable import Intern

@MainActor
final class InteractionQualityTests: XCTestCase {
  private func makeModel(
    execute: @escaping @MainActor (Candidate) async -> Executor.Outcome = { _ in
      .init(succeeded: false, message: "Test execution failed")
    }
  ) throws -> InternModel {
    let suite = "InteractionQualityTests.\(UUID())"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defaults.set(true, forKey: "localOnly")
    defaults.set(false, forKey: "includeSpotlight")
    addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
    return InternModel(
      defaults: defaults,
      execute: execute,
      buildIndex: { _ in LocalIndex(candidates: [Fixtures.roadmap, Fixtures.invoice]) })
  }

  private func settle() async {
    try? await Task.sleep(for: .milliseconds(400))
  }

  private func launcherWindow() throws -> NSWindow {
    try XCTUnwrap(NSApp.windows.first { $0 is KeyablePanel && $0.isVisible })
  }

  private func key(
    _ code: UInt16, in window: NSWindow, modifiers: NSEvent.ModifierFlags = [],
    repeated: Bool = false
  ) throws -> NSEvent {
    try XCTUnwrap(
      NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
        windowNumber: window.windowNumber, context: nil, characters: "",
        charactersIgnoringModifiers: "", isARepeat: repeated, keyCode: code))
  }

  func testWorkspaceEditorOwnsFocusWithoutChangingSearchOrMembers() async throws {
    let model = try makeModel()
    let controller = InternPanelIntern(model: model)
    controller.show()
    defer { controller.hide() }
    await settle()
    model.query = "pdf"
    model.toggleMember(Fixtures.roadmap)
    model.toggleMember(Fixtures.invoice)
    model.select(0)
    model.actionsVisible = true
    model.performAction(.saveWorkspace)
    await settle()

    let panel = try launcherWindow()
    let editor = try XCTUnwrap(panel.firstResponder as? NSTextView)
    XCTAssertEqual(editor.string, "")
    editor.insertText("Research", replacementRange: NSRange(location: NSNotFound, length: 0))
    await settle()
    XCTAssertEqual(model.workspaceName, "Research")
    XCTAssertEqual(model.query, "pdf")
    XCTAssertEqual(model.selectedMembers.count, 2)
    XCTAssertTrue(model.savingWorkspace)
  }

  func testQuickLookKeepsSearchAndSelectionWhenPanelResignsKey() async throws {
    let model = try makeModel()
    let controller = InternPanelIntern(model: model)
    controller.show()
    defer { controller.hide() }
    await settle()
    model.query = "roadmap"
    let selectedID = model.topHit?.id
    model.previewSelection()
    await settle()

    XCTAssertTrue(controller.isVisible)
    XCTAssertEqual(model.query, "roadmap")
    XCTAssertEqual(model.topHit?.id, selectedID)
    let preview = try XCTUnwrap(NSApp.windows.first { $0.title == Fixtures.roadmap.title })
    XCTAssertNil(controller.handleKeyEvent(try key(53, in: preview)))
    await settle()
    XCTAssertTrue(controller.isVisible)
    XCTAssertEqual(model.query, "roadmap")
  }

  func testQuickLookAcceptsKeyboardWithoutActivatingTheLauncherApplication() async throws {
    let model = try makeModel()
    let controller = InternPanelIntern(model: model)
    controller.show()
    defer { controller.hide() }
    await settle()
    model.query = "roadmap"
    model.previewSelection()
    await settle()

    let preview = try XCTUnwrap(
      NSApp.windows.first { $0.title == Fixtures.roadmap.title } as? PreviewPanel)
    XCTAssertTrue(preview.styleMask.contains(.nonactivatingPanel))
    XCTAssertTrue(preview.canBecomeKey)
    XCTAssertFalse(preview.becomesKeyOnlyIfNeeded)
    XCTAssertFalse(preview.hidesOnDeactivate)
    XCTAssertNil(controller.handleKeyEvent(try key(53, in: preview)))
    XCTAssertFalse(preview.isVisible)
    XCTAssertEqual(model.query, "roadmap")
  }

  func testFailedExecutionRestoresKeyboardFocusWithoutResettingSearch() async throws {
    var finish: CheckedContinuation<Executor.Outcome, Never>?
    let model = try makeModel { _ in
      await withCheckedContinuation { finish = $0 }
    }
    let controller = InternPanelIntern(model: model)
    controller.show()
    defer { controller.hide() }
    await settle()
    let link = Candidate(
      id: "url:focus", title: "Focus example", subtitle: "example.com", kind: .openURL,
      payload: .url(URL(string: "https://example.com")!))
    model.replaceIndex([link])
    model.query = "focus"
    let launcher = try launcherWindow()
    model.executeSelection()
    await settle()
    let other = PreviewPanel(
      contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
      styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
    other.isReleasedWhenClosed = false
    defer { other.close() }
    other.makeKeyAndOrderFront(nil)
    await settle()
    XCTAssertTrue(other.isKeyWindow)
    XCTAssertFalse(launcher.isKeyWindow)
    let completion = try XCTUnwrap(finish)
    completion.resume(returning: .init(succeeded: false, message: "Open was rejected"))
    await settle()

    XCTAssertTrue(launcher.isKeyWindow)
    XCTAssertTrue(controller.isVisible)
    XCTAssertEqual(model.query, "focus")
    XCTAssertEqual(model.topHit?.id, link.id)
    XCTAssertEqual(model.lastError, "Open was rejected")
  }

  func testModifiersAndMarkedTextAreLeftToTheFieldEditor() async throws {
    let model = try makeModel()
    let controller = InternPanelIntern(model: model)
    controller.show()
    defer { controller.hide() }
    await settle()
    model.query = "pdf"
    await settle()
    let panel = try launcherWindow()
    let selection = model.selection
    for modifiers: NSEvent.ModifierFlags in [.control, .option, .shift, [.control, .option]] {
      for code: UInt16 in [125, 126, 36, 48] {
        let event = try key(code, in: panel, modifiers: modifiers)
        if code == 48 && modifiers == .shift { continue }
        XCTAssertTrue(controller.handleKeyEvent(event) === event)
      }
    }
    XCTAssertEqual(model.selection, selection)
    XCTAssertEqual(model.scope, .all)

    let editor = try XCTUnwrap(panel.firstResponder as? NSTextView)
    editor.setMarkedText(
      "に", selectedRange: NSRange(location: 1, length: 0),
      replacementRange: NSRange(location: NSNotFound, length: 0))
    XCTAssertTrue(editor.hasMarkedText())
    for code: UInt16 in [36, 76, 53, 125, 126, 48] {
      let event = try key(code, in: panel)
      XCTAssertTrue(controller.handleKeyEvent(event) === event)
    }
    XCTAssertTrue(controller.isVisible)
    XCTAssertFalse(model.isExecuting)
    editor.unmarkText()
  }

  func testGroupShortcutsToggleSelectedMemberOncePerPress() async throws {
    let model = try makeModel()
    let controller = InternPanelIntern(model: model)
    controller.show()
    defer { controller.hide() }
    await settle()
    model.query = "roadmap"
    model.select(0)
    let panel = try launcherWindow()

    for modifiers: NSEvent.ModifierFlags in [[.command, .shift], .command] {
      XCTAssertNil(controller.handleKeyEvent(try key(49, in: panel, modifiers: modifiers)))
      XCTAssertEqual(model.selectedMembers.map(\.id), [Fixtures.roadmap.id])
      XCTAssertEqual(model.topHit?.id, Fixtures.roadmap.id)
      XCTAssertNil(
        controller.handleKeyEvent(try key(49, in: panel, modifiers: modifiers, repeated: true)))
      XCTAssertEqual(model.selectedMembers.map(\.id), [Fixtures.roadmap.id])
      XCTAssertNil(controller.handleKeyEvent(try key(49, in: panel, modifiers: modifiers)))
      XCTAssertTrue(model.selectedMembers.isEmpty)
    }
    XCTAssertEqual(model.query, "roadmap")
  }

  func testConfirmationPrecedesActionsAndReturnRepeatCannotExecute() async throws {
    var executions = 0
    let model = try makeModel { _ in
      executions += 1
      return .init(succeeded: false, message: "Test only")
    }
    let controller = InternPanelIntern(model: model)
    controller.show()
    defer { controller.hide() }
    await settle()
    model.replaceIndex([SystemToggle.emptyTrash.candidate])
    model.query = "empty trash"
    model.actionsVisible = true
    let panel = try launcherWindow()
    XCTAssertNil(controller.handleKeyEvent(try key(36, in: panel)))
    XCTAssertNotNil(model.confirmation)
    XCTAssertTrue(model.actionsVisible)
    for code: UInt16 in [36, 76] {
      XCTAssertNil(controller.handleKeyEvent(try key(code, in: panel, repeated: true)))
    }
    let tab = try key(48, in: panel)
    XCTAssertTrue(controller.handleKeyEvent(tab) === tab)
    XCTAssertNotNil(model.confirmation)
    XCTAssertEqual(model.scope, .all)
    await settle()
    XCTAssertEqual(executions, 0)

    XCTAssertNil(controller.handleKeyEvent(try key(76, in: panel)))
    await settle()
    XCTAssertEqual(executions, 1)
    XCTAssertNil(model.confirmation)
    XCTAssertEqual(model.lastError, "Test only")
  }

  func testEscapeUnwindsOneOverlayWithoutRepeating() async throws {
    let model = try makeModel()
    let controller = InternPanelIntern(model: model)
    controller.show()
    defer { controller.hide() }
    await settle()
    model.query = "pdf"
    model.toggleMember(Fixtures.roadmap)
    model.toggleMember(Fixtures.invoice)
    model.select(0)
    model.actionsVisible = true
    model.performAction(.saveWorkspace)
    let panel = try launcherWindow()
    XCTAssertNil(controller.handleKeyEvent(try key(53, in: panel)))
    XCTAssertFalse(model.savingWorkspace)
    XCTAssertTrue(model.actionsVisible)
    XCTAssertNil(controller.handleKeyEvent(try key(53, in: panel, repeated: true)))
    XCTAssertTrue(model.actionsVisible)
    XCTAssertNil(controller.handleKeyEvent(try key(53, in: panel)))
    XCTAssertFalse(model.actionsVisible)
    XCTAssertTrue(controller.isVisible)
    XCTAssertEqual(model.query, "pdf")
    XCTAssertEqual(model.selectedMembers.count, 2)
  }

  func testWorkspaceReturnSavesOnceWithoutOpeningTheGroup() async throws {
    var executions = 0
    let model = try makeModel { _ in
      executions += 1
      return .init(succeeded: false, message: "Test only")
    }
    let controller = InternPanelIntern(model: model)
    controller.show()
    defer { controller.hide() }
    await settle()
    model.query = "pdf"
    model.toggleMember(Fixtures.roadmap)
    model.toggleMember(Fixtures.invoice)
    model.select(0)
    model.actionsVisible = true
    model.performAction(.saveWorkspace)
    model.workspaceName = "Research"
    let panel = try launcherWindow()
    XCTAssertNil(controller.handleKeyEvent(try key(36, in: panel)))
    XCTAssertNil(controller.handleKeyEvent(try key(36, in: panel, repeated: true)))
    await settle()
    XCTAssertEqual(model.library.snapshot.workspaces.map(\.name), ["Research"])
    XCTAssertFalse(model.savingWorkspace)
    XCTAssertFalse(model.actionsVisible)
    XCTAssertEqual(executions, 0)
    XCTAssertEqual(model.query, "pdf")
    XCTAssertEqual((panel.firstResponder as? NSTextView)?.string, "pdf")
  }

  func testShortcutsRequireExactModifiersAndIgnoreAutoRepeat() async throws {
    let model = try makeModel()
    let controller = InternPanelIntern(model: model)
    controller.show()
    defer { controller.hide() }
    await settle()
    model.query = "roadmap"
    let panel = try launcherWindow()
    for modifiers: NSEvent.ModifierFlags in [[.command, .shift], [.command, .option]] {
      let event = try key(35, in: panel, modifiers: modifiers)
      XCTAssertTrue(controller.handleKeyEvent(event) === event)
      XCTAssertFalse(model.library.isPinned(Fixtures.roadmap))
    }
    XCTAssertNil(controller.handleKeyEvent(try key(35, in: panel, modifiers: .command)))
    XCTAssertTrue(model.library.isPinned(Fixtures.roadmap))
    XCTAssertNil(
      controller.handleKeyEvent(try key(35, in: panel, modifiers: .command, repeated: true)))
    XCTAssertTrue(model.library.isPinned(Fixtures.roadmap))
    XCTAssertNil(controller.handleKeyEvent(try key(48, in: panel, modifiers: .shift)))
    XCTAssertEqual(model.scope, .workspaces)
  }

  func testQuitAndSettingsShortcutsWorkWithoutTheMenuBarItem() async throws {
    let model = try makeModel()
    let controller = InternPanelIntern(model: model)
    var quits = 0
    controller.terminate = { quits += 1 }
    controller.show()
    defer { controller.hide() }
    await settle()
    model.query = "pdf"
    let panel = try launcherWindow()

    XCTAssertNil(controller.handleKeyEvent(try key(43, in: panel, modifiers: .command)))
    XCTAssertEqual(model.settingsRequests, 1)
    XCTAssertNil(
      controller.handleKeyEvent(try key(43, in: panel, modifiers: .command, repeated: true)))
    XCTAssertEqual(model.settingsRequests, 1)
    let shifted = try key(43, in: panel, modifiers: [.command, .shift])
    XCTAssertTrue(controller.handleKeyEvent(shifted) === shifted)
    XCTAssertEqual(model.settingsRequests, 1)
    XCTAssertEqual(model.query, "pdf")

    model.toggleMember(Fixtures.roadmap)
    model.toggleMember(Fixtures.invoice)
    model.actionsVisible = true
    model.performAction(.saveWorkspace)
    XCTAssertTrue(model.savingWorkspace)
    XCTAssertNil(controller.handleKeyEvent(try key(43, in: panel, modifiers: .command)))
    XCTAssertEqual(model.settingsRequests, 2)

    let optioned = try key(12, in: panel, modifiers: [.command, .option])
    XCTAssertTrue(controller.handleKeyEvent(optioned) === optioned)
    XCTAssertEqual(quits, 0)
    XCTAssertNil(controller.handleKeyEvent(try key(12, in: panel, modifiers: .command)))
    XCTAssertNil(
      controller.handleKeyEvent(try key(12, in: panel, modifiers: .command, repeated: true)))
    XCTAssertEqual(quits, 1)
  }

  func testEventsFromOtherWindowsAndHiddenPanelsPassThrough() async throws {
    let model = try makeModel()
    let controller = InternPanelIntern(model: model)
    controller.show()
    defer { controller.hide() }
    await settle()
    let panel = try launcherWindow()
    let other = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: .titled,
      backing: .buffered, defer: false)
    other.isReleasedWhenClosed = false
    defer { other.close() }
    for code: UInt16 in [36, 53, 48, 125] {
      let event = try key(code, in: other)
      XCTAssertTrue(controller.handleKeyEvent(event) === event)
    }
    XCTAssertTrue(controller.isVisible)
    controller.hide()
    let event = try key(36, in: panel)
    XCTAssertTrue(controller.handleKeyEvent(event) === event)
  }

  func testModalHeightWinsOverTheUnderlyingActionsAndEmptyResults() throws {
    let model = try makeModel()
    model.actionsVisible = true
    model.savingWorkspace = true
    XCTAssertEqual(
      InternPanelIntern.height(for: model), InternPanelIntern.height(rows: 3, empty: false))
    model.actionsVisible = false
    XCTAssertEqual(
      InternPanelIntern.height(for: model), InternPanelIntern.height(rows: 3, empty: false))
    model.saveWorkspace()
    XCTAssertEqual(
      InternPanelIntern.height(for: model),
      InternPanelIntern.height(rows: 3, empty: false) + InternPanelIntern.feedbackHeight)
  }

  func testPanelFittingKeepsTallListsInsideEachScreensVisibleFrame() {
    for screen in [
      NSRect(x: 0, y: 0, width: 800, height: 600),
      NSRect(x: -1280, y: 120, width: 1280, height: 720),
      NSRect(x: 400, y: -900, width: 600, height: 400),
    ] {
      let frame = NSRect(
        x: screen.midX - 340, y: screen.midY + screen.height * 0.22 - 556,
        width: 680, height: 556)
      XCTAssertTrue(screen.contains(InternPanelIntern.fitting(frame, in: screen)))
    }
  }

  func testSettingsCanBeRaisedAgainAfterBeingHidden() {
    let delegate = AppDelegate()
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 480, height: 300),
      styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    delegate.attachSettingsWindow(window)
    XCTAssertTrue(window.isVisible)
    window.orderOut(nil)
    XCTAssertFalse(window.isVisible)
    delegate.raiseSettings()
    XCTAssertTrue(window.isVisible)
  }
}
