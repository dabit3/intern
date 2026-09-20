import Carbon
import Foundation

/// Registers a single global hotkey (Option+Space) with the Carbon hotkey API, which needs no
/// Accessibility permission. Calls `handler` on the main thread whenever it is pressed.
final class HotKey {
  private var reference: EventHotKeyRef?
  private var handlerReference: EventHandlerRef?
  private let handler: () -> Void
  private(set) var registrationStatus: OSStatus = noErr

  var registrationError: String? {
    guard registrationStatus != noErr else { return nil }
    return
      "Option-Space is unavailable (error \(registrationStatus)). Use Toggle Intern in the menu. Check System Settings → Keyboard → Keyboard Shortcuts for a conflict, then restart Intern."
  }

  static let optionSpaceKeyCode: UInt32 = 49  // kVK_Space
  static let signature: OSType = 0x4A45_5631  // "JEV1"

  init(handler: @escaping () -> Void) {
    self.handler = handler
    var eventType = EventTypeSpec(
      eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    let selfPointer = Unmanaged.passUnretained(self).toOpaque()
    registrationStatus = InstallEventHandler(
      GetApplicationEventTarget(),
      { _, event, userData -> OSStatus in
        guard let event, let userData else { return OSStatus(eventNotHandledErr) }
        var identifier = EventHotKeyID()
        let status = GetEventParameter(
          event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
          nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier)
        guard status == noErr, identifier.signature == HotKey.signature, identifier.id == 1 else {
          return OSStatus(eventNotHandledErr)
        }
        let hotKey = Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue()
        hotKey.handler()
        return noErr
      }, 1, &eventType, selfPointer, &handlerReference)
    guard registrationStatus == noErr else { return }
    let hotKeyID = EventHotKeyID(signature: Self.signature, id: 1)
    registrationStatus = RegisterEventHotKey(
      Self.optionSpaceKeyCode, UInt32(optionKey), hotKeyID, GetApplicationEventTarget(), 0,
      &reference)
    if registrationStatus != noErr, let handlerReference {
      RemoveEventHandler(handlerReference)
      self.handlerReference = nil
    }
  }

  deinit {
    if let reference { UnregisterEventHotKey(reference) }
    if let handlerReference { RemoveEventHandler(handlerReference) }
  }
}
