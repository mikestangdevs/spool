import AppKit
import ApplicationServices
import QuartzCore
import SpoolCore

final class ManagedWindow {
    let id: WindowID
    let element: AXUIElement
    let pid: pid_t
    /// Where the window was when Spool first saw it. Restored on quit.
    let originalFrame: CGRect
    /// False for windows that cannot be moved or resized; they are left alone.
    let canManage: Bool
    var stripKey: String?
    var floating = false
    /// The frame Spool last gave the window. A different real frame means the user dragged it.
    var lastSet: CGRect?
    /// Width the app fell back to when asked to go narrower.
    var minWidth = 0.0
    let bundleID: String?
    /// Hidden somewhere other than the edge it scrolled off, because another display is there.
    var relocated = false
    /// From macOS 26 a window with a toolbar has rounder corners than one with only a title
    /// bar. The system does not report the radius, so this is read off the window's make-up.
    lazy var cornerRadius: CGFloat = {
        guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26 else { return 10 }
        return element.hasToolbar ? 26 : 16
    }()
    /// Times this window was held back from the strip while a possible tab switch settled.
    var deferrals = 0

    init(id: WindowID, element: AXUIElement, pid: pid_t, bundleID: String?, frame: CGRect) {
        self.id = id
        self.bundleID = bundleID
        self.element = element
        self.pid = pid
        originalFrame = frame
        canManage = element.isSettable(kAXPositionAttribute) && element.isSettable(kAXSizeAttribute)
    }
}

private let observerCallback: AXObserverCallback = { _, element, notification, refcon in
    guard let refcon else { return }
    Unmanaged<WindowManager>.fromOpaque(refcon).takeUnretainedValue()
        .handle(notification as String, element)
}

private final class AppObserver {
    let element: AXUIElement
    private let observer: AXObserver
    private let refcon: UnsafeMutableRawPointer

    init?(pid: pid_t, refcon: UnsafeMutableRawPointer) {
        var created: AXObserver?
        guard AXObserverCreate(pid, observerCallback, &created) == .success, let created else { return nil }
        observer = created
        self.refcon = refcon
        element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, 0.25)   // a hung app must not hang the strip
        // An app that is still launching refuses; the next reconcile tries again.
        guard AXObserverAddNotification(observer, element, kAXWindowCreatedNotification as CFString, refcon) == .success else { return nil }
        for name in [kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification,
                     kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification,
                     kAXWindowMovedNotification, kAXWindowResizedNotification] {
            AXObserverAddNotification(observer, element, name as CFString, refcon)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
    }

    func watch(_ window: AXUIElement) {
        AXObserverAddNotification(observer, window, kAXUIElementDestroyedNotification as CFString, refcon)
    }

    deinit {
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
    }
}

/// Moves windows to their target frames. Position and size travel together on one spring
/// curve, so neighbouring windows stay edge to edge the whole way instead of opening gaps.
private final class Animator {
    struct Move {
        let window: ManagedWindow
        let from: CGRect
        let to: CGRect
        let animate: Bool
    }

    /// Called each time a window is placed, so overlays can follow it.
    var onPlace: ((ManagedWindow) -> Void)?
    /// Called when nothing is moving any more.
    var onIdle: (() -> Void)?
    /// Called with the windows whose size was changed, once they have reached it.
    var onResized: (([ManagedWindow]) -> Void)?

    private var moves: [Move] = []
    private var resized: [ManagedWindow] = []
    private var timer: Timer?
    private var start = 0.0
    private var duration = 0.0

    var isRunning: Bool { timer != nil }

    func run(_ new: [Move], duration: Double) {
        let incoming = Set(new.map(\.window.id))
        for move in moves where !incoming.contains(move.window.id) { place(move, 1) }
        timer?.invalidate()
        timer = nil
        moves = []
        for move in new {
            if abs(move.to.width - move.from.width) > 0.5 || abs(move.to.height - move.from.height) > 0.5 {
                resized.append(move.window)
            }
            if move.animate && duration > 0 && distance(move) > 1 {
                moves.append(move)
            } else {
                place(move, 1)
            }
        }
        guard !moves.isEmpty else {
            settle()
            return
        }
        self.duration = duration
        start = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func cancel() {
        timer?.invalidate()
        timer = nil
        moves = []
        resized = []
    }

    /// Jumps every window in flight to its target.
    func finish() {
        guard isRunning else { return }
        timer?.invalidate()
        timer = nil
        for move in moves { place(move, 1) }
        moves = []
        settle()
    }

    private func settle() {
        let done = resized
        resized = []
        if !done.isEmpty { onResized?(done) }
        onIdle?()
    }

    private func distance(_ move: Move) -> CGFloat {
        max(abs(move.to.minX - move.from.minX), abs(move.to.minY - move.from.minY),
            abs(move.to.width - move.from.width), abs(move.to.height - move.from.height))
    }

    /// An under-damped spring from 0 to 1: it overshoots by about 4% once, then settles.
    private func spring(_ t: Double) -> Double {
        let damping = 0.72, frequency = 9.5
        let damped = frequency * (1 - damping * damping).squareRoot()
        return 1 - exp(-damping * frequency * t) * (cos(damped * t) + damping * frequency / damped * sin(damped * t))
    }

    private func tick() {
        let t = min(1, (CACurrentMediaTime() - start) / duration)
        let progress = t >= 1 ? 1 : spring(t)
        for move in moves { place(move, progress) }
        if t >= 1 {
            timer?.invalidate()
            timer = nil
            moves = []
            settle()
        }
    }

    private func place(_ move: Move, _ t: Double) {
        func mix(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * t }
        let frame = CGRect(x: mix(move.from.minX, move.to.minX), y: mix(move.from.minY, move.to.minY),
                           width: max(1, mix(move.from.width, move.to.width)), height: max(1, mix(move.from.height, move.to.height)))
        // Resizing makes an app redraw, so only ask when the size really changed since last time.
        let last = move.window.lastSet?.size ?? move.from.size
        let resize = move.window.lastSet == nil || abs(last.width - frame.width) > 0.5 || abs(last.height - frame.height) > 0.5
        move.window.element.setPosition(frame.origin)
        if resize { move.window.element.setSize(frame.size) }
        move.window.lastSet = frame
        onPlace?(move.window)
    }
}

/// Tracks windows through the Accessibility API and keeps them on their strips.
final class WindowManager {
    static let shared = WindowManager()

    private(set) var running = false
    private let store = SettingsStore.shared
    private var settings: Settings { store.value }

    private var windows: [WindowID: ManagedWindow] = [:]
    private var strips: [String: Strip] = [:]
    private var observers: [pid_t: AppObserver] = [:]
    private let animator = Animator()

    private var dragged: Set<WindowID> = []
    private var pendingReconcile: DispatchWorkItem?
    private var safetyTimer: Timer?
    private var mouseMonitor: Any?
    private var notificationTokens: [(NotificationCenter, NSObjectProtocol)] = []
    private var applying = false
    /// The window whose edge the user is dragging, and when its neighbours were last moved.
    private var liveID: WindowID?
    private var lastLiveDraw = 0.0
    /// The window that has keyboard focus, as far as Spool knows. The border follows it.
    private var focusID: WindowID?
    private var pendingSave: DispatchWorkItem?
    private var marks: [String: WindowID] = [:]
    /// The strip being peeked at, and the scroll position to go back to.
    private var peekState: (key: String, offset: Double)?

    /// The strip being scrolled by a gesture, and when it was last redrawn.
    private var scrollKey: String?
    private var scrollStart = 0.0
    private var lastScrollDraw = 0.0

    private let widthPresets = [1.0 / 3, 0.5, 2.0 / 3, 1.0]
    private let animationDuration = 0.42

    // MARK: Lifecycle

    func start() {
        guard !running, AXIsProcessTrusted() else { return }
        running = true

        let workspace = NSWorkspace.shared.notificationCenter
        let soon: (Notification) -> Void = { [weak self] _ in self?.scheduleReconcile() }
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didHideApplicationNotification,
                     NSWorkspace.didUnhideApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification] {
            notificationTokens.append((workspace, workspace.addObserver(forName: name, object: nil, queue: .main, using: soon)))
        }
        notificationTokens.append((workspace, workspace.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
                self?.syncFocus(animated: true)
            }))
        notificationTokens.append((workspace, workspace.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
                if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                    self?.observers[app.processIdentifier] = nil
                }
                self?.scheduleReconcile()
            }))
        let center = NotificationCenter.default
        notificationTokens.append((center, center.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
                // Displays flicker while they wake or reconnect, so wait for them to settle.
                self?.scheduleReconcile(after: 1)
            }))

        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { self?.finishDrag() }
        }
        // Accessibility notifications are occasionally dropped; this catches what they miss.
        safetyTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.reconcile() }

        animator.onPlace = { [weak self] window in
            // The border is a separate window and cannot keep step with one that is moving,
            // so it steps aside and comes back when the window has landed.
            guard let self, window.id == self.focusID else { return }
            FocusBorder.shared.hide()
        }

        animator.onResized = { [weak self] windows in self?.checkMinimumWidths(windows) }
        animator.onIdle = { [weak self] in self?.updateBorder() }

        reconcile(initial: true)
    }

    /// Stops managing and puts every window back where Spool found it.
    func stop() {
        guard running else { return }
        running = false
        animator.cancel()
        pendingReconcile?.cancel()
        safetyTimer?.invalidate()
        safetyTimer = nil
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        mouseMonitor = nil
        notificationTokens.forEach { $0.0.removeObserver($0.1) }
        notificationTokens = []
        pendingSave?.cancel()
        saveSession()
        FocusBorder.shared.hide()
        focusID = nil
        marks = [:]
        peekState = nil
        liveID = nil
        for window in windows.values where window.lastSet != nil {
            window.element.setSize(window.originalFrame.size)
            window.element.setPosition(window.originalFrame.origin)
            window.element.setSize(window.originalFrame.size)
        }
        windows = [:]
        strips = [:]
        observers = [:]
        dragged = []
        scrollKey = nil
    }

    func settingsChanged() {
        guard running else { return }
        ensureAllVisible()
        apply(animated: true)
    }

    // MARK: Tracking

    fileprivate func handle(_ notification: String, _ element: AXUIElement) {
        guard running else { return }
        switch notification {
        case kAXWindowCreatedNotification:
            // A new window is often not ready to be measured yet; look twice.
            scheduleReconcile()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.reconcile() }
        case kAXUIElementDestroyedNotification:
            // Not removed here: closing a tab is followed by its neighbour appearing in the
            // same place, and reconcile needs to see both to keep the column.
            scheduleReconcile()
        case kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification:
            scheduleReconcile()
        case kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification:
            syncFocus(animated: true)
        case kAXWindowMovedNotification, kAXWindowResizedNotification:
            // Spool's own moves arrive here too; only a held mouse button means the user did it.
            guard let id = element.windowID else { return }
            let held = NSEvent.pressedMouseButtons & 1 != 0
            if held {
                dragged.insert(id)
                if notification == kAXWindowResizedNotification { liveResize(id) }
            }
            // Apps often settle on a slightly different size a moment after being asked.
            if id == focusID {
                if held { FocusBorder.shared.hide() } else { updateBorder() }
            }
        default:
            break
        }
    }

    private func scheduleReconcile(after delay: Double = 0.05) {
        pendingReconcile?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.reconcile() }
        pendingReconcile = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Brings the strips in line with the windows that actually exist and are showing.
    private func reconcile(initial: Bool = false) {
        guard running, scrollKey == nil else { return }
        let screens = currentScreens()
        let currentKeys = Set(screens.map(\.key))
        let showing = windowServerIDs([.optionOnScreenOnly, .excludeDesktopElements])
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        var arrivals: [(window: ManagedWindow, frame: CGRect)] = []
        var changed = false

        for app in NSWorkspace.shared.runningApplications
        where app.activationPolicy == .regular && !app.isTerminated && app.processIdentifier != getpid() {
            let pid = app.processIdentifier
            if observers[pid] == nil { observers[pid] = AppObserver(pid: pid, refcon: refcon) }
            guard let observer = observers[pid], let elements = observer.element.windows else { continue }
            for element in elements {
                guard let id = element.windowID else { continue }
                let window: ManagedWindow
                if let known = windows[id] {
                    window = known
                } else {
                    // Sheets, dialogs and panels are not standard windows and stay above the strip.
                    guard element.subrole == kAXStandardWindowSubrole, let frame = element.frame else { continue }
                    window = ManagedWindow(id: id, element: element, pid: pid, bundleID: app.bundleIdentifier, frame: frame)
                    if settings.rule(for: window.bundleID)?.floats == true { window.floating = true }
                    windows[id] = window
                    observer.watch(element)
                }
                guard window.canManage, !window.floating else { continue }
                let hidden = !showing.contains(id) || element.isMinimized || element.isFullscreen
                if let key = window.stripKey {
                    if currentKeys.contains(key) {
                        // A window that has merely stopped showing is dealt with below.
                        if element.isMinimized || element.isFullscreen {
                            detach(window)
                            changed = true
                        }
                    } else if !hidden {
                        // It was on another Space or a display that is gone, and has turned up here.
                        detach(window)
                        arrivals.append((window, element.frame ?? window.originalFrame))
                    }
                } else if !hidden {
                    arrivals.append((window, element.frame ?? window.originalFrame))
                }
            }
        }

        // Every tab of a tabbed window is a window of its own, and only the front tab is on
        // screen. Opening, switching or closing a tab therefore looks like one window vanishing
        // and another appearing in the same place. Treat that pair as one window: the newcomer
        // takes over the column instead of leaving a gap and opening a new one.
        var departed = windows.values.filter { window in
            window.stripKey.map(currentKeys.contains) == true && !showing.contains(window.id)
        }
        func sameSpot(_ a: CGRect, _ b: CGRect) -> Bool {
            // Loose on size: apps such as Terminal settle a little short of the size they were given.
            abs(a.minX - b.minX) < 6 && abs(a.minY - b.minY) < 6 && abs(a.width - b.width) < 30 && abs(a.height - b.height) < 30
        }
        var retry = false
        arrivals.removeAll { arrival in
            let new = arrival.window
            if let i = departed.firstIndex(where: { $0.pid == new.pid && $0.lastSet.map { sameSpot($0, arrival.frame) } == true }),
               let key = departed[i].stripKey, strips[key]?.replace(departed[i].id, with: new.id) == true {
                let old = departed.remove(at: i)
                new.stripKey = key
                new.lastSet = old.lastSet
                new.minWidth = old.minWidth
                new.relocated = old.relocated
                old.stripKey = nil
                old.lastSet = nil
                changed = true
                return true
            }
            // The old tab can still be on screen for a moment after the new one appears.
            // Hold the newcomer back briefly rather than give it a column it should not have.
            let twin = windows.values.contains { other in
                other.id != new.id && other.pid == new.pid && other.stripKey != nil && showing.contains(other.id)
                    && other.lastSet.map { sameSpot($0, arrival.frame) } == true
            }
            if twin && !initial && new.deferrals < 3 {
                new.deferrals += 1
                retry = true
                return true
            }
            return false
        }
        for window in departed {
            detach(window)
            changed = true
        }
        if retry { scheduleReconcile(after: 0.12) }

        // Windows on other Spaces are missing from the accessibility list, so only the
        // window server can say that one has really closed.
        let alive = windowServerIDs([.optionAll])
        for (id, window) in windows where !alive.contains(id) {
            detach(window)
            windows[id] = nil
            changed = true
        }

        if initial {
            if settings.restoreSession, let session = Session.load() {
                changed = restore(session, currentKeys, &arrivals) || changed
            }
            arrivals.sort { $0.frame.minX < $1.frame.minX }
        }
        for (window, frame) in arrivals {
            guard let screen = screen(for: frame, in: screens) else { continue }
            var strip = strips[screen.key] ?? Strip()
            let rule = settings.rule(for: window.bundleID)
            let width = (rule?.width ?? settings.newWindowWidth).width(current: Double(frame.width))
            if rule?.stacks == true, !initial {
                strip.addToFocusedColumn(window.id, width: width)
            } else {
                strip.insert(window.id, width: width, at: initial ? strip.columns.count : nil)
            }
            strips[screen.key] = strip
            window.stripKey = screen.key
            changed = true
        }

        dropEmptyStrips()
        focusID = focusedWindowID()
        guard changed else {
            updateBorder()
            return
        }
        if let id = focusID, let key = windows[id]?.stripKey { strips[key]?.focus(id) }
        ensureAllVisible()
        apply(animated: !initial)
    }

    // MARK: Session

    private struct Session: Codable {
        var strips: [String: Strip]
        /// Owning process of each window, as a guard against a reused window ID.
        var owners: [WindowID: pid_t]
        var floating: [WindowID]

        static var file: URL {
            let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Spool", isDirectory: true)
            return folder.appendingPathComponent("session.json")
        }

        static func load() -> Session? {
            guard let data = try? Data(contentsOf: file) else { return nil }
            return try? JSONDecoder().decode(Session.self, from: data)
        }
    }

    /// Puts arriving windows back into the columns they were in last time. Windows that have
    /// closed are dropped; windows that are new stay in `arrivals` and join the strip as usual.
    private func restore(_ session: Session, _ currentKeys: Set<String>,
                         _ arrivals: inout [(window: ManagedWindow, frame: CGRect)]) -> Bool {
        let same = { (window: ManagedWindow) in session.owners[window.id] == window.pid }
        for (window, _) in arrivals where session.floating.contains(window.id) && same(window) {
            window.floating = true
        }
        arrivals.removeAll { $0.window.floating }

        var restored = false
        for (key, saved) in session.strips where currentKeys.contains(key) {
            let back = Set(arrivals.filter { same($0.window) }.map(\.window.id))
            var strip = saved
            for id in saved.allWindows where !back.contains(id) { strip.remove(id) }
            guard !strip.isEmpty else { continue }
            strips[key] = strip
            for id in strip.allWindows { windows[id]?.stripKey = key }
            arrivals.removeAll { strip.locate($0.window.id) != nil }
            restored = true
        }
        return restored
    }

    private func saveSession() {
        guard running || !strips.isEmpty else { return }
        var owners: [WindowID: pid_t] = [:]
        for window in windows.values where window.stripKey != nil || window.floating { owners[window.id] = window.pid }
        let session = Session(strips: strips, owners: owners, floating: windows.values.filter(\.floating).map(\.id))
        do {
            try FileManager.default.createDirectory(at: Session.file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(session).write(to: Session.file, options: .atomic)
        } catch {
            NSLog("Spool: could not save the session: \(error.localizedDescription)")
        }
    }

    private func scheduleSave() {
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveSession() }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    private func detach(_ window: ManagedWindow) {
        if let key = window.stripKey { strips[key]?.remove(window.id) }
        window.stripKey = nil
    }

    private func dropEmptyStrips() {
        strips = strips.filter { !$0.value.isEmpty }
    }

    // MARK: Focus

    private func focusedWindowID() -> WindowID? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let element = observers[app.processIdentifier]?.element ?? AXUIElementCreateApplication(app.processIdentifier)
        return element.focusedWindow?.windowID
    }

    /// Follows focus that changed outside Spool (a click, ⌘-Tab) and scrolls it into view.
    private func syncFocus(animated: Bool) {
        guard running, scrollKey == nil else { return }
        focusID = focusedWindowID()
        defer { updateBorder() }
        guard let id = focusID, let key = windows[id]?.stripKey, let before = strips[key] else { return }
        strips[key]?.focus(id)
        ensureVisible(key)
        if strips[key] != before {
            apply(animated: animated)
            showMinimap(key)
        }
    }

    /// Fits the border to the focused window as it really is on screen, or hides it.
    private func updateBorder() {
        guard running, settings.focusBorder, !animator.isRunning, scrollKey == nil, liveID == nil,
              let id = focusID, let window = windows[id],
              let frame = windowServerBounds(id) ?? window.lastSet ?? window.element.frame else {
            FocusBorder.shared.hide()
            return
        }
        FocusBorder.shared.show(around: frame, below: id, width: settings.borderWidth, radius: window.cornerRadius)
    }

    private func focus(_ window: ManagedWindow) {
        focusID = window.id
        updateBorder()
        AXUIElementSetAttributeValue(window.element, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(window.element, kAXRaiseAction as CFString)
        NSRunningApplication(processIdentifier: window.pid)?.activate()
        // activate() from a background app can be ignored; the accessibility route is not.
        AXUIElementSetAttributeValue(AXUIElementCreateApplication(window.pid), kAXFrontmostAttribute as CFString, kCFBooleanTrue)
    }

    // MARK: Layout

    private func metrics(_ strip: Strip, _ screen: ScreenInfo) -> Metrics {
        var minWidths: [WindowID: Double] = [:]
        for id in strip.allWindows {
            if let min = windows[id]?.minWidth, min > 0 { minWidths[id] = min }
        }
        return Metrics(usable: Double(screen.area.width) - 2 * settings.outerGap, gap: settings.innerGap, minWidths: minWidths)
    }

    private func ensureVisible(_ key: String) {
        guard let screen = currentScreens().first(where: { $0.key == key }), let strip = strips[key] else { return }
        strips[key]?.ensureVisible(metrics(strip, screen))
    }

    private func ensureAllVisible() {
        for screen in currentScreens() {
            guard let strip = strips[screen.key] else { continue }
            strips[screen.key]?.ensureVisible(metrics(strip, screen))
        }
    }

    private func apply(animated: Bool, positionsOnly: Bool = false, skipping: WindowID? = nil) {
        var moves: [Animator.Move] = []
        let screens = currentScreens()
        for screen in screens {
            guard let strip = strips[screen.key] else { continue }
            let others = screens.filter { $0.key != screen.key }.map(\.full)
            let frames = strip.frames(in: screen.area, outer: settings.outerGap, metrics(strip, screen))
            for (id, raw) in frames where id != skipping {
                guard let window = windows[id] else { continue }
                let parked = park(raw, in: screen.full, avoiding: others)
                // A window going to or from a hiding place far from its edge must not be seen crossing the screen.
                let jump = parked.relocated || window.relocated
                window.relocated = parked.relocated
                let current = window.lastSet ?? window.element.frame ?? parked.frame
                var target = parked.frame
                if positionsOnly { target.size = current.size }
                if window.lastSet != nil, abs(current.minX - target.minX) < 0.5, abs(current.minY - target.minY) < 0.5,
                   abs(current.width - target.width) < 0.5, abs(current.height - target.height) < 0.5 {
                    continue
                }
                // Windows that stay off screen jump; nobody sees them travel.
                let seen = current.intersects(screen.full.insetBy(dx: 2, dy: 0)) || target.intersects(screen.full.insetBy(dx: 2, dy: 0))
                moves.append(.init(window: window, from: current, to: target, animate: animated && seen && !jump))
            }
        }
        animator.run(moves, duration: settings.animations ? animationDuration : 0)
        updateBorder()
        if !positionsOnly { scheduleSave() }
    }

    /// Some apps refuse to go as narrow as asked. Give their column the width they settled on.
    private func checkMinimumWidths(_ resized: [ManagedWindow]) {
        guard running, !applying, liveID == nil else { return }
        var grew = false
        for window in resized {
            guard let asked = window.lastSet, let actual = window.element.size,
                  actual.width > asked.width + 2, Double(actual.width) > window.minWidth else { continue }
            window.minWidth = Double(actual.width)
            grew = true
        }
        guard grew else { return }
        applying = true
        ensureAllVisible()
        apply(animated: false)
        applying = false
    }

    // MARK: Actions

    /// Runs an action on the active strip. `widthRatio` turns `.fullWidth` into "set this width".
    func perform(_ action: Action, widthRatio: Double? = nil) {
        guard running else { return }
        if scrollKey != nil { endScroll() }
        switch action {
        case .overview:
            Overview.shared.toggle()
            return
        case .setMark, .jumpToMark:
            promptForMark(set: action == .setMark)
            return
        case .peekLeft, .peekRight:
            return   // these act on press and release; see peek(_:)
        default:
            break
        }
        let screens = currentScreens()
        let focusedID = focusedWindowID()

        if action == .toggleFloat {
            toggleFloat(focusedID, screens)
            return
        }

        var key = screenUnderMouse(in: screens)?.key
        if let focusedID, let k = windows[focusedID]?.stripKey, strips[k] != nil {
            key = k
            strips[k]?.focus(focusedID)
        }
        guard let key, var strip = strips[key], let screen = screens.first(where: { $0.key == key }) else { return }
        let m = metrics(strip, screen)
        var keepOffset = false

        switch action {
        case .focusLeft: strip.moveFocus(by: -1)
        case .focusRight: strip.moveFocus(by: 1)
        case .focusUp: strip.focusRow(by: -1)
        case .focusDown: strip.focusRow(by: 1)
        case .moveLeft: strip.swapColumn(by: -1)
        case .moveRight: strip.swapColumn(by: 1)
        case .moveUp: strip.swapRow(by: -1)
        case .moveDown: strip.swapRow(by: 1)
        case .cycleWidth: strip.cycleWidth(widthPresets)
        case .fullWidth: strip.setFocusedWidth(.fraction(widthRatio ?? 1))
        case .matchWidths: strip.matchWidthsToFocused()
        case .stack: strip.stackLeft()
        case .unstack: strip.unstack()
        case .toggleTabs: strip.toggleTabs()
        case .evenStack: strip.evenFocusedStack()
        case .focusFirst: strip.focusColumn(0)
        case .focusLast: strip.focusColumn(strip.columns.count - 1)
        case .center:
            strip.center(m)
            keepOffset = true
        case .chain: strip.chain()
        case .nextDisplay:
            strips[key] = strip
            sendToNextDisplay(from: screen, screens)
            return
        case .toggleFloat:
            return
        default:
            if let index = action.columnIndex {
                strip.focusColumn(index)
            } else if let pattern = action.pattern, let first = strip.applyPattern(pattern) {
                strip.alignLeft(first, metrics(strip, screen))
                keepOffset = true
            }
        }

        if !keepOffset { strip.ensureVisible(metrics(strip, screen)) }
        strips[key] = strip
        apply(animated: true)
        if settings.widthOverlay, action == .cycleWidth || action == .fullWidth,
           let id = strip.focusedWindow, case .fraction(let share) = strip.columns[strip.focused].width,
           let frame = strip.frames(in: screen.area, outer: settings.outerGap, metrics(strip, screen))[id] {
            HUD.shared.show(widthLabel(share), over: frame.intersection(screen.area), big: true)
        }
        showMinimap(key)
        // Raise even when focus did not move: in a tab group the focused window must come forward.
        if let id = strip.focusedWindow, let window = windows[id], id != focusedID || strip.columns[strip.focused].tabbed {
            focus(window)
        }
    }

    private func toggleFloat(_ id: WindowID?, _ screens: [ScreenInfo]) {
        guard let id, let window = windows[id], window.canManage else { return }
        if window.floating {
            window.floating = false
            reconcile()
        } else {
            let screen = window.stripKey.flatMap { key in screens.first { $0.key == key } } ?? screens.first
            detach(window)
            window.floating = true
            window.lastSet = nil
            if let area = screen?.area {
                let size = CGSize(width: min(window.originalFrame.width, area.width * 0.8),
                                  height: min(window.originalFrame.height, area.height * 0.8))
                window.element.setSize(size)
                window.element.setPosition(CGPoint(x: area.midX - size.width / 2, y: area.midY - size.height / 2))
            }
            dropEmptyStrips()
            ensureAllVisible()
            apply(animated: true)
        }
        focus(window)
    }

    private func sendToNextDisplay(from screen: ScreenInfo, _ screens: [ScreenInfo]) {
        guard screens.count > 1, let index = screens.firstIndex(where: { $0.key == screen.key }),
              let id = strips[screen.key]?.focusedWindow, let window = windows[id],
              let column = strips[screen.key]?.remove(id) else { return }
        let destination = screens[(index + 1) % screens.count]
        var strip = strips[destination.key] ?? Strip()
        strip.insertColumn(column, at: strip.isEmpty ? 0 : strip.focused + 1)
        strips[destination.key] = strip
        window.stripKey = destination.key
        dropEmptyStrips()
        ensureAllVisible()
        apply(animated: true)
        focus(window)
    }

    // MARK: Mouse drags

    /// After the user lets go of a window: adopt a new size, or reorder to where it was dropped.
    private func finishDrag() {
        guard running, !dragged.isEmpty else { return }
        defer { updateBorder() }
        var ids = dragged
        dragged = []
        let screens = currentScreens()
        var changed = false
        if let live = liveID {
            // The neighbours have been following the edge; take the final size and let everything settle.
            liveID = nil
            adoptResize(live)
            if let key = windows[live]?.stripKey { strips[key]?.overscroll = false }
            // Windows Spool moved to keep up are in the set too; none of them was dragged.
            ids = []
            changed = true
        }
        for id in ids {
            guard let window = windows[id], let key = window.stripKey, var strip = strips[key],
                  let screen = screens.first(where: { $0.key == key }),
                  let frame = window.element.frame, let target = window.lastSet else { continue }
            let dw = abs(frame.width - target.width), dh = abs(frame.height - target.height)
            if dw > 3 || dh > 3 {
                if dw > 3 {
                    window.minWidth = 0
                    strip.setWidth(of: id, .points(Double(frame.width)))
                }
                if dh > 3 {
                    let available = Double(screen.area.height) - 2 * settings.outerGap
                    strip.setHeight(of: id, fraction: Double(frame.height) / available)
                }
                strips[key] = strip
            } else if hypot(frame.minX - target.minX, frame.minY - target.minY) > 20 {
                guard let destination = screenUnderMouse(in: screens), let column = strip.remove(id) else { continue }
                strips[key] = strip
                var into = strips[destination.key] ?? Strip()
                let m = metrics(into, destination)
                let left = Double(destination.area.minX) + settings.outerGap - into.offset
                let mids = zip(into.origins(m), into.widths(m)).map { left + $0 + $1 / 2 }
                into.insertColumn(column, at: mids.filter { $0 < Double(frame.midX) }.count)
                strips[destination.key] = into
                window.stripKey = destination.key
            } else {
                continue
            }
            window.lastSet = frame
            changed = true
        }
        guard changed else { return }
        dropEmptyStrips()
        ensureAllVisible()
        apply(animated: true)
    }

    /// Called as the user drags a window's edge: the rest of the strip follows straight away.
    private func liveResize(_ id: WindowID) {
        if liveID == nil {
            // Resize notifications also come from Spool's own animation. Finish it first, so
            // the next one can only be the user's.
            if animator.isRunning {
                animator.finish()
                return
            }
            guard windows[id]?.stripKey != nil else { return }
            liveID = id
        }
        guard liveID == id else { return }
        let now = CACurrentMediaTime()
        guard now - lastLiveDraw > 0.012 else { return }
        lastLiveDraw = now
        adoptResize(id)
        apply(animated: false, skipping: id)
    }

    /// Makes the strip agree with the size and position the user has given a window.
    private func adoptResize(_ id: WindowID) {
        guard let window = windows[id], let key = window.stripKey, var strip = strips[key],
              let screen = currentScreens().first(where: { $0.key == key }),
              let frame = window.element.frame, let place = strip.locate(id) else { return }
        window.minWidth = 0
        strip.setWidth(of: id, .points(Double(frame.width)))
        let column = strip.columns[place.column]
        if column.windows.count > 1, !column.tabbed, abs(frame.height - (window.lastSet?.height ?? frame.height)) > 1 {
            let available = Double(screen.area.height) - 2 * settings.outerGap
            strip.setHeight(of: id, fraction: Double(frame.height) / available)
        }
        // Dragging the left edge moves the window itself, so scroll the strip to keep the
        // column where the user has put it instead of pulling it back.
        if let laid = strip.frames(in: screen.area, outer: settings.outerGap, metrics(strip, screen))[id] {
            strip.offset += Double(laid.minX - frame.minX)
            strip.overscroll = true
        }
        strips[key] = strip
        window.lastSet = frame
    }

    // MARK: Shared helpers for the features below

    /// The strip holding the focused window, or failing that the one under the pointer.
    private func activeStrip() -> (key: String, screen: ScreenInfo)? {
        let screens = currentScreens()
        var key = screenUnderMouse(in: screens)?.key
        if let id = focusedWindowID(), let k = windows[id]?.stripKey, strips[k] != nil {
            key = k
            strips[k]?.focus(id)
        }
        guard let key, strips[key] != nil, let screen = screens.first(where: { $0.key == key }) else { return nil }
        return (key, screen)
    }

    private func showMinimap(_ key: String) {
        guard settings.minimap, let strip = strips[key], strip.columns.count > 1,
              let screen = currentScreens().first(where: { $0.key == key }) else { return }
        let m = metrics(strip, screen)
        let total = strip.totalWidth(m)
        guard total > m.usable + 1 else { return }   // everything is already in view
        Minimap.shared.show(origins: strip.origins(m), widths: strip.widths(m), total: total, offset: strip.offset,
                            usable: m.usable, focused: strip.focused, over: screen.area)
    }

    private func announce(_ text: String, hold: Double = 0.9) {
        let frame = focusID.flatMap { windows[$0] }.flatMap { $0.lastSet ?? $0.element.frame }
        guard let area = frame ?? screenUnderMouse(in: currentScreens())?.area else { return }
        HUD.shared.show(text, over: area, hold: hold)
    }

    /// Focuses any known window, scrolling its strip to it.
    func select(_ id: WindowID) {
        guard running, let window = windows[id] else { return }
        if let key = window.stripKey {
            strips[key]?.focus(id)
            ensureVisible(key)
            apply(animated: true)
        }
        focus(window)
    }

    // MARK: Overview

    struct OverviewCard {
        let id: WindowID
        /// Position on the unscrolled strip, in points.
        let frame: CGRect
        let title: String
        let pid: pid_t
        let column: Int
        let focused: Bool
    }

    /// The active strip laid out end to end, for the overview to draw.
    func overviewCards() -> (screen: ScreenInfo, cards: [OverviewCard], size: CGSize)? {
        guard running, let (key, screen) = activeStrip(), var strip = strips[key] else { return nil }
        let m = metrics(strip, screen)
        strip.offset = 0
        let area = CGRect(origin: .zero, size: screen.area.size)
        let frames = strip.frames(in: area, outer: settings.outerGap, m)
        var cards: [OverviewCard] = []
        for (c, column) in strip.columns.enumerated() {
            for (r, id) in column.windows.enumerated() {
                // In a tab group only the front tab is shown.
                if column.tabbed && r != column.active { continue }
                guard let window = windows[id], let frame = frames[id] else { continue }
                cards.append(OverviewCard(id: id, frame: frame, title: window.element.title ?? "", pid: window.pid,
                                          column: c, focused: c == strip.focused && r == column.active))
            }
        }
        return (screen, cards, CGSize(width: strip.totalWidth(m) + 2 * settings.outerGap, height: area.height))
    }

    // MARK: Marks

    func setMark(_ name: String) {
        guard running, let id = focusedWindowID(), windows[id] != nil else { return }
        marks[name] = id
        announce("Marked \(name.uppercased())")
    }

    func jump(toMark name: String) {
        guard running else { return }
        guard let id = marks[name], windows[id] != nil else {
            marks[name] = nil   // the window it pointed at has closed
            announce("No window marked \(name.uppercased())")
            return
        }
        select(id)
    }

    private func promptForMark(set: Bool) {
        announce(set ? "Mark with…" : "Jump to…", hold: KeyCapture.timeout)
        KeyCapture.shared.next { [weak self] key in
            HUD.shared.hide()
            guard let self, let key, key.count == 1, key.first!.isLetter || key.first!.isNumber else { return }
            set ? self.setMark(key) : self.jump(toMark: key)
        }
    }

    // MARK: Peek

    /// Slides the neighbouring column into view without moving focus. `endPeek` slides back.
    func peek(_ action: Action) {
        guard running, peekState == nil, scrollKey == nil, let (key, screen) = activeStrip(),
              let strip = strips[key] else { return }
        var shifted = strip
        shifted.moveFocus(by: action == .peekLeft ? -1 : 1)
        shifted.overscroll = false
        shifted.ensureVisible(metrics(strip, screen))
        guard shifted.focused != strip.focused, shifted.offset != strip.offset else { return }
        peekState = (key, strip.offset)
        strips[key]?.offset = shifted.offset
        strips[key]?.overscroll = true
        apply(animated: true)
        showMinimap(key)
    }

    func endPeek() {
        guard let state = peekState else { return }
        peekState = nil
        strips[state.key]?.offset = state.offset
        strips[state.key]?.overscroll = false
        ensureVisible(state.key)
        apply(animated: true)
        showMinimap(state.key)
    }

    // MARK: Named strips

    /// Remembers the active strip as an arrangement of apps. Returns false when there is none.
    @discardableResult
    func saveStrip(named name: String) -> Bool {
        guard running, let (key, _) = activeStrip(), let strip = strips[key] else { return false }
        let columns: [SavedStrip.Column] = strip.columns.compactMap { column in
            // A window whose app has no bundle ID cannot be found again, so it is left out.
            let kept = column.windows.indices.filter { windows[column.windows[$0]]?.bundleID != nil }
            guard !kept.isEmpty else { return nil }
            return SavedStrip.Column(apps: kept.map { windows[column.windows[$0]]!.bundleID! },
                                     weights: kept.map { column.weights[$0] }, width: column.width, tabbed: column.tabbed)
        }
        guard !columns.isEmpty else { return false }
        SavedStrips.shared.save(SavedStrip(name: name, columns: columns))
        announce("Saved “\(name)”")
        return true
    }

    /// Rebuilds a remembered strip on the active screen from the windows that are open,
    /// opening any app that is not running and slotting its window in when it appears.
    func loadStrip(named name: String, attempt: Int = 0) {
        guard running, let saved = SavedStrips.shared.strip(named: name) else {
            if attempt == 0 { announce("No strip named “\(name)”") }
            return
        }
        let screens = currentScreens()
        guard let screen = activeStrip()?.screen ?? screenUnderMouse(in: screens) else { return }
        let currentKeys = Set(screens.map(\.key))

        if attempt == 0 {
            let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
            let quiet = NSWorkspace.OpenConfiguration()
            quiet.activates = false
            for app in Set(saved.columns.flatMap(\.apps)).subtracting(running) {
                if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app) {
                    NSWorkspace.shared.openApplication(at: url, configuration: quiet)
                }
            }
        }
        reconcile()

        // Prefer windows already on this strip, so recalling a strip twice changes nothing.
        let candidates = windows.values
            .filter { $0.stripKey.map(currentKeys.contains) ?? false }
            .sorted { ($0.stripKey == screen.key ? 0 : 1, $0.id) < ($1.stripKey == screen.key ? 0 : 1, $1.id) }
        var used: Set<WindowID> = []
        var columns: [Column] = []
        var waiting = false
        for wanted in saved.columns {
            var column: Column?
            for app in wanted.apps {
                guard let window = candidates.first(where: { $0.bundleID == app && !used.contains($0.id) }) else {
                    waiting = true
                    continue
                }
                used.insert(window.id)
                if column == nil { column = Column(window.id, width: wanted.width) } else { column?.append(window.id) }
            }
            guard var column else { continue }
            if column.windows.count == wanted.apps.count { column.weights = wanted.weights }
            column.tabbed = wanted.tabbed && column.windows.count > 1
            columns.append(column)
        }

        if !columns.isEmpty {
            for id in used { windows[id].map(detach) }
            var strip = strips[screen.key] ?? Strip()
            strip.columns = columns + strip.columns   // windows the strip did not ask for follow it
            strip.focused = 0
            strip.offset = 0
            strip.overscroll = false
            strips[screen.key] = strip
            for id in used { windows[id]?.stripKey = screen.key }
            dropEmptyStrips()
            ensureAllVisible()
            apply(animated: true)
            if attempt == 0 || !waiting, let id = strip.focusedWindow, let window = windows[id] { focus(window) }
        }
        // Apps that were just opened need a moment before their windows exist.
        if waiting && attempt < 12 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.loadStrip(named: name, attempt: attempt + 1)
            }
        }
    }

    // MARK: Free scrolling (gestures)

    /// Starts sliding the strip under the pointer. Returns false when there is nothing to slide.
    @discardableResult
    func beginScroll() -> Bool {
        guard running, let screen = screenUnderMouse(in: currentScreens()), let strip = strips[screen.key] else { return false }
        animator.finish()
        scrollKey = screen.key
        scrollStart = strip.offset
        return true
    }

    /// Slides the strip to `delta` points from where the gesture began. Positive moves content left.
    func scroll(to delta: Double) {
        guard let key = scrollKey, let strip = strips[key],
              let screen = currentScreens().first(where: { $0.key == key }) else { return }
        let slack = 80.0
        strips[key]?.offset = min(max(scrollStart + delta, -slack), strip.maxOffset(metrics(strip, screen)) + slack)
        strips[key]?.overscroll = true
        let now = CACurrentMediaTime()
        guard now - lastScrollDraw > 0.008 else { return }
        lastScrollDraw = now
        apply(animated: false, positionsOnly: true)
        showMinimap(key)
    }

    func scroll(by delta: Double) {
        guard let key = scrollKey, let strip = strips[key] else { return }
        scroll(to: strip.offset - scrollStart + delta)
    }

    /// Ends a slide: focus the column it landed on and line the strip up.
    func endScroll() {
        guard let key = scrollKey else { return }
        scrollKey = nil
        guard var strip = strips[key], let screen = currentScreens().first(where: { $0.key == key }) else { return }
        let m = metrics(strip, screen)
        if let column = strip.settleColumn(m) { strip.focusColumn(column) }
        strip.overscroll = false
        strip.ensureVisible(m)
        strips[key] = strip
        apply(animated: true)
        showMinimap(key)
        if let id = strip.focusedWindow, let window = windows[id], id != focusedWindowID() { focus(window) }
    }
}
