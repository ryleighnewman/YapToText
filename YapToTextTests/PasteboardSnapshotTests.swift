import XCTest
import AppKit
@testable import YapToText

/// The 1.5.3 Intelligent Insert crash: the same snapshot was restored twice (the read's own
/// restore, then settleUnansweredRead after a slow app's late copy), and writing the same
/// NSPasteboardItem a second time raises. These run on a private pasteboard, never the
/// user's clipboard.
@MainActor
final class PasteboardSnapshotTests: XCTestCase {
    private var pb: NSPasteboard!

    override func setUp() {
        super.setUp()
        pb = NSPasteboard(name: NSPasteboard.Name("yaptotext-tests-\(UUID().uuidString)"))
    }

    override func tearDown() {
        pb.releaseGlobally()
        pb = nil
        super.tearDown()
    }

    func testSnapshotCanBeRestoredTwice() {
        pb.clearContents()
        pb.setString("the user's clipboard", forType: .string)
        let snapshot = PasteboardSnapshot.capture(pb)

        pb.clearContents()
        pb.setString("selection copied by the read", forType: .string)
        snapshot.write(to: pb)
        XCTAssertEqual(pb.string(forType: .string), "the user's clipboard")

        // The late copy lands and overwrites the clipboard; the same snapshot goes back again.
        pb.clearContents()
        pb.setString("late copy", forType: .string)
        snapshot.write(to: pb)
        XCTAssertEqual(pb.string(forType: .string), "the user's clipboard")
    }

    func testEveryItemAndTypeSurvives() {
        let first = NSPasteboardItem()
        first.setString("plain", forType: .string)
        first.setData(Data("{\\rtf1 rich}".utf8), forType: .rtf)
        let second = NSPasteboardItem()
        second.setString("second item", forType: .string)
        pb.clearContents()
        pb.writeObjects([first, second])

        let snapshot = PasteboardSnapshot.capture(pb)
        XCTAssertEqual(snapshot.string, "plain")
        pb.clearContents()
        snapshot.write(to: pb)
        snapshot.write(to: pb)

        let items = pb.pasteboardItems ?? []
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items.first?.string(forType: .string), "plain")
        XCTAssertNotNil(items.first?.data(forType: .rtf))
        XCTAssertEqual(items.last?.string(forType: .string), "second item")
    }

    func testEmptyClipboardStaysEmpty() {
        pb.clearContents()
        let snapshot = PasteboardSnapshot.capture(pb)
        XCTAssertTrue(snapshot.isEmpty)
        pb.setString("something", forType: .string)
        snapshot.write(to: pb)
        XCTAssertNil(pb.string(forType: .string))
    }
}
