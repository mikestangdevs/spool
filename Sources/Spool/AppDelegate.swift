import AppKit
import ApplicationServices
import SpoolCore
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let manager = WindowManager.shared
    private let store = SettingsStore.shared
    private var settingsWindow: NSWindow?
    private var trustTimer: Timer?
    private var signalSources: [DispatchSourceSignal] = []
    private var enabled = true

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem.button?.image = menuBarIcon()
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false   // otherwise AppKit re-enables the items disabled below
        statusItem.menu = menu

        HotkeyCenter.shared.handler = { [weak self] action, pressed in
            guard let self else { return }
            if action == .peekLeft || action == .peekRight {
                pressed ? self.manager.peek(action) : self.manager.endPeek()
            } else if pressed {
                self.manager.perform(action)
            }
        }
        store.onChange = { [weak self] in
            guard let self else { return }
            if self.manager.running { HotkeyCenter.shared.register(self.store.value.bindings) }
            self.manager.settingsChanged()
        }

        // Put windows back even when the process is asked to stop from outside.
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { NSApp.terminate(nil) }
            source.resume()
            signalSources.append(source)
        }

        if AXIsProcessTrusted() {
            begin()
        } else {
            let prompt = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            AXIsProcessTrustedWithOptions(prompt)
            trustTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
                guard AXIsProcessTrusted() else { return }
                timer.invalidate()
                self?.begin()
            }
        }
    }

    /// `spool://focus?direction=east`, from `spoolctl`, `open`, or any launcher.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            switch Command.parse(url) {
            case .action(let name):
                if let action = Action(rawValue: name) { manager.perform(action) }
            case .width(let ratio):
                manager.perform(.fullWidth, widthRatio: ratio)
            case .saveStrip(let name):
                manager.saveStrip(named: name)
            case .loadStrip(let name):
                manager.loadStrip(named: name)
            case .mark(let name):
                manager.setMark(name)
            case .jumpToMark(let name):
                manager.jump(toMark: name)
            case nil:
                NSLog("Spool: ignored unrecognised URL \(url.absoluteString)")
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        manager.stop()
    }

    private func begin() {
        guard enabled, AXIsProcessTrusted() else { return }
        manager.start()
        HotkeyCenter.shared.register(store.value.bindings)
        SwipeRecognizer.shared.start()
        OptionScroll.shared.start()
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let trusted = AXIsProcessTrusted()
        if !trusted {
            let note = NSMenuItem(title: "Spool needs Accessibility access to move windows", action: nil, keyEquivalent: "")
            note.isEnabled = false
            menu.addItem(note)
            menu.addItem(item("Grant Accessibility Access…", #selector(openAccessibility)))
            menu.addItem(.separator())
        }
        menu.addItem(item(manager.running ? "Turn Spool Off" : "Turn Spool On", #selector(toggleEnabled)))
        menu.addItem(.separator())

        let overview = item("Overview", #selector(showOverview))
        overview.isEnabled = manager.running
        if let combo = store.value.combo(for: .overview) { overview.toolTip = combo.display }
        menu.addItem(overview)

        let strips = NSMenu()
        let saved = SavedStrips.shared.names
        for name in saved {
            let entry = item(name, #selector(loadStrip(_:)))
            entry.representedObject = name
            strips.addItem(entry)
        }
        if !saved.isEmpty { strips.addItem(.separator()) }
        strips.addItem(item("Save Current Strip…", #selector(saveStrip)))
        if !saved.isEmpty {
            let remove = NSMenu()
            for name in saved {
                let entry = item(name, #selector(deleteStrip(_:)))
                entry.representedObject = name
                remove.addItem(entry)
            }
            let parent = NSMenuItem(title: "Delete", action: nil, keyEquivalent: "")
            parent.submenu = remove
            strips.addItem(parent)
        }
        let stripsItem = NSMenuItem(title: "Strips", action: nil, keyEquivalent: "")
        stripsItem.submenu = strips
        stripsItem.isEnabled = manager.running
        menu.addItem(stripsItem)
        menu.addItem(.separator())
        for action in Action.layouts {
            let entry = item(action.title, #selector(runLayout(_:)))
            entry.representedObject = action.rawValue
            entry.image = layoutPicture(action.pattern)
            entry.isEnabled = manager.running
            if let combo = store.value.combo(for: action) { entry.toolTip = combo.display }
            menu.addItem(entry)
        }
        menu.addItem(.separator())
        menu.addItem(item("Settings…", #selector(openSettings), key: ","))
        menu.addItem(item("Quit Spool", #selector(quit), key: "q"))
    }

    private func item(_ title: String, _ selector: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.target = self
        return item
    }

    /// The strip in miniature: the focused window, with its neighbours running off both edges.
    private func menuBarIcon() -> NSImage {
        let size = NSSize(width: 20, height: 16)
        let image = NSImage(size: size, flipped: false) { bounds in
            NSBezierPath(rect: bounds).addClip()
            func pane(_ x: CGFloat, _ width: CGFloat, _ alpha: CGFloat) {
                NSColor.black.withAlphaComponent(alpha).setFill()
                NSBezierPath(roundedRect: NSRect(x: x, y: 2.5, width: width, height: 11), xRadius: 2, yRadius: 2).fill()
            }
            pane(-3, 6.5, 0.45)
            pane(5.5, 9, 1)
            pane(16.5, 6.5, 0.45)
            return true
        }
        image.isTemplate = true   // macOS tints it for light and dark menu bars
        image.accessibilityDescription = "Spool"
        return image
    }

    /// A small diagram of a layout: one box per window. `nil` draws the chain running off the edge.
    private func layoutPicture(_ pattern: [Int]?) -> NSImage {
        let size = NSSize(width: 24, height: 14)
        let image = NSImage(size: size, flipped: true) { _ in
            let columns = pattern ?? [1, 1, 1]
            let chain = pattern == nil
            let gap: CGFloat = 1.5
            let width = chain ? 9 : (size.width - gap * CGFloat(columns.count - 1)) / CGFloat(columns.count)
            NSBezierPath(rect: NSRect(origin: .zero, size: size)).addClip()
            for (c, rows) in columns.enumerated() {
                let height = (size.height - gap * CGFloat(rows - 1)) / CGFloat(rows)
                for r in 0..<rows {
                    let box = NSRect(x: CGFloat(c) * (width + gap), y: CGFloat(r) * (height + gap), width: width, height: height)
                    NSBezierPath(roundedRect: box, xRadius: 1.5, yRadius: 1.5).fill()
                }
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    @objc private func toggleEnabled() {
        // Spool can be switched on and still not running, when the permission is missing.
        if manager.running {
            enabled = false
            HotkeyCenter.shared.unregisterAll()
            manager.stop()
        } else {
            enabled = true
            AXIsProcessTrusted() ? begin() : openAccessibility()
        }
    }

    @objc private func runLayout(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let action = Action(rawValue: raw) else { return }
        // Let the menu close and focus return to the window first.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.manager.perform(action) }
    }

    @objc private func showOverview() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.manager.perform(.overview) }
    }

    @objc private func loadStrip(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.manager.loadStrip(named: name) }
    }

    @objc private func deleteStrip(_ sender: NSMenuItem) {
        if let name = sender.representedObject as? String { SavedStrips.shared.delete(named: name) }
    }

    @objc private func saveStrip() {
        let alert = NSAlert()
        alert.messageText = "Save this strip"
        alert.informativeText = "Spool remembers which apps are in which columns, and their widths. Recalling it reopens any that are closed."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = "Name, such as coding"
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        // Read the strip before the alert takes focus away from it.
        let previous = NSWorkspace.shared.frontmostApplication
        NSApp.activate(ignoringOtherApps: true)
        let confirmed = alert.runModal() == .alertFirstButtonReturn
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        previous?.activate()
        guard confirmed, !name.isEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.manager.saveStrip(named: name) }
    }

    @objc private func openAccessibility() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView()))
            window.title = "Spool Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
