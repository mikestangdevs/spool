import AppKit
import Carbon.HIToolbox
import CoreGraphics

/// Takes the next key press away from whatever app has focus and hands it to Spool.
/// Used for the letter that follows the mark shortcuts.
final class KeyCapture {
    static let shared = KeyCapture()
    static let timeout = 3.0

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var completion: ((String?) -> Void)?
    private var expiry: DispatchWorkItem?

    /// Calls back with the key's character, lowercased, or nil on Escape or timeout.
    func next(_ completion: @escaping (String?) -> Void) {
        finish(nil)
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                eventsOfInterest: mask, callback: { _, type, event, _ in
            guard type == .keyDown else { return Unmanaged.passUnretained(event) }
            let escape = event.getIntegerValueField(.keyboardEventKeycode) == Int64(kVK_Escape)
            let key = escape ? nil : NSEvent(cgEvent: event)?.charactersIgnoringModifiers?.lowercased()
            DispatchQueue.main.async { KeyCapture.shared.finish(key) }
            return nil   // the key was for Spool; the app must not see it
        }, userInfo: nil)
        guard let tap else {
            completion(nil)
            return
        }
        self.completion = completion
        source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        let expiry = DispatchWorkItem { [weak self] in self?.finish(nil) }
        self.expiry = expiry
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.timeout, execute: expiry)
    }

    private func finish(_ key: String?) {
        expiry?.cancel()
        expiry = nil
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
        let done = completion
        completion = nil
        done?(key)
    }
}
