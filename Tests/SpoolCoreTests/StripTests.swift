import CoreGraphics
import XCTest
@testable import SpoolCore

final class StripTests: XCTestCase {
    let m = Metrics(usable: 1000, gap: 10)

    func strip(_ ids: [WindowID], width: Double = 0.5) -> Strip {
        var s = Strip()
        for id in ids { s.insert(id, width: .fraction(width), at: s.columns.count) }
        return s
    }

    func testNewWindowOpensBesideFocused() {
        var s = strip([1, 2, 3])
        s.focus(1)
        s.insert(9, width: .fraction(0.5))
        XCTAssertEqual(s.allWindows, [1, 9, 2, 3])
        XCTAssertEqual(s.focusedWindow, 9)
    }

    func testRemoveClosesGapAndKeepsFocus() {
        var s = strip([1, 2, 3])
        s.focus(3)
        s.remove(1)
        XCTAssertEqual(s.allWindows, [2, 3])
        XCTAssertEqual(s.focusedWindow, 3)
        s.remove(3)
        XCTAssertEqual(s.focusedWindow, 2)
        s.remove(2)
        XCTAssertNil(s.focusedWindow)
    }

    func testFractionsFillTheScreenExactly() {
        let halves = strip([1, 2])
        XCTAssertEqual(halves.totalWidth(m), 1000, accuracy: 0.001)
        let thirds = strip([1, 2, 3], width: 1.0 / 3)
        XCTAssertEqual(thirds.totalWidth(m), 1000, accuracy: 0.001)
    }

    func testOtherColumnsKeepTheirWidthWhenOneOpens() {
        var s = strip([1, 2])
        let before = s.widths(m)
        s.insert(3, width: .fraction(1))
        XCTAssertEqual(s.widths(m)[0], before[0])
        XCTAssertEqual(s.widths(m)[1], before[1])
        XCTAssertEqual(s.widths(m)[2], 1000)
        XCTAssertGreaterThan(s.totalWidth(m), m.usable)
    }

    func testEnsureVisibleScrollsTheLeastDistance() {
        var s = strip([1, 2, 3, 4])   // four halves: 495 wide at 0, 505, 1010, 1515
        s.focus(3)
        s.ensureVisible(m)
        XCTAssertEqual(s.offset, 505, accuracy: 0.001)   // column 3 ends at 1505
        s.focus(2)
        s.ensureVisible(m)
        XCTAssertEqual(s.offset, 505, accuracy: 0.001)   // already in view, no movement
        s.focus(1)
        s.ensureVisible(m)
        XCTAssertEqual(s.offset, 0, accuracy: 0.001)
    }

    func testOffsetIsPulledBackWhenTheStripShrinks() {
        var s = strip([1, 2, 3, 4])
        s.focus(4)
        s.ensureVisible(m)
        XCTAssertEqual(s.offset, s.maxOffset(m), accuracy: 0.001)
        s.remove(4)
        s.remove(3)
        s.ensureVisible(m)
        XCTAssertEqual(s.offset, 0, accuracy: 0.001)
    }

    func testCenterSurvivesUntilFocusLeavesTheScreen() {
        var s = strip([1, 2, 3, 4])
        s.focus(1)
        s.center(m)
        XCTAssertEqual(s.offset, 495.0 / 2 - 500, accuracy: 0.001)
        s.ensureVisible(m)
        XCTAssertLessThan(s.offset, 0)   // still centred
        s.focus(4)
        s.ensureVisible(m)
        XCTAssertEqual(s.offset, s.maxOffset(m), accuracy: 0.001)
    }

    func testCycleWidth() {
        var s = strip([1], width: 1.0 / 3)
        let presets = [1.0 / 3, 0.5, 2.0 / 3, 1]
        s.cycleWidth(presets)
        XCTAssertEqual(s.columns[0].width, .fraction(0.5))
        s.cycleWidth(presets)
        s.cycleWidth(presets)
        XCTAssertEqual(s.columns[0].width, .fraction(1))
        s.cycleWidth(presets)
        XCTAssertEqual(s.columns[0].width, .fraction(1.0 / 3))
        s.setFocusedWidth(.points(777))
        s.cycleWidth(presets)
        XCTAssertEqual(s.columns[0].width, .fraction(1.0 / 3))
    }

    func testStackAndUnstack() {
        var s = strip([1, 2, 3])
        s.focus(2)
        XCTAssertTrue(s.stackLeft())
        XCTAssertEqual(s.columns.map(\.windows), [[1, 2], [3]])
        XCTAssertEqual(s.focusedWindow, 2)
        XCTAssertTrue(s.unstack())
        XCTAssertEqual(s.columns.map(\.windows), [[1], [2], [3]])
        XCTAssertEqual(s.focusedWindow, 2)
        s.focus(1)
        XCTAssertFalse(s.stackLeft())
        XCTAssertFalse(s.unstack())
    }

    func testStackedFramesShareTheHeight() {
        var s = strip([1, 2])
        s.focus(2)
        s.stackLeft()
        let area = CGRect(x: 0, y: 25, width: 1020, height: 620)
        let frames = s.frames(in: area, outer: 10, m)
        XCTAssertEqual(frames[1], CGRect(x: 10, y: 35, width: 495, height: 295))
        XCTAssertEqual(frames[2], CGRect(x: 10, y: 340, width: 495, height: 295))
        s.setHeight(of: 1, fraction: 0.75)
        let uneven = s.frames(in: area, outer: 10, m)
        XCTAssertEqual(Double(uneven[1]!.height), 590 * 0.75, accuracy: 0.001)
        XCTAssertEqual(Double(uneven[2]!.maxY), 635, accuracy: 0.001)
        s.evenFocusedStack()
        XCTAssertEqual(s.frames(in: area, outer: 10, m)[1], frames[1])
    }

    func testTabsShareOneFrame() {
        var s = strip([1, 2])
        s.focus(2)
        s.stackLeft()
        s.toggleTabs()
        let frames = s.frames(in: CGRect(x: 0, y: 0, width: 1020, height: 620), outer: 10, m)
        XCTAssertEqual(frames[1], frames[2])
    }

    func testSwapMovesFocusWithTheColumn() {
        var s = strip([1, 2, 3])
        s.focus(1)
        s.swapColumn(by: 1)
        XCTAssertEqual(s.allWindows, [2, 1, 3])
        XCTAssertEqual(s.focusedWindow, 1)
        s.swapColumn(by: -5)
        XCTAssertEqual(s.allWindows, [2, 1, 3])
    }

    func testPatternTwoPlusOne() {
        var s = strip([1, 2, 3, 4])
        s.focus(2)
        let first = s.applyPattern([2, 1])
        XCTAssertEqual(first, 1)
        XCTAssertEqual(s.columns.map(\.windows), [[1], [2, 3], [4]])
        XCTAssertEqual(s.columns[1].width, .fraction(0.5))
        XCTAssertEqual(s.focusedWindow, 2)
    }

    func testPatternBacksUpWhenTooFewWindowsFollow() {
        var s = strip([1, 2, 3, 4, 5])
        s.focus(5)
        XCTAssertEqual(s.applyPattern([2, 2]), 1)
        XCTAssertEqual(s.columns.map(\.windows), [[1], [2, 3], [4, 5]])
        XCTAssertEqual(s.focusedWindow, 5)
    }

    func testPatternWithFewerWindowsThanSlots() {
        var s = strip([1, 2, 3])
        s.focus(1)
        s.applyPattern([2, 2, 2])
        XCTAssertEqual(s.columns.map(\.windows), [[1, 2], [3]])
        XCTAssertEqual(s.columns[0].width, .fraction(0.5))
    }

    func testChainFlattensStacks() {
        var s = strip([1, 2, 3])
        s.focus(3)
        s.applyPattern([2, 1])
        s.chain()
        XCTAssertEqual(s.columns.map(\.windows), [[1], [2], [3]])
        XCTAssertEqual(s.focusedWindow, 3)
    }

    func testSettlePicksTheColumnMostInView() {
        var s = strip([1, 2, 3, 4])
        s.offset = 400    // column 1 (505–1000) fully in view, column 2 mostly
        XCTAssertEqual(s.settleColumn(m), 1)
        s.offset = 1100   // only columns 2 and 3 remain, column 3 fully
        XCTAssertEqual(s.settleColumn(m), 3)
    }

    func testMinimumWidthFromAnAppWidensItsColumn() {
        let s = strip([1, 2], width: 1.0 / 3)
        let stubborn = Metrics(usable: 1000, gap: 10, minWidths: [1: 600])
        XCTAssertEqual(s.widths(stubborn)[0], 600)
        XCTAssertEqual(s.origins(stubborn)[1], 610)
    }

    func testParkKeepsASliverOnScreen() {
        let screen = CGRect(x: 0, y: 0, width: 1000, height: 600)
        let left = park(CGRect(x: -900, y: 10, width: 400, height: 500), in: screen)
        XCTAssertEqual(left.frame.maxX, 1)
        XCTAssertFalse(left.relocated)
        let right = park(CGRect(x: 1500, y: 10, width: 400, height: 500), in: screen)
        XCTAssertEqual(right.frame.minX, 999)
        let partly = CGRect(x: -200, y: 10, width: 400, height: 500)
        XCTAssertEqual(park(partly, in: screen).frame, partly)
    }

    // Two displays side by side above a laptop.
    func testParkingAvoidsNeighbouringDisplays() {
        let leftDell = CGRect(x: -1920, y: -1080, width: 1920, height: 1080)
        let rightDell = CGRect(x: 0, y: -1080, width: 1920, height: 1080)
        let laptop = CGRect(x: 0, y: 0, width: 1728, height: 1117)
        func leak(_ r: CGRect, _ screens: [CGRect]) -> CGFloat {
            screens.reduce(0) { $0 + ($1.intersects(r) ? $1.intersection(r).width * $1.intersection(r).height : 0) }
        }

        // Scrolled off the right of the left display: the natural spot is on the right display.
        let gone = CGRect(x: 400, y: -1040, width: 900, height: 1000)
        let hidden = park(gone, in: leftDell, avoiding: [rightDell, laptop])
        XCTAssertTrue(hidden.relocated)
        XCTAssertEqual(leak(hidden.frame, [rightDell, laptop]), 0)
        XCTAssertEqual(hidden.frame.maxX, leftDell.minX + 1)

        // Mirror image on the right display.
        let mirrored = park(CGRect(x: -1500, y: -1040, width: 900, height: 1000), in: rightDell, avoiding: [leftDell, laptop])
        XCTAssertTrue(mirrored.relocated)
        XCTAssertEqual(leak(mirrored.frame, [leftDell, laptop]), 0)

        // Mostly still on its own display: left where it is, for macOS to clip.
        let peeking = CGRect(x: -700, y: -1040, width: 900, height: 1000)
        let kept = park(peeking, in: leftDell, avoiding: [rightDell, laptop])
        XCTAssertFalse(kept.relocated)
        XCTAssertEqual(kept.frame, peeking)

        // Mostly over the neighbour: hidden rather than shown on the wrong display.
        let mostlyOver = park(CGRect(x: -200, y: -1040, width: 900, height: 1000), in: leftDell, avoiding: [rightDell, laptop])
        XCTAssertTrue(mostlyOver.relocated)
        XCTAssertEqual(leak(mostlyOver.frame, [rightDell, laptop]), 0)

        // The laptop has nothing beside it, so nothing changes there.
        let plain = park(CGRect(x: 2500, y: 40, width: 800, height: 1000), in: laptop, avoiding: [leftDell, rightDell])
        XCTAssertFalse(plain.relocated)
        XCTAssertEqual(plain.frame.minX, laptop.maxX - 1)
    }

    func testStripSurvivesEncoding() throws {
        var s = strip([1, 2, 3])
        s.focus(2)
        s.stackLeft()
        s.toggleTabs()
        s.setWidth(of: 3, .points(640))
        s.offset = 120
        let copy = try JSONDecoder().decode(Strip.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(copy, s)
    }

    func testCommands() {
        XCTAssertEqual(Command.parse(["focus", "east"]), .action("focusRight"))
        XCTAssertEqual(Command.parse(["move", "west"]), .action("moveLeft"))
        XCTAssertEqual(Command.parse(["jump", "2"]), .action("column2"))
        XCTAssertEqual(Command.parse(["float"]), .action("toggleFloat"))
        XCTAssertEqual(Command.parse(["layout", "2+1"]), .action("layout2plus1"))
        XCTAssertEqual(Command.parse(["width", "0.5"]), .width(0.5))
        XCTAssertEqual(Command.parse(["width", "1/3"]), .width(1.0 / 3))
        XCTAssertEqual(Command.parse(["width", "cycle"]), .action("cycleWidth"))
        XCTAssertEqual(Command.parse(["display"]), .action("nextDisplay"))
        XCTAssertNil(Command.parse(["width", "7"]))
        XCTAssertNil(Command.parse(["jump", "12"]))
        XCTAssertNil(Command.parse(["focus"]))
        XCTAssertNil(Command.parse(["float", "now"]))
        XCTAssertNil(Command.parse(["launch", "missiles"]))
    }

    func testCommandURLsRoundTrip() {
        XCTAssertEqual(Command.parse(URL(string: "spool://focus?direction=east")!), .action("focusRight"))
        XCTAssertEqual(Command.parse(URL(string: "spool://width?ratio=0.5")!), .width(0.5))
        XCTAssertEqual(Command.parse(URL(string: "spool://float")!), .action("toggleFloat"))
        XCTAssertNil(Command.parse(URL(string: "https://focus?direction=east")!))
        for words in [["focus", "east"], ["layout", "2+1"], ["width", "1/3"], ["stack"]] {
            XCTAssertEqual(Command.url(for: words).flatMap(Command.parse), Command.parse(words), "\(words)")
        }
        XCTAssertNil(Command.url(for: ["nonsense"]))
    }

    func testWidthLabels() {
        XCTAssertEqual(widthLabel(1.0 / 3), "1/3")
        XCTAssertEqual(widthLabel(0.5), "1/2")
        XCTAssertEqual(widthLabel(1), "Full")
        XCTAssertEqual(widthLabel(0.4), "40%")
    }

    func testRuleStacksUnderFocused() {
        var s = strip([1, 2, 3])
        s.focus(2)
        s.addToFocusedColumn(9, width: .fraction(0.5))
        XCTAssertEqual(s.columns.map(\.windows), [[1], [2, 9], [3]])
        XCTAssertEqual(s.focusedWindow, 9)
        var empty = Strip()
        empty.addToFocusedColumn(4, width: .fraction(0.5))
        XCTAssertEqual(empty.allWindows, [4])
    }

    func testNamedStripAndMarkCommands() {
        XCTAssertEqual(Command.parse(["save", "Coding"]), .saveStrip("Coding"))
        XCTAssertEqual(Command.parse(["load", "Coding"]), .loadStrip("Coding"))
        XCTAssertEqual(Command.parse(["mark", "A"]), .mark("a"))
        XCTAssertEqual(Command.parse(["goto", "a"]), .jumpToMark("a"))
        XCTAssertEqual(Command.parse(["overview"]), .action("overview"))
        XCTAssertNil(Command.parse(["mark", "ab"]))
        XCTAssertNil(Command.parse(["mark", "!"]))
        XCTAssertNil(Command.parse(["save"]))
        XCTAssertEqual(Command.url(for: ["save", "deep work"]).flatMap(Command.parse), .saveStrip("deep work"))
    }
}
