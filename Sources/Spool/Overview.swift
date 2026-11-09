import AppKit
import Carbon.HIToolbox
import ScreenCaptureKit
import SpoolCore

/// A zoomed-out picture of the whole strip. Pick a window with the mouse or the keyboard.
final class Overview {
    static let shared = Overview()

    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { true }
    }

    private var panel: Panel?
    /// The window that had focus when the overview opened, to return to on cancel.
    private var origin: WindowID?

    func toggle() {
        panel == nil ? open() : close(selecting: origin)
    }

    private func open() {
        guard let model = WindowManager.shared.overviewCards(), !model.cards.isEmpty else { return }
        origin = model.cards.first(where: \.focused)?.id

        let panel = Panel(contentRect: appKitRect(model.screen.full), styleMask: [.borderless, .nonactivatingPanel],
                          backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .modalPanel
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false

        let backdrop = NSVisualEffectView(frame: CGRect(origin: .zero, size: panel.frame.size))
        backdrop.material = .fullScreenUI
        backdrop.blendingMode = .behindWindow
        backdrop.state = .active
        let view = OverviewView(frame: backdrop.bounds, cards: model.cards, stripSize: model.size)
        view.autoresizingMask = [.width, .height]
        view.onPick = { [weak self] id in self?.close(selecting: id) }
        view.onCancel = { [weak self] in self?.close(selecting: self?.origin) }
        backdrop.addSubview(view)
        panel.contentView = backdrop

        self.panel = panel
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(view)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 1
        }

        if SettingsStore.shared.value.overviewThumbnails && CGPreflightScreenCaptureAccess() {
            capture(model.cards.map(\.id)) { [weak view] id, image in view?.setImage(image, for: id) }
        }
    }

    private func close(selecting id: WindowID?) {
        panel?.orderOut(nil)
        panel = nil
        if let id { WindowManager.shared.select(id) }
    }

    /// Photographs each window, wherever it is on the strip, and delivers the pictures as they arrive.
    private func capture(_ ids: [WindowID], deliver: @escaping (WindowID, CGImage) -> Void) {
        Task {
            guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false) else { return }
            for id in ids {
                guard let window = content.windows.first(where: { $0.windowID == id }), window.frame.width > 0 else { continue }
                let config = SCStreamConfiguration()
                // Cards are drawn far smaller than the window, so a reduced capture is plenty.
                let scale = min(1, 900 / window.frame.width)
                config.width = Int(window.frame.width * scale)
                config.height = Int(window.frame.height * scale)
                config.showsCursor = false
                let filter = SCContentFilter(desktopIndependentWindow: window)
                if let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) {
                    await MainActor.run { deliver(id, image) }
                }
            }
        }
    }
}

private final class OverviewView: NSView {
    var onPick: ((WindowID) -> Void)?
    var onCancel: (() -> Void)?

    private let cards: [WindowManager.OverviewCard]
    private let stripSize: CGSize
    private var images: [WindowID: CGImage] = [:]
    private var icons: [pid_t: NSImage] = [:]
    private var selected: Int
    private var tracking: NSTrackingArea?

    init(frame: CGRect, cards: [WindowManager.OverviewCard], stripSize: CGSize) {
        self.cards = cards
        self.stripSize = stripSize
        selected = cards.firstIndex(where: \.focused) ?? 0
        super.init(frame: frame)
        for card in cards where icons[card.pid] == nil {
            icons[card.pid] = NSRunningApplication(processIdentifier: card.pid)?.icon
        }
    }

    required init?(coder: NSCoder) { fatalError("OverviewView is created in code") }

    // Top-left origin, to match the strip's own coordinates.
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    func setImage(_ image: CGImage, for id: WindowID) {
        images[id] = image
        needsDisplay = true
    }

    // MARK: Layout

    /// Shrinks the strip to fit the screen, never larger than half size.
    private var scale: CGFloat {
        min((bounds.width - 120) / stripSize.width, (bounds.height * 0.6) / stripSize.height, 0.5)
    }

    private func rect(_ card: WindowManager.OverviewCard) -> CGRect {
        let s = scale
        let left = (bounds.width - stripSize.width * s) / 2
        let top = (bounds.height - stripSize.height * s) / 2
        return CGRect(x: left + card.frame.minX * s, y: top + card.frame.minY * s,
                      width: card.frame.width * s, height: card.frame.height * s).insetBy(dx: 3, dy: 3)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.35).setFill()
        bounds.fill()

        var numbered: Set<Int> = []
        for (index, card) in cards.enumerated() {
            let frame = rect(card)
            let shape = NSBezierPath(roundedRect: frame, xRadius: 8, yRadius: 8)

            NSGraphicsContext.saveGraphicsState()
            shape.addClip()
            if let image = images[card.id] {
                NSImage(cgImage: image, size: frame.size).draw(in: frame, from: .zero, operation: .sourceOver,
                                                             fraction: 1, respectFlipped: true, hints: nil)
            } else {
                NSColor(white: 0.16, alpha: 0.95).setFill()
                frame.fill()
                let side = min(72, frame.height * 0.4, frame.width * 0.5)
                icons[card.pid]?.draw(in: CGRect(x: frame.midX - side / 2, y: frame.midY - side / 2 - 8, width: side, height: side),
                                     from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
            drawCaption(card, in: frame)
            NSGraphicsContext.restoreGraphicsState()

            (index == selected ? NSColor.controlAccentColor : NSColor.white.withAlphaComponent(0.18)).setStroke()
            shape.lineWidth = index == selected ? 3 : 1
            shape.stroke()

            if card.column < 9, numbered.insert(card.column).inserted {
                let number = NSAttributedString(string: "\(card.column + 1)", attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
                    .foregroundColor: NSColor.white.withAlphaComponent(0.6),
                ])
                number.draw(at: CGPoint(x: frame.midX - number.size().width / 2, y: frame.minY - 20))
            }
        }
    }

    private func drawCaption(_ card: WindowManager.OverviewCard, in frame: CGRect) {
        let band = CGRect(x: frame.minX, y: frame.maxY - 24, width: frame.width, height: 24)
        guard frame.height > 60, frame.width > 70 else { return }
        NSColor.black.withAlphaComponent(0.6).setFill()
        band.fill()
        icons[card.pid]?.draw(in: CGRect(x: band.minX + 6, y: band.minY + 4, width: 16, height: 16),
                             from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        let title = card.title.isEmpty ? (NSRunningApplication(processIdentifier: card.pid)?.localizedName ?? "") : card.title
        NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.white, .paragraphStyle: style,
        ]).draw(in: CGRect(x: band.minX + 28, y: band.minY + 5, width: band.width - 34, height: 15))
    }

    // MARK: Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    private func card(at event: NSEvent) -> Int? {
        let point = convert(event.locationInWindow, from: nil)
        return cards.indices.first { rect(cards[$0]).contains(point) }
    }

    override func mouseMoved(with event: NSEvent) {
        guard let index = card(at: event), index != selected else { return }
        selected = index
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        if let index = card(at: event) { onPick?(cards[index].id) } else { onCancel?() }
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        switch Int(event.keyCode) {
        case kVK_Escape: onCancel?()
        case kVK_Return, kVK_ANSI_KeypadEnter, kVK_Space: onPick?(cards[selected].id)
        case kVK_LeftArrow, kVK_ANSI_H: moveColumn(-1)
        case kVK_RightArrow, kVK_ANSI_L: moveColumn(1)
        case kVK_UpArrow, kVK_ANSI_K: moveRow(-1)
        case kVK_DownArrow, kVK_ANSI_J: moveRow(1)
        default:
            // A digit picks the top window of that column.
            if let digit = event.charactersIgnoringModifiers.flatMap({ Int($0) }), digit >= 1,
               let index = cards.firstIndex(where: { $0.column == digit - 1 }) {
                onPick?(cards[index].id)
            }
        }
    }

    private func moveColumn(_ delta: Int) {
        let current = cards[selected]
        let row = cards[..<selected].filter { $0.column == current.column }.count
        let column = cards.indices.filter { cards[$0].column == current.column + delta }
        guard !column.isEmpty else { return }
        selected = column[min(row, column.count - 1)]
        needsDisplay = true
    }

    private func moveRow(_ delta: Int) {
        let next = selected + delta
        guard cards.indices.contains(next), cards[next].column == cards[selected].column else { return }
        selected = next
        needsDisplay = true
    }
}
