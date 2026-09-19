import Carbon
import Foundation

/// Registers a single global hotkey (Option+Space) with the Carbon hotkey API, which needs no
/// Accessibility permission. Calls `handler` on the main thread whenever it is pressed.
final class HotKey {
  private var reference: EventHotKeyRef?
  private var handlerReference: EventHandlerRef?
  private let handler: () -> Void

  static let optionSpaceKeyCode: UInt32 = 49  // kVK_Space
  static let signature: OSType = 0x4A45_5631  // "JEV1"

  init(handler: @escaping () -> Void) {
    self.handler = handler
    var eventType = EventTypeSpec(
      eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    let selfPointer = Unmanaged.passUnretained(self).toOpaque()
    InstallEventHandler(
      GetApplicationEventTarget(),
      { _, _, userData -> OSStatus in
        guard let userData else { return noErr }
        let hotKey = Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue()
        hotKey.handler()
        return noErr
      }, 1, &eventType, selfPointer, &handlerReference)
    let hotKeyID = EventHotKeyID(signature: Self.signature, id: 1)
    RegisterEventHotKey(
      Self.optionSpaceKeyCode, UInt32(optionKey), hotKeyID, GetApplicationEventTarget(), 0,
      &reference)
  }

  deinit {
    if let reference { UnregisterEventHotKey(reference) }
    if let handlerReference { RemoveEventHandler(handlerReference) }
  }
}
