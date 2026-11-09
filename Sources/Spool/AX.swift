import AppKit
import ApplicationServices
import SpoolCore

// Private, but the only way to tie an accessibility element to its window server ID.
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

extension AXUIElement {
    private func raw(_ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(self, name as CFString, &value) == .success else { return nil }
        return value
    }

    private func axValue(_ name: String) -> AXValue? {
        guard let value = raw(name), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        return (value as! AXValue)
    }

    private func bool(_ name: String) -> Bool { (raw(name) as? Bool) ?? false }

    private func element(_ name: String) -> AXUIElement? {
        guard let value = raw(name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    var windowID: WindowID? {
        var id: CGWindowID = 0
        return _AXUIElementGetWindow(self, &id) == .success && id != 0 ? id : nil
    }

    /// nil when the app did not answer, which is different from having no windows.
    var windows: [AXUIElement]? { raw(kAXWindowsAttribute) as? [AXUIElement] }
    var focusedWindow: AXUIElement? { element(kAXFocusedWindowAttribute) }
    var title: String? { raw(kAXTitleAttribute) as? String }
    var subrole: String? { raw(kAXSubroleAttribute) as? String }
    var isMinimized: Bool { bool(kAXMinimizedAttribute) }
    var isFullscreen: Bool { bool("AXFullScreen") }

    var position: CGPoint? {
        var point = CGPoint.zero
        guard let value = axValue(kAXPositionAttribute), AXValueGetValue(value, .cgPoint, &point) else { return nil }
        return point
    }

    var size: CGSize? {
        var size = CGSize.zero
        guard let value = axValue(kAXSizeAttribute), AXValueGetValue(value, .cgSize, &size) else { return nil }
        return size
    }
    var frame: CGRect? {
        guard let position, let size else { return nil }
        return CGRect(origin: position, size: size)
    }

    func isSettable(_ name: String) -> Bool {
        var settable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(self, name as CFString, &settable) == .success && settable.boolValue
    }

    func setPosition(_ point: CGPoint) {
        var point = point
        guard let value = AXValueCreate(.cgPoint, &point) else { return }
        AXUIElementSetAttributeValue(self, kAXPositionAttribute as CFString, value)
    }

    func setSize(_ size: CGSize) {
        var size = size
        guard let value = AXValueCreate(.cgSize, &size) else { return }
        AXUIElementSetAttributeValue(self, kAXSizeAttribute as CFString, value)
    }
}

/// Window server IDs of normal-layer windows.
func windowServerIDs(_ options: CGWindowListOption) -> Set<WindowID> {
    guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
    return Set(list.compactMap { info in
        (info[kCGWindowLayer as String] as? Int) == 0 ? info[kCGWindowNumber as String] as? WindowID : nil
    })
}

/// A display, with its frames in accessibility coordinates (origin at the top left of the primary display).
struct ScreenInfo {
    /// Display plus the Space it is showing, so every Space keeps its own strip.
    let key: String
    /// The area windows may use: below the menu bar, clear of the Dock.
    let area: CGRect
    let full: CGRect
}

private typealias MainConnection = @convention(c) () -> Int32
private typealias CurrentSpace = @convention(c) (Int32, CFString) -> UInt64

// Private SkyLight calls, looked up at run time. Without them every Space shares one strip per display.
private let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
private let mainConnection = dlsym(skyLight, "CGSMainConnectionID").map { unsafeBitCast($0, to: MainConnection.self) }
private let currentSpace = dlsym(skyLight, "CGSManagedDisplayGetCurrentSpace").map { unsafeBitCast($0, to: CurrentSpace.self) }

func currentScreens() -> [ScreenInfo] {
    guard let primary = NSScreen.screens.first else { return [] }
    let flip = { (r: CGRect) in CGRect(x: r.minX, y: primary.frame.maxY - r.maxY, width: r.width, height: r.height) }
    return NSScreen.screens.map { screen in
        var display = "\(screen.frame)"
        var space: UInt64 = 0
        if let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
           let uuid = CGDisplayCreateUUIDFromDisplayID(number)?.takeRetainedValue(),
           let string = CFUUIDCreateString(nil, uuid) {
            display = string as String
            if let mainConnection, let currentSpace { space = currentSpace(mainConnection(), string) }
        }
        return ScreenInfo(key: "\(display):\(space)", area: flip(screen.visibleFrame), full: flip(screen.frame))
    }
}

/// The screen holding most of `frame`, falling back to the first.
func screen(for frame: CGRect, in screens: [ScreenInfo]) -> ScreenInfo? {
    screens.max { a, b in
        let ia = a.full.intersection(frame), ib = b.full.intersection(frame)
        return ia.width * ia.height < ib.width * ib.height
    }
}

func screenUnderMouse(in screens: [ScreenInfo]) -> ScreenInfo? {
    guard let primary = NSScreen.screens.first else { return nil }
    let mouse = NSEvent.mouseLocation
    let point = CGPoint(x: mouse.x, y: primary.frame.maxY - mouse.y)
    return screens.first { $0.full.contains(point) } ?? screens.first
}
