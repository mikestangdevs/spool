import AppKit
import Carbon.HIToolbox
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @ObservedObject var store = SettingsStore.shared

    var body: some View {
        TabView {
            general.tabItem { Label("General", systemImage: "gearshape") }
            shortcuts.tabItem { Label("Shortcuts", systemImage: "keyboard") }
            gestures.tabItem { Label("Gestures", systemImage: "hand.draw") }
            apps.tabItem { Label("Apps", systemImage: "app.badge") }
        }
        .frame(width: 600, height: 600)
        .padding()
    }

    private var general: some View {
        Form {
            Picker("New windows open at", selection: $store.value.newWindowWidth) {
                ForEach(NewWindowWidth.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            LabeledContent("Gap around the strip") {
                Slider(value: $store.value.outerGap, in: 0...40, step: 1)
                Text("\(Int(store.value.outerGap)) pt").monospacedDigit().frame(width: 44, alignment: .trailing)
            }
            LabeledContent("Gap between windows") {
                Slider(value: $store.value.innerGap, in: 0...40, step: 1)
                Text("\(Int(store.value.innerGap)) pt").monospacedDigit().frame(width: 44, alignment: .trailing)
            }
            Toggle("Animate window movement", isOn: $store.value.animations)
            Toggle("Border around the focused window", isOn: $store.value.focusBorder)
            if store.value.focusBorder {
                LabeledContent("Border thickness") {
                    Slider(value: $store.value.borderWidth, in: 1...8, step: 1)
                    Text("\(Int(store.value.borderWidth)) pt").monospacedDigit().frame(width: 44, alignment: .trailing)
                }
            }
            Toggle("Show the width when it changes", isOn: $store.value.widthOverlay)
            Toggle("Restore the strip when Spool reopens", isOn: $store.value.restoreSession)
            Toggle("Show a map of the strip while it moves", isOn: $store.value.minimap)
            Toggle("Window pictures in the overview", isOn: Binding(get: { store.value.overviewThumbnails }, set: { wanted in
                store.value.overviewThumbnails = wanted
                // macOS shows its own prompt the first time; after that the user must use System Settings.
                if wanted && !CGPreflightScreenCaptureAccess() { CGRequestScreenCaptureAccess() }
            }))
            if store.value.overviewThumbnails && !CGPreflightScreenCaptureAccess() {
                Text("Pictures need Screen Recording access for Spool in System Settings → Privacy & Security. Until then the overview shows app icons.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            LaunchAtLoginToggle()
        }
        .formStyle(.grouped)
    }

    private var shortcuts: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("Style", selection: $store.value.style) {
                    ForEach(ShortcutStyle.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .fixedSize()
                Spacer()
                Button("Reset all") { store.value.overrides = [:] }
                    .disabled(store.value.overrides.isEmpty)
            }
            if let caution = store.value.style.caution {
                Text(caution).font(.callout).foregroundStyle(.secondary)
            }
            List(Action.allCases, id: \.self) { action in
                HStack {
                    Text(action.title)
                    if store.value.conflicts.contains(action) {
                        Label("Shared with another action", systemImage: "exclamationmark.triangle.fill")
                            .labelStyle(.iconOnly).foregroundStyle(.yellow)
                            .help("Another action uses this chord. Only one of them will fire.")
                    } else if HotkeyCenter.shared.failed.contains(action) {
                        Label("Unavailable", systemImage: "exclamationmark.triangle.fill")
                            .labelStyle(.iconOnly).foregroundStyle(.orange)
                            .help("macOS or another app already owns this chord.")
                    }
                    Spacer()
                    ShortcutRecorder(action: action)
                }
            }
        }
    }

    private var apps: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Rules decide what happens to an app's windows as they open. Windows already on the strip stay as they are.")
                .font(.callout).foregroundStyle(.secondary)
            List {
                ForEach($store.value.rules) { $rule in
                    HStack {
                        Text(rule.name).frame(width: 110, alignment: .leading).lineLimit(1)
                        Picker("", selection: $rule.floats) {
                            Text("On the strip").tag(false)
                            Text("Floating").tag(true)
                        }
                        .labelsHidden().fixedSize()
                        if !rule.floats {
                            Picker("", selection: $rule.width) {
                                Text("Usual width").tag(NewWindowWidth?.none)
                                ForEach(NewWindowWidth.allCases, id: \.self) { Text($0.title).tag(NewWindowWidth?.some($0)) }
                            }
                            .labelsHidden().frame(width: 130)
                            Toggle("Stack", isOn: $rule.stacks)
                                .help("Open under the focused window instead of beside it.")
                        }
                        Spacer()
                        Button {
                            store.value.rules.removeAll { $0.bundleID == rule.bundleID }
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
            Menu("Add a Running App") {
                ForEach(candidates, id: \.bundleID) { app in
                    Button(app.name) { store.value.rules.append(app) }
                }
            }
            .fixedSize()
        }
    }

    private var candidates: [AppRule] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != getpid() }
            .compactMap { app in app.bundleIdentifier.map { AppRule(bundleID: $0, name: app.localizedName ?? $0) } }
            .filter { store.value.rule(for: $0.bundleID) == nil }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var gestures: some View {
        Form {
            Picker("Finger swipe", selection: $store.value.swipeFingers) {
                Text("Off").tag(0)
                Text("3 fingers").tag(3)
                Text("4 fingers").tag(4)
            }
            Toggle("⌥ + scroll slides the strip", isOn: $store.value.optionScroll)
            Text("macOS uses the same fingers for switching Spaces. In System Settings → Trackpad → More Gestures, turn off “Swipe between full-screen applications” or move it to the other finger count. Turn off Three Finger Drag too if you use it.")
                .font(.callout).foregroundStyle(.secondary)
            if !SwipeRecognizer.shared.available {
                Text("No trackpad was found, so finger swipes are inactive.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct LaunchAtLoginToggle: View {
    @State private var enabled = SMAppService.mainApp.status == .enabled

    var body: some View {
        Toggle("Open at login", isOn: Binding(get: { enabled }, set: { wanted in
            do {
                if wanted { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                NSLog("Spool: could not change the login item: \(error.localizedDescription)")
            }
            enabled = SMAppService.mainApp.status == .enabled
        }))
    }
}

private struct ShortcutRecorder: View {
    let action: Action
    @ObservedObject var store = SettingsStore.shared
    @State private var monitor: Any?

    var body: some View {
        Button(monitor != nil ? "Press keys…" : (store.value.combo(for: action)?.display ?? "None")) {
            monitor == nil ? begin() : end()
        }
        .frame(minWidth: 96)
        .onDisappear(perform: end)
    }

    private func begin() {
        // Let existing chords through to this window so they can be re-recorded.
        HotkeyCenter.shared.unregisterAll()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == UInt16(kVK_Escape) {
                end()
                return nil
            }
            var mods: UInt32 = 0
            if event.modifierFlags.contains(.control) { mods |= UInt32(controlKey) }
            if event.modifierFlags.contains(.option) { mods |= UInt32(optionKey) }
            if event.modifierFlags.contains(.shift) { mods |= UInt32(shiftKey) }
            if event.modifierFlags.contains(.command) { mods |= UInt32(cmdKey) }
            // A chord needs a real modifier or it would swallow ordinary typing.
            guard mods & UInt32(controlKey | optionKey | cmdKey) != 0 else {
                NSSound.beep()
                return nil
            }
            let combo = KeyCombo(keyCode: UInt32(event.keyCode), mods: mods, label: label(for: event))
            end()
            store.value.overrides[action.rawValue] = combo
            return nil
        }
    }

    private func end() {
        guard let monitor else { return }
        NSEvent.removeMonitor(monitor)
        self.monitor = nil
        HotkeyCenter.shared.register(store.value.bindings)
    }

    private func label(for event: NSEvent) -> String {
        let named: [Int: String] = [
            kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
            kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫",
        ]
        if let name = named[Int(event.keyCode)] { return name }
        return event.charactersIgnoringModifiers?.uppercased() ?? "Key \(event.keyCode)"
    }
}
