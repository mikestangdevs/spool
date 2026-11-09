import CoreGraphics
import Foundation

public struct Metrics {
    /// Width available to columns, after the outer gaps.
    public var usable: Double
    /// Gap between neighbouring columns and between stacked windows.
    public var gap: Double
    /// Widths that apps refused to go below, measured after a resize.
    public var minWidths: [WindowID: Double]

    public init(usable: Double, gap: Double, minWidths: [WindowID: Double] = [:]) {
        self.usable = usable
        self.gap = gap
        self.minWidths = minWidths
    }
}

public let minimumColumnWidth: Double = 120

extension ColumnWidth {
    /// Fractions are sized so that, say, two halves and the gap between them fill the screen exactly.
    func resolve(_ m: Metrics) -> Double {
        switch self {
        case .fraction(let f): return max(minimumColumnWidth, (m.usable + m.gap) * f - m.gap)
        case .points(let p): return min(max(p, minimumColumnWidth), m.usable)
        }
    }
}

public extension Strip {
    func widths(_ m: Metrics) -> [Double] {
        columns.map { column in
            max(column.width.resolve(m), column.windows.compactMap { m.minWidths[$0] }.max() ?? 0)
        }
    }

    /// Left edge of each column, measured from the strip's left end.
    func origins(_ m: Metrics) -> [Double] {
        var x = 0.0
        return widths(m).map { width in
            defer { x += width + m.gap }
            return x
        }
    }

    func totalWidth(_ m: Metrics) -> Double {
        let w = widths(m)
        return w.reduce(0, +) + m.gap * Double(max(w.count - 1, 0))
    }

    func maxOffset(_ m: Metrics) -> Double { max(0, totalWidth(m) - m.usable) }

    /// Scrolls the least distance that brings the focused column fully on screen.
    mutating func ensureVisible(_ m: Metrics) {
        guard columns.indices.contains(focused) else {
            offset = 0
            return
        }
        let width = widths(m)[focused]
        let low = origins(m)[focused]
        let high = low + width
        let visible = low >= offset - 0.5 && high <= offset + m.usable + 0.5
        if overscroll && visible { return }
        overscroll = false
        if width >= m.usable || low < offset {
            offset = low
        } else if high > offset + m.usable {
            offset = high - m.usable
        }
        offset = min(max(offset, 0), maxOffset(m))
    }

    /// Puts the focused column in the middle of the screen, even at the ends of the strip.
    mutating func center(_ m: Metrics) {
        guard columns.indices.contains(focused) else { return }
        offset = origins(m)[focused] + widths(m)[focused] / 2 - m.usable / 2
        overscroll = true
    }

    mutating func alignLeft(_ column: Int, _ m: Metrics) {
        guard columns.indices.contains(column) else { return }
        offset = min(max(origins(m)[column], 0), maxOffset(m))
        overscroll = false
    }

    /// The column a free scroll has landed on: the one most in view, then the one nearest the middle.
    func settleColumn(_ m: Metrics) -> Int? {
        guard !columns.isEmpty else { return nil }
        let w = widths(m), o = origins(m)
        let middle = offset + m.usable / 2
        var best = 0
        var bestScore = (-1.0, -Double.infinity)
        for i in columns.indices {
            let overlap = max(0, min(o[i] + w[i], offset + m.usable) - max(o[i], offset))
            let score = (overlap / min(w[i], m.usable), -abs(o[i] + w[i] / 2 - middle))
            if score.0 > bestScore.0 + 0.001 || (abs(score.0 - bestScore.0) <= 0.001 && score.1 > bestScore.1) {
                best = i
                bestScore = score
            }
        }
        return best
    }

    /// Where every window belongs, in the same coordinates as `area`. Frames may lie off screen.
    func frames(in area: CGRect, outer: Double, _ m: Metrics) -> [WindowID: CGRect] {
        var result: [WindowID: CGRect] = [:]
        let w = widths(m), o = origins(m)
        let top = Double(area.minY) + outer
        let height = Double(area.height) - 2 * outer
        for (i, column) in columns.enumerated() {
            let x = Double(area.minX) + outer + o[i] - offset
            if column.tabbed || column.windows.count == 1 {
                for id in column.windows {
                    result[id] = CGRect(x: x, y: top, width: w[i], height: height)
                }
                continue
            }
            let total = column.weights.reduce(0, +)
            let free = height - m.gap * Double(column.windows.count - 1)
            var y = top
            for (row, id) in column.windows.enumerated() {
                let h = free * column.weights[row] / total
                result[id] = CGRect(x: x, y: y, width: w[i], height: h)
                y += h + m.gap
            }
        }
        return result
    }
}

/// macOS will not keep a window entirely off screen, so one that has scrolled out of view
/// waits at the nearest edge with `sliver` points showing. If that would put most of it on
/// another display, it is `relocated` to an edge with nothing beyond it.
public func park(_ frame: CGRect, in screen: CGRect, avoiding others: [CGRect] = [],
                 sliver: CGFloat = 1) -> (frame: CGRect, relocated: Bool) {
    func area(_ r: CGRect) -> CGFloat { r.isNull ? 0 : r.width * r.height }
    func spill(_ r: CGRect) -> CGFloat { others.reduce(0) { $0 + area(r.intersection($1)) } }

    var natural = frame
    if frame.maxX < screen.minX + sliver {
        natural.origin.x = screen.minX + sliver - frame.width
    } else if frame.minX > screen.maxX - sliver {
        natural.origin.x = screen.maxX - sliver
    }
    let leaked = spill(natural)
    if leaked == 0 || area(natural.intersection(screen)) > leaked { return (natural, false) }

    var left = frame, right = frame, below = frame, above = frame
    left.origin.x = screen.minX + sliver - frame.width
    right.origin.x = screen.maxX - sliver
    below.origin.x = min(max(frame.minX, screen.minX), max(screen.minX, screen.maxX - frame.width))
    below.origin.y = screen.maxY - sliver
    above.origin.x = below.origin.x
    above.origin.y = screen.minY + sliver - frame.height
    let sides = frame.midX < screen.midX ? [left, right] : [right, left]
    var best = sides[0]
    for candidate in sides + [below, above] where spill(candidate) < spill(best) { best = candidate }
    return (best, true)
}
