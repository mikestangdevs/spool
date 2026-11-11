import AppKit

func overlayWindow() -> NSWindow {
    let window = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
    window.isOpaque = false
    window.backgroundColor = .clear
    window.hasShadow = false
    window.ignoresMouseEvents = true
    window.level = .floating
    window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
    window.isReleasedWhenClosed = false
    return window
}

/// Converts a rect from accessibility coordinates (top-left origin) to AppKit's (bottom-left).
func appKitRect(_ rect: CGRect) -> CGRect {
    let height = NSScreen.screens.first?.frame.maxY ?? 0
    return CGRect(x: rect.minX, y: height - rect.maxY, width: rect.width, height: rect.height)
}

/// A coloured edge around the focused window.
///
/// It is not drawn on top. A shape slightly larger than the window is slid directly beneath
/// it in the window stack, so the window's own outline is the inner edge of the border and
/// the two meet exactly, whatever the window's corners look like.
final class FocusBorder {
    static let shared = FocusBorder()

    private let window = overlayWindow()
    private let shape = CAShapeLayer()

    private init() {
        window.level = .normal
        // Transient keeps it out of Mission Control.
        window.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        let view = NSView()
        view.wantsLayer = true
        shape.fillRule = .evenOdd
        view.layer?.addSublayer(shape)
        window.contentView = view
    }

    /// `frame` is the window's frame in accessibility coordinates, `id` its window number and
    /// `radius` its corner radius, which only shapes the outer edge.
    func show(around frame: CGRect, below id: UInt32, width: CGFloat, radius: CGFloat) {
        let outer = appKitRect(frame).insetBy(dx: -width, dy: -width)
        window.setFrame(outer, display: false)
        let bounds = CGRect(origin: .zero, size: outer.size)
        let ring = CGMutablePath()
        ring.addRoundedRect(in: bounds, cornerWidth: radius + width, cornerHeight: radius + width)
        // Hollow, so a see-through window is not tinted. The hole stays hidden under the
        // window: it starts a little inside the edge and is rounder than any real corner.
        let hole = bounds.insetBy(dx: width + 2, dy: width + 2)
        let holeRadius = min(radius + 12, hole.width / 2, hole.height / 2)
        if hole.width > 0, hole.height > 0 {
            ring.addRoundedRect(in: hole, cornerWidth: holeRadius, cornerHeight: holeRadius)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)   // no implicit animation; it must stay glued to the window
        shape.frame = bounds
        shape.fillColor = NSColor.controlAccentColor.cgColor
        shape.path = ring
        CATransaction.commit()
        if !window.isVisible {
            window.alphaValue = 0
            window.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                window.animator().alphaValue = 1
            }
        }
        window.order(.below, relativeTo: Int(id))
    }

    func hide() {
        if window.isVisible { window.orderOut(nil) }
    }
}

/// A brief label over a window or screen: the new width, a mark, a prompt.
final class HUD {
    static let shared = HUD()

    private let window = overlayWindow()
    private let backdrop = NSVisualEffectView()
    private let label = NSTextField(labelWithString: "")
    private var fade: DispatchWorkItem?

    private init() {
        backdrop.material = .hudWindow
        backdrop.state = .active
        backdrop.wantsLayer = true
        backdrop.layer?.cornerRadius = 20
        backdrop.layer?.masksToBounds = true
        label.textColor = .labelColor
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        backdrop.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: backdrop.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: backdrop.centerYAnchor),
        ])
        window.contentView = backdrop
        window.level = .statusBar
    }

    /// `frame` is the area to centre on, in accessibility coordinates. `big` is for a single
    /// short value such as "1/3"; sentences use the smaller size.
    func show(_ text: String, over frame: CGRect, big: Bool = false, hold: Double = 0.7) {
        let target = appKitRect(frame)
        label.font = .systemFont(ofSize: big ? 40 : 17, weight: .semibold)
        label.stringValue = text
        let fit = label.intrinsicContentSize
        let size = CGSize(width: max(fit.width + 48, big ? 132 : 0), height: big ? 96 : fit.height + 32)
        window.setFrame(CGRect(x: target.midX - size.width / 2, y: target.midY - size.height / 2,
                               width: size.width, height: size.height), display: true)
        window.alphaValue = 1
        window.orderFrontRegardless()
        fade?.cancel()
        let work = DispatchWorkItem { [weak self] in
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.25
                self?.window.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                if self?.window.alphaValue == 0 { self?.window.orderOut(nil) }
            })
        }
        fade = work
        DispatchQueue.main.asyncAfter(deadline: .now() + hold, execute: work)
    }

    func hide() {
        fade?.cancel()
        window.orderOut(nil)
    }
}

/// A small map of the strip at the foot of the screen: one tick per column and a frame
/// around the part in view. It appears while the strip moves and fades afterwards.
final class Minimap {
    static let shared = Minimap()

    private final class MapView: NSView {
        var origins: [Double] = []
        var widths: [Double] = []
        var total = 1.0
        var offset = 0.0
        var usable = 1.0
        var focused = 0

        override func draw(_ dirtyRect: NSRect) {
            NSColor.black.withAlphaComponent(0.55).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
            let inner = bounds.insetBy(dx: 7, dy: 4.5)
            // The view can be scrolled a little past either end, so the map covers that too.
            let low = min(0, offset), high = max(total, offset + usable)
            let scale = inner.width / (high - low)
            let x = { (value: Double) in inner.minX + (value - low) * scale }
            for i in origins.indices {
                let tick = NSRect(x: x(origins[i]), y: inner.minY, width: max(1.5, widths[i] * scale - 1), height: inner.height)
                (i == focused ? NSColor.controlAccentColor : NSColor.white.withAlphaComponent(0.45)).setFill()
                NSBezierPath(roundedRect: tick, xRadius: 1.5, yRadius: 1.5).fill()
            }
            let view = NSRect(x: x(offset), y: inner.minY - 2, width: usable * scale, height: inner.height + 4)
            NSColor.white.setStroke()
            let outline = NSBezierPath(roundedRect: view, xRadius: 3, yRadius: 3)
            outline.lineWidth = 1
            outline.stroke()
        }
    }

    private let window = overlayWindow()
    private let view = MapView()
    private var fade: DispatchWorkItem?

    private init() {
        window.contentView = view
        window.level = .statusBar
    }

    /// `area` is the usable part of the screen, in accessibility coordinates.
    func show(origins: [Double], widths: [Double], total: Double, offset: Double, usable: Double, focused: Int, over area: CGRect) {
        view.origins = origins
        view.widths = widths
        view.total = max(total, 1)
        view.offset = offset
        view.usable = usable
        view.focused = focused
        let screen = appKitRect(area)
        let size = CGSize(width: min(200, screen.width * 0.16), height: 16)
        window.setFrame(CGRect(x: screen.midX - size.width / 2, y: screen.minY + 16, width: size.width, height: size.height), display: false)
        view.needsDisplay = true
        window.alphaValue = 1
        if !window.isVisible { window.orderFrontRegardless() }
        fade?.cancel()
        let work = DispatchWorkItem { [weak self] in
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.3
                self?.window.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                if self?.window.alphaValue == 0 { self?.window.orderOut(nil) }
            })
        }
        fade = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9, execute: work)
    }
}
