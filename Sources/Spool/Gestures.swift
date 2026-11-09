import AppKit
import CoreGraphics

// MARK: Trackpad swipe

/// One frame of trackpad contact: how many fingers are down and their mean position (0…1).
private func touchFrame(_ device: UnsafeMutableRawPointer?, _ touches: UnsafeMutableRawPointer?,
                        _ count: Int32, _ timestamp: Double, _ frame: Int32) -> Int32 {
    // Layout of the private MTTouch record: 96 bytes, state at 20, normalised x and y at 32 and 36.
    let stride = 96
    var fingers = 0
    var x = 0.0, y = 0.0
    if let touches {
        for i in 0..<Int(count) {
            let touch = touches + i * stride
            let state = touch.load(fromByteOffset: 20, as: Int32.self)
            guard state == 3 || state == 4 || state == 5 else { continue }   // touching, not hovering or lifting
            fingers += 1
            x += Double(touch.load(fromByteOffset: 32, as: Float.self))
            y += Double(touch.load(fromByteOffset: 36, as: Float.self))
        }
    }
    let n = fingers, mx = fingers > 0 ? x / Double(fingers) : 0, my = fingers > 0 ? y / Double(fingers) : 0
    DispatchQueue.main.async { SwipeRecognizer.shared.frame(fingers: n, x: mx, y: my) }
    return 0
}

/// Reads raw trackpad touches through the private MultitouchSupport framework, which is the
/// only way to see a three-finger swipe system-wide.
final class SwipeRecognizer {
    static let shared = SwipeRecognizer()

    private typealias Callback = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, Int32, Double, Int32) -> Int32
    private typealias CreateList = @convention(c) () -> Unmanaged<CFArray>?
    private typealias Register = @convention(c) (UnsafeRawPointer, Callback) -> Void
    private typealias StartStop = @convention(c) (UnsafeRawPointer, Int32) -> Int32

    private enum Phase {
        case idle
        case pending(x: Double, y: Double)
        case sliding(startX: Double, width: Double)
        case rejected
    }

    private var devices: CFArray?
    private var phase = Phase.idle
    /// Strip points travelled per full trackpad width, as a multiple of the screen width.
    private let gain = 1.6

    private(set) var available = false

    func start() {
        guard devices == nil,
              let lib = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_LAZY),
              let create = dlsym(lib, "MTDeviceCreateList"),
              let register = dlsym(lib, "MTRegisterContactFrameCallback"),
              let start = dlsym(lib, "MTDeviceStart"),
              let list = unsafeBitCast(create, to: CreateList.self)()?.takeRetainedValue() else { return }
        devices = list
        for i in 0..<CFArrayGetCount(list) {
            guard let device = CFArrayGetValueAtIndex(list, i) else { continue }
            unsafeBitCast(register, to: Register.self)(device, touchFrame)
            _ = unsafeBitCast(start, to: StartStop.self)(device, 0)
            available = true
        }
    }

    fileprivate func frame(fingers: Int, x: Double, y: Double) {
        let wanted = SettingsStore.shared.value.swipeFingers
        guard wanted > 0 else {
            if case .sliding = phase { WindowManager.shared.endScroll() }
            phase = .idle
            return
        }
        switch phase {
        case .idle:
            if fingers == wanted { phase = .pending(x: x, y: y) } else if fingers > wanted { phase = .rejected }
        case .pending(let startX, let startY):
            guard fingers == wanted else {
                phase = fingers == 0 ? .idle : (fingers > wanted ? .rejected : .idle)
                return
            }
            let dx = x - startX, dy = y - startY
            if abs(dy) > 0.04 && abs(dy) > abs(dx) {
                phase = .rejected   // a vertical swipe belongs to Mission Control
            } else if abs(dx) > 0.015 && abs(dx) > abs(dy) * 1.2 {
                let width = Double(NSScreen.main?.frame.width ?? 1440)
                phase = WindowManager.shared.beginScroll() ? .sliding(startX: x, width: width) : .rejected
            }
        case .sliding(let startX, let width):
            if fingers == wanted {
                WindowManager.shared.scroll(to: -(x - startX) * width * gain)
            } else {
                WindowManager.shared.endScroll()
                phase = fingers == 0 ? .idle : .rejected
            }
        case .rejected:
            if fingers == 0 { phase = .idle }
        }
    }
}

// MARK: Option + scroll

/// Holding ⌥ while scrolling (two fingers or a wheel) slides the strip instead of the app.
final class OptionScroll {
    static let shared = OptionScroll()

    private var tap: CFMachPort?
    private var settle: DispatchWorkItem?
    private var scrolling = false

    func start() {
        guard tap == nil else { return }
        let mask = CGEventMask(1 << CGEventType.scrollWheel.rawValue)
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                eventsOfInterest: mask, callback: { _, type, event, _ in
            OptionScroll.shared.handle(type, event) ? nil : Unmanaged.passUnretained(event)
        }, userInfo: nil)
        guard let tap else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
    }

    /// Returns true when the event was used and should not reach the app.
    private func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        }
        let flags = event.flags.intersection([.maskAlternate, .maskCommand, .maskControl, .maskShift])
        guard type == .scrollWheel, flags == .maskAlternate, SettingsStore.shared.value.optionScroll,
              WindowManager.shared.running else { return false }
        let horizontal = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2)
        let vertical = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)
        let delta = abs(horizontal) >= abs(vertical) ? horizontal : vertical   // a plain wheel only has vertical
        if !scrolling {
            guard WindowManager.shared.beginScroll() else { return false }
            scrolling = true
        }
        WindowManager.shared.scroll(by: -delta)
        settle?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.scrolling = false
            WindowManager.shared.endScroll()
        }
        settle = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
        return true
    }
}
