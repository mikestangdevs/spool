import Foundation

/// A request from the command line or a `spool://` URL, such as `focus east` or `width 0.5`.
public enum Command: Equatable {
    /// The raw value of one of the app's actions.
    case action(String)
    /// Set the focused column to this share of the screen.
    case width(Double)
    /// Remember the current strip under a name, or rebuild a remembered one.
    case saveStrip(String)
    case loadStrip(String)
    /// Tag the focused window with a letter or digit, or go back to the window carrying it.
    case mark(String)
    case jumpToMark(String)

    public static let usage = """
        focus  east | west | north | south | first | last
        move   east | west | north | south
        width  cycle | full | match | <ratio such as 0.5 or 1/3>
        jump   <1-9> | first | last
        layout 2 | 3 | 2+1 | 1+2 | 4 | 5 | 6 | chain
        display next
        save   <name>        remember the current strip
        load   <name>        rebuild a remembered strip
        mark   <letter>      tag the focused window
        goto   <letter>      jump to a tagged window
        stack | unstack | tabs | even | float | center | chain | overview
        """

    private static let directions = [
        "east": "Right", "right": "Right", "west": "Left", "left": "Left",
        "north": "Up", "up": "Up", "south": "Down", "down": "Down",
    ]

    private static let layouts = [
        "2": "layout2", "3": "layout3", "4": "layout4", "5": "layout5", "6": "layout6",
        "2+1": "layout2plus1", "1+2": "layout1plus2", "chain": "chain",
    ]

    private static let bare = [
        "stack": "stack", "unstack": "unstack", "tabs": "toggleTabs", "even": "evenStack",
        "float": "toggleFloat", "center": "center", "centre": "center", "chain": "chain",
        "overview": "overview",
    ]

    /// Reads a verb and its optional argument. Returns nil for anything it does not recognise.
    public static func parse(_ words: [String]) -> Command? {
        guard let verb = words.first?.lowercased(), words.count <= 2 else { return nil }
        let arg = words.count == 2 ? words[1].lowercased() : nil

        if let name = bare[verb] { return arg == nil ? .action(name) : nil }
        if verb == "display" { return arg == nil || arg == "next" ? .action("nextDisplay") : nil }
        guard let arg else { return nil }
        let name = words[1].trimmingCharacters(in: .whitespaces)   // names keep their capitals

        switch verb {
        case "save":
            return name.isEmpty ? nil : .saveStrip(name)
        case "load":
            return name.isEmpty ? nil : .loadStrip(name)
        case "mark", "goto":
            guard arg.count == 1, arg.first!.isLetter || arg.first!.isNumber else { return nil }
            return verb == "mark" ? .mark(arg) : .jumpToMark(arg)
        case "focus":
            if arg == "first" { return .action("focusFirst") }
            if arg == "last" { return .action("focusLast") }
            return directions[arg].map { .action("focus" + $0) }
        case "move":
            return directions[arg].map { .action("move" + $0) }
        case "jump":
            if arg == "first" { return .action("focusFirst") }
            if arg == "last" { return .action("focusLast") }
            guard let n = Int(arg), (1...9).contains(n) else { return nil }
            return .action("column\(n)")
        case "layout":
            return layouts[arg].map { .action($0) }
        case "width":
            switch arg {
            case "cycle": return .action("cycleWidth")
            case "full": return .action("fullWidth")
            case "match": return .action("matchWidths")
            default:
                guard let ratio = ratio(arg), ratio >= 0.1, ratio <= 1 else { return nil }
                return .width(ratio)
            }
        default:
            return nil
        }
    }

    /// Reads `spool://focus?direction=east`. The name of the query item does not matter.
    public static func parse(_ url: URL) -> Command? {
        guard url.scheme?.lowercased() == "spool", let verb = url.host else { return nil }
        let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value
        return parse([verb] + (value.map { [$0] } ?? []))
    }

    /// The URL that carries these words to the app.
    public static func url(for words: [String]) -> URL? {
        guard parse(words) != nil else { return nil }
        var components = URLComponents()
        components.scheme = "spool"
        components.host = words[0].lowercased()
        if words.count == 2 { components.queryItems = [URLQueryItem(name: "arg", value: words[1])] }
        return components.url
    }

    private static func ratio(_ text: String) -> Double? {
        let parts = text.split(separator: "/")
        if parts.count == 2, let a = Double(parts[0]), let b = Double(parts[1]), b != 0 { return a / b }
        return Double(text)
    }
}

/// How a column width reads to a person: "1/3", "Full", or a percentage.
public func widthLabel(_ fraction: Double) -> String {
    let named: [(Double, String)] = [(0.25, "1/4"), (1.0 / 3, "1/3"), (0.5, "1/2"), (2.0 / 3, "2/3"), (0.75, "3/4"), (1, "Full")]
    if let match = named.first(where: { abs($0.0 - fraction) < 0.005 }) { return match.1 }
    return "\(Int((fraction * 100).rounded()))%"
}
