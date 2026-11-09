import Foundation
import SpoolCore

/// A strip remembered by name: which apps sit in which columns. Windows are matched by
/// app when it is recalled, since the windows themselves will not be the same ones.
struct SavedStrip: Codable {
    struct Column: Codable {
        /// Bundle IDs, top to bottom.
        var apps: [String]
        var weights: [Double]
        var width: ColumnWidth
        var tabbed: Bool
    }

    var name: String
    var columns: [Column]
}

final class SavedStrips {
    static let shared = SavedStrips()

    private var strips: [SavedStrip] = []
    private let file = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Spool", isDirectory: true).appendingPathComponent("strips.json")

    private init() {
        if let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode([SavedStrip].self, from: data) {
            strips = saved
        }
    }

    var names: [String] { strips.map(\.name) }

    /// Names match without regard to case, so `load coding` finds "Coding".
    func strip(named name: String) -> SavedStrip? {
        strips.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    func save(_ strip: SavedStrip) {
        delete(named: strip.name)
        strips.append(strip)
        strips.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        write()
    }

    func delete(named name: String) {
        strips.removeAll { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        write()
    }

    private func write() {
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(strips).write(to: file, options: .atomic)
        } catch {
            NSLog("Spool: could not save the named strips: \(error.localizedDescription)")
        }
    }
}
