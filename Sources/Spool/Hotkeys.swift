import Carbon.HIToolbox
import Foundation

/// Global hotkeys through Carbon, which needs no permission and swallows the chord.
final class HotkeyCenter {
    static let shared = HotkeyCenter()

    /// Called with true when a chord goes down and false when it is let go.
    var handler: ((Action, Bool) -> Void)?
    /// Actions whose chord the system refused, usually because something else owns it.
    private(set) var failed: Set<Action> = []

    private var refs: [EventHotKeyRef] = []
    private var actions: [UInt32: Action] = [:]
    private var installed = false

    func register(_ bindings: [Action: KeyCombo]) {
        unregisterAll()
        installHandler()
        var next: UInt32 = 1
        for (action, combo) in bindings.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: 0x5350_4F4C, id: next)   // 'SPOL'
            if RegisterEventHotKey(combo.keyCode, combo.mods, id, GetApplicationEventTarget(), 0, &ref) == noErr, let ref {
                refs.append(ref)
                actions[next] = action
            } else {
                failed.insert(action)
            }
            next += 1
        }
    }

    func unregisterAll() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs = []
        actions = [:]
        failed = []
    }

    fileprivate func fire(_ id: UInt32, pressed: Bool) {
        if let action = actions[id] { handler?(action, pressed) }
    }

    private func installHandler() {
        guard !installed else { return }
        installed = true
        var specs = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            HotkeyCenter.shared.fire(id.id, pressed: GetEventKind(event) == UInt32(kEventHotKeyPressed))
            return noErr
        }, 2, &specs, nil, nil)
    }
}
