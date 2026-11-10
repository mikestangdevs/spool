import Carbon.HIToolbox
import Foundation
import SpoolCore

enum Action: String, CaseIterable, Codable {
    case focusLeft, focusRight, focusUp, focusDown
    case moveLeft, moveRight, moveUp, moveDown
    case cycleWidth, fullWidth, matchWidths
    case stack, unstack, toggleTabs, evenStack
    case toggleFloat, nextDisplay
    case column1, column2, column3, column4, column5, column6, column7, column8, column9
    case focusFirst, focusLast, center
    case layout2, layout3, layout2plus1, layout1plus2, layout4, layout5, layout6, chain
    case overview, setMark, jumpToMark, peekLeft, peekRight

    var title: String {
        switch self {
        case .focusLeft: return "Focus previous column"
        case .focusRight: return "Focus next column"
        case .focusUp: return "Focus up in stack"
        case .focusDown: return "Focus down in stack"
        case .moveLeft: return "Swap with left neighbour"
        case .moveRight: return "Swap with right neighbour"
        case .moveUp: return "Move up in stack"
        case .moveDown: return "Move down in stack"
        case .cycleWidth: return "Cycle width"
        case .fullWidth: return "Full width"
        case .matchWidths: return "Match other columns to focused width"
        case .stack: return "Stack into the column on the left"
        case .unstack: return "Unstack"
        case .toggleTabs: return "Tabs in column"
        case .evenStack: return "Even a stack"
        case .toggleFloat: return "Toggle floating"
        case .nextDisplay: return "Send to next display"
        case .focusFirst: return "Focus first column"
        case .focusLast: return "Focus last column"
        case .center: return "Centre column"
        case .layout2: return "2 across"
        case .layout3: return "3 in a row"
        case .layout2plus1: return "2 + 1"
        case .layout1plus2: return "1 + 2"
        case .layout4: return "4 grid"
        case .layout5: return "5 grid"
        case .layout6: return "6 grid"
        case .chain: return "Chain"
        case .overview: return "Overview of the whole strip"
        case .setMark: return "Mark this window (then a letter)"
        case .jumpToMark: return "Jump to a mark (then a letter)"
        case .peekLeft: return "Peek left while held"
        case .peekRight: return "Peek right while held"
        default: return "Focus column \(columnIndex! + 1)"
        }
    }

    static let columns: [Action] = [.column1, .column2, .column3, .column4, .column5, .column6, .column7, .column8, .column9]
    var columnIndex: Int? { Action.columns.firstIndex(of: self) }

    static let layouts: [Action] = [.layout2, .layout3, .layout2plus1, .layout1plus2, .layout4, .layout5, .layout6, .chain]

    /// Windows per column for the layout pictures. Five is two stacked pairs and one tall window.
    var pattern: [Int]? {
        switch self {
        case .layout2: return [1, 1]
        case .layout3: return [1, 1, 1]
        case .layout2plus1: return [2, 1]
        case .layout1plus2: return [1, 2]
        case .layout4: return [2, 2]
        case .layout5: return [2, 2, 1]
        case .layout6: return [2, 2, 2]
        default: return nil
        }
    }
}

struct KeyCombo: Codable, Equatable {
    var keyCode: UInt32
    /// Carbon modifier flags.
    var mods: UInt32
    var label: String

    var display: String {
        var s = ""
        if mods & UInt32(controlKey) != 0 { s += "⌃" }
        if mods & UInt32(optionKey) != 0 { s += "⌥" }
        if mods & UInt32(shiftKey) != 0 { s += "⇧" }
        if mods & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + label
    }
}

enum ShortcutStyle: String, Codable, CaseIterable {
    case arrows, vim, option, commandOption

    var title: String {
        switch self {
        case .arrows: return "Control-Option + arrows"
        case .vim: return "Control-Option + H J K L"
        case .option: return "Option"
        case .commandOption: return "Command-Option"
        }
    }

    /// Carbon modifiers held for every strip chord in this style.
    var modifiers: UInt32 {
        switch self {
        case .arrows, .vim: return UInt32(controlKey | optionKey)
        case .option: return UInt32(optionKey)
        case .commandOption: return UInt32(cmdKey | optionKey)
        }
    }

    /// What the style takes away from other apps, shown under the picker.
    var caution: String? {
        switch self {
        case .arrows, .vim: return nil
        case .option: return "Option alone takes over ⌥-arrow word movement and the characters typed with ⌥ and a letter, in every app."
        case .commandOption: return "Several of these chords, such as ⌘⌥F, ⌘⌥S and ⌘⌥T, are menu shortcuts in many apps and will stop reaching them."
        }
    }
}

enum NewWindowWidth: String, Codable, CaseIterable {
    case keep, third, half, twoThirds, full
    var title: String {
        switch self {
        case .keep: return "Keep the window's own width"
        case .third: return "One third"
        case .half: return "Half"
        case .twoThirds: return "Two thirds"
        case .full: return "Full"
        }
    }
    func width(current: Double) -> ColumnWidth {
        switch self {
        case .keep: return .points(current)
        case .third: return .fraction(1.0 / 3)
        case .half: return .fraction(0.5)
        case .twoThirds: return .fraction(2.0 / 3)
        case .full: return .fraction(1)
        }
    }
}

/// How one app's windows should be treated when they open.
struct AppRule: Codable, Equatable, Identifiable {
    var bundleID: String
    var name: String
    /// Leave this app's windows off the strip.
    var floats = false
    /// Width for its new windows; nil uses the general setting.
    var width: NewWindowWidth?
    /// Open under the focused window instead of beside it.
    var stacks = false

    var id: String { bundleID }
}

struct Settings: Codable, Equatable {
    var outerGap = 8.0
    var innerGap = 8.0
    var newWindowWidth = NewWindowWidth.half
    var animations = true
    /// Fingers for the strip swipe: 3, 4, or 0 for off.
    var swipeFingers = 3
    var optionScroll = true
    var style = ShortcutStyle.arrows
    /// Recorded bindings, keyed by `Action.rawValue`, that replace the style's defaults.
    var overrides: [String: KeyCombo] = [:]
    var focusBorder = true
    var borderWidth = 2.0
    var widthOverlay = true
    var restoreSession = true
    var minimap = true
    /// Live window pictures in the overview. Needs the Screen Recording permission.
    var overviewThumbnails = false
    var rules: [AppRule] = []

    func rule(for bundleID: String?) -> AppRule? {
        guard let bundleID else { return nil }
        return rules.first { $0.bundleID == bundleID }
    }

    init() {}

    // Decoded key by key so settings saved by an older build keep working when fields are added.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func read<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? c.decodeIfPresent(T.self, forKey: key)) ?? fallback
        }
        let d = Settings()
        outerGap = read(.outerGap, d.outerGap)
        innerGap = read(.innerGap, d.innerGap)
        newWindowWidth = read(.newWindowWidth, d.newWindowWidth)
        animations = read(.animations, d.animations)
        swipeFingers = read(.swipeFingers, d.swipeFingers)
        optionScroll = read(.optionScroll, d.optionScroll)
        style = read(.style, d.style)
        overrides = read(.overrides, d.overrides)
        focusBorder = read(.focusBorder, d.focusBorder)
        borderWidth = read(.borderWidth, d.borderWidth)
        widthOverlay = read(.widthOverlay, d.widthOverlay)
        restoreSession = read(.restoreSession, d.restoreSession)
        minimap = read(.minimap, d.minimap)
        overviewThumbnails = read(.overviewThumbnails, d.overviewThumbnails)
        rules = read(.rules, d.rules)
    }

    func combo(for action: Action) -> KeyCombo? {
        overrides[action.rawValue] ?? Settings.defaultCombo(for: action, style: style)
    }

    var bindings: [Action: KeyCombo] {
        Dictionary(uniqueKeysWithValues: Action.allCases.compactMap { a in combo(for: a).map { (a, $0) } })
    }

    /// Actions whose chord is also bound to another action.
    var conflicts: Set<Action> {
        var seen: [String: [Action]] = [:]
        for (action, combo) in bindings { seen["\(combo.keyCode):\(combo.mods)", default: []].append(action) }
        return Set(seen.values.filter { $0.count > 1 }.flatMap { $0 })
    }

    static func defaultCombo(for action: Action, style: ShortcutStyle) -> KeyCombo? {
        let base = style.modifiers
        let shifted = base | UInt32(shiftKey)
        let layout = UInt32(cmdKey | controlKey)
        let vim = style == .vim
        let left = vim ? (kVK_ANSI_H, "H") : (kVK_LeftArrow, "←")
        let right = vim ? (kVK_ANSI_L, "L") : (kVK_RightArrow, "→")
        let up = vim ? (kVK_ANSI_K, "K") : (kVK_UpArrow, "↑")
        let down = vim ? (kVK_ANSI_J, "J") : (kVK_DownArrow, "↓")
        let digits = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]
        func combo(_ key: (Int, String), _ mods: UInt32) -> KeyCombo {
            KeyCombo(keyCode: UInt32(key.0), mods: mods, label: key.1)
        }
        switch action {
        case .focusLeft: return combo(left, base)
        case .focusRight: return combo(right, base)
        case .focusUp: return combo(up, base)
        case .focusDown: return combo(down, base)
        case .moveLeft: return combo(left, shifted)
        case .moveRight: return combo(right, shifted)
        case .moveUp: return combo(up, shifted)
        case .moveDown: return combo(down, shifted)
        case .cycleWidth: return combo((kVK_ANSI_R, "R"), base)
        case .fullWidth: return combo((kVK_ANSI_F, "F"), base)
        case .matchWidths: return combo((kVK_ANSI_B, "B"), base)
        case .stack: return combo((kVK_ANSI_S, "S"), base)
        case .unstack: return combo((kVK_ANSI_S, "S"), shifted)
        case .toggleTabs: return combo((kVK_ANSI_T, "T"), base)
        case .evenStack: return combo((kVK_ANSI_0, "0"), base)
        case .toggleFloat: return combo((kVK_Space, "Space"), base)
        case .nextDisplay: return combo((kVK_ANSI_N, "N"), base)
        case .focusFirst: return combo((kVK_ANSI_LeftBracket, "["), base)
        case .focusLast: return combo((kVK_ANSI_RightBracket, "]"), base)
        case .center: return combo((kVK_ANSI_C, "C"), base)
        case .layout2: return combo((kVK_ANSI_2, "2"), layout)
        case .layout3: return combo((kVK_ANSI_3, "3"), layout)
        case .layout4: return combo((kVK_ANSI_4, "4"), layout)
        case .layout5: return combo((kVK_ANSI_5, "5"), layout)
        case .layout6: return combo((kVK_ANSI_6, "6"), layout)
        case .layout2plus1: return combo((kVK_LeftArrow, "←"), layout)
        case .layout1plus2: return combo((kVK_RightArrow, "→"), layout)
        case .chain: return combo((kVK_ANSI_Backslash, "\\"), layout)
        case .overview: return combo((kVK_ANSI_O, "O"), base)
        case .setMark: return combo((kVK_ANSI_M, "M"), base)
        case .jumpToMark: return combo((kVK_ANSI_Quote, "'"), base)
        case .peekLeft: return combo((kVK_ANSI_Comma, ","), base)
        case .peekRight: return combo((kVK_ANSI_Period, "."), base)
        default:
            guard let i = action.columnIndex else { return nil }
            return combo((digits[i], "\(i + 1)"), base)
        }
    }
}

final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()
    private static let key = "settings"

    var onChange: (() -> Void)?

    @Published var value: Settings {
        didSet {
            guard value != oldValue else { return }
            if let data = try? JSONEncoder().encode(value) { UserDefaults.standard.set(data, forKey: Self.key) }
            onChange?()
        }
    }

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode(Settings.self, from: data) {
            value = saved
        } else {
            value = Settings()
        }
    }
}
