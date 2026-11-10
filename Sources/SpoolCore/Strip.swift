import Foundation

public typealias WindowID = UInt32

/// A column's width: a share of the screen, or a fixed size the user dragged it to.
public enum ColumnWidth: Equatable, Codable {
    case fraction(Double)
    case points(Double)
}

/// One slot on the strip. Usually a single window; a stack or a tab group when it holds more.
public struct Column: Equatable, Codable {
    public var windows: [WindowID]
    /// Relative heights of the stacked windows. Always the same count as `windows`.
    public var weights: [Double]
    public var width: ColumnWidth
    public var tabbed = false
    /// Focused row, which is also the visible tab when `tabbed`.
    public var active = 0

    public init(_ id: WindowID, width: ColumnWidth) {
        windows = [id]
        weights = [1]
        self.width = width
    }

    public mutating func append(_ id: WindowID) {
        let mean = weights.reduce(0, +) / Double(max(weights.count, 1))
        windows.append(id)
        weights.append(mean > 0 ? mean : 1)
    }

    mutating func remove(at row: Int) {
        windows.remove(at: row)
        weights.remove(at: row)
        if row < active { active -= 1 }
        active = max(0, min(active, windows.count - 1))
    }
}

/// The row of columns for one display (and one Space).
public struct Strip: Equatable, Codable {
    public var columns: [Column] = []
    public var focused = 0
    /// How far the strip is scrolled, in points from its left end.
    public var offset: Double = 0
    /// Set by `center`, so the next visibility check does not pull the strip back into range.
    public var overscroll = false

    public init() {}

    public var isEmpty: Bool { columns.isEmpty }
    public var allWindows: [WindowID] { columns.flatMap(\.windows) }

    public var focusedWindow: WindowID? {
        guard columns.indices.contains(focused) else { return nil }
        let column = columns[focused]
        return column.windows[column.active]
    }

    public func locate(_ id: WindowID) -> (column: Int, row: Int)? {
        for (c, column) in columns.enumerated() {
            if let r = column.windows.firstIndex(of: id) { return (c, r) }
        }
        return nil
    }

    // MARK: Membership

    /// Adds a window as its own column. With no index it opens beside the focused column.
    public mutating func insert(_ id: WindowID, width: ColumnWidth, at index: Int? = nil) {
        insertColumn(Column(id, width: width), at: index ?? (columns.isEmpty ? 0 : focused + 1))
    }

    public mutating func insertColumn(_ column: Column, at index: Int) {
        let i = max(0, min(index, columns.count))
        columns.insert(column, at: i)
        focused = i
    }

    /// Removes a window and closes the gap. Returns a single column carrying its old width.
    @discardableResult
    public mutating func remove(_ id: WindowID) -> Column? {
        guard let (c, r) = locate(id) else { return nil }
        let width = columns[c].width
        columns[c].remove(at: r)
        if columns[c].windows.isEmpty {
            columns.remove(at: c)
            if c < focused { focused -= 1 }
        }
        focused = max(0, min(focused, columns.count - 1))
        return Column(id, width: width)
    }

    /// Adds a window to the bottom of the focused column, or as the first column of an empty strip.
    public mutating func addToFocusedColumn(_ id: WindowID, width: ColumnWidth) {
        guard columns.indices.contains(focused) else {
            insert(id, width: width)
            return
        }
        columns[focused].append(id)
        columns[focused].active = columns[focused].windows.count - 1
    }

    /// Puts `new` exactly where `old` was: same column, row, width and height.
    @discardableResult
    public mutating func replace(_ old: WindowID, with new: WindowID) -> Bool {
        guard let (c, r) = locate(old), locate(new) == nil else { return false }
        columns[c].windows[r] = new
        return true
    }

    // MARK: Focus

    @discardableResult
    public mutating func focus(_ id: WindowID) -> Bool {
        guard let (c, r) = locate(id) else { return false }
        focused = c
        columns[c].active = r
        return true
    }

    public mutating func focusColumn(_ index: Int) {
        guard !columns.isEmpty else { return }
        focused = max(0, min(index, columns.count - 1))
    }

    public mutating func moveFocus(by delta: Int) { focusColumn(focused + delta) }

    public mutating func focusRow(by delta: Int) {
        guard columns.indices.contains(focused) else { return }
        let count = columns[focused].windows.count
        columns[focused].active = max(0, min(columns[focused].active + delta, count - 1))
    }

    // MARK: Moving

    public mutating func swapColumn(by delta: Int) {
        let other = focused + delta
        guard columns.indices.contains(focused), columns.indices.contains(other) else { return }
        columns.swapAt(focused, other)
        focused = other
    }

    public mutating func swapRow(by delta: Int) {
        guard columns.indices.contains(focused) else { return }
        let row = columns[focused].active
        let other = row + delta
        guard columns[focused].windows.indices.contains(other) else { return }
        columns[focused].windows.swapAt(row, other)
        columns[focused].weights.swapAt(row, other)
        columns[focused].active = other
    }

    // MARK: Widths and heights

    /// Steps to the next preset wider than the current width, wrapping to the first.
    public mutating func cycleWidth(_ presets: [Double]) {
        guard columns.indices.contains(focused), let first = presets.first else { return }
        var next = first
        if case .fraction(let current) = columns[focused].width {
            next = presets.first { $0 > current + 0.001 } ?? first
        }
        columns[focused].width = .fraction(next)
    }

    public mutating func setFocusedWidth(_ width: ColumnWidth) {
        guard columns.indices.contains(focused) else { return }
        columns[focused].width = width
    }

    public mutating func setWidth(of id: WindowID, _ width: ColumnWidth) {
        guard let (c, _) = locate(id) else { return }
        columns[c].width = width
    }

    /// Gives one stacked window `fraction` of the column height; the rest keep their proportions.
    public mutating func setHeight(of id: WindowID, fraction: Double) {
        guard let (c, r) = locate(id), columns[c].windows.count > 1 else { return }
        let share = max(0.1, min(fraction, 0.9))
        let others = columns[c].weights.enumerated().filter { $0.offset != r }.map(\.element).reduce(0, +)
        guard others > 0 else { return }
        for i in columns[c].weights.indices where i != r {
            columns[c].weights[i] = columns[c].weights[i] / others * (1 - share)
        }
        columns[c].weights[r] = share
    }

    public mutating func matchWidthsToFocused() {
        guard columns.indices.contains(focused) else { return }
        let width = columns[focused].width
        for i in columns.indices { columns[i].width = width }
    }

    public mutating func evenFocusedStack() {
        guard columns.indices.contains(focused) else { return }
        columns[focused].weights = columns[focused].weights.map { _ in 1 }
    }

    // MARK: Stacks and tabs

    /// Moves the focused window to the bottom of the column on its left.
    @discardableResult
    public mutating func stackLeft() -> Bool {
        guard focused > 0, let id = focusedWindow else { return false }
        let target = focused - 1
        let row = columns[focused].active
        columns[focused].remove(at: row)
        if columns[focused].windows.isEmpty { columns.remove(at: focused) }
        columns[target].append(id)
        columns[target].active = columns[target].windows.count - 1
        focused = target
        return true
    }

    /// Pulls the focused window out of its stack into a new column on the right.
    @discardableResult
    public mutating func unstack() -> Bool {
        guard columns.indices.contains(focused), columns[focused].windows.count > 1,
              let id = focusedWindow else { return false }
        let width = columns[focused].width
        columns[focused].remove(at: columns[focused].active)
        if columns[focused].windows.count == 1 { columns[focused].tabbed = false }
        columns.insert(Column(id, width: width), at: focused + 1)
        focused += 1
        return true
    }

    public mutating func toggleTabs() {
        guard columns.indices.contains(focused), columns[focused].windows.count > 1 else { return }
        columns[focused].tabbed.toggle()
    }

    /// Puts every window back in its own column, one after another.
    public mutating func chain() {
        let target = focusedWindow
        columns = columns.flatMap { column in column.windows.map { Column($0, width: column.width) } }
        if let target { focus(target) }
    }

    /// Arranges windows into a screen-filling picture, for example `[2, 1]` for two stacked
    /// windows beside one full-height window. Starts at the focused window, or earlier when
    /// too few windows follow it. Returns the index of the picture's first column.
    @discardableResult
    public mutating func applyPattern(_ pattern: [Int]) -> Int? {
        let flat = columns.flatMap { column in column.windows.map { ($0, column.width) } }
        guard let target = focusedWindow,
              let at = flat.firstIndex(where: { $0.0 == target }) else { return nil }
        let wanted = min(pattern.reduce(0, +), flat.count)
        let start = min(at, flat.count - wanted)

        var groups: [[WindowID]] = []
        var next = start
        for size in pattern {
            let take = min(size, start + wanted - next)
            if take <= 0 { break }
            groups.append(flat[next..<next + take].map(\.0))
            next += take
        }

        var rebuilt = flat[..<start].map { Column($0.0, width: $0.1) }
        for group in groups {
            var column = Column(group[0], width: .fraction(1 / Double(groups.count)))
            group.dropFirst().forEach { column.append($0) }
            rebuilt.append(column)
        }
        rebuilt += flat[next...].map { Column($0.0, width: $0.1) }
        columns = rebuilt
        focus(target)
        return start
    }
}
