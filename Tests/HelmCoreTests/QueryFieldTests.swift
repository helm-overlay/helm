import XCTest
@testable import HelmCore

final class QueryFieldTests: XCTestCase {
    func testInsertAppendsAndAdvancesCaret() {
        var f = QueryField()
        f.insert("ab")
        f.insert("c")
        XCTAssertEqual(f.text, "abc")
        XCTAssertEqual(f.cursor, 3)
    }

    func testInsertAtCaretInMiddle() {
        var f = QueryField()
        f.insert("ac")
        f.moveCursor(by: -1)
        f.insert("b")
        XCTAssertEqual(f.text, "abc")
        XCTAssertEqual(f.cursor, 2)
        XCTAssertEqual(f.beforeCursor, "ab")
        XCTAssertEqual(f.afterCursor, "c")
    }

    func testInsertAcceptsPunctuation() {
        var f = QueryField()
        f.insert("MOBPC-123/foo.bar@x")
        XCTAssertEqual(f.text, "MOBPC-123/foo.bar@x")
    }

    func testBackspaceDeletesBeforeCaret() {
        var f = QueryField()
        f.insert("abc")
        f.moveCursor(by: -1)
        f.backspace()
        XCTAssertEqual(f.text, "ac")
        XCTAssertEqual(f.cursor, 1)
    }

    func testBackspaceAtStartIsNoOp() {
        var f = QueryField()
        f.insert("ab")
        f.moveToStart()
        f.backspace()
        XCTAssertEqual(f.text, "ab")
        XCTAssertEqual(f.cursor, 0)
    }

    func testCaretMovementClamps() {
        var f = QueryField()
        f.insert("ab")
        f.moveCursor(by: 5)
        XCTAssertEqual(f.cursor, 2)
        f.moveCursor(by: -9)
        XCTAssertEqual(f.cursor, 0)
    }

    func testDeleteWordBack() {
        var f = QueryField()
        f.insert("foo bar baz")
        f.deleteWordBack()
        XCTAssertEqual(f.text, "foo bar ")
        f.deleteWordBack()
        XCTAssertEqual(f.text, "foo ")
    }

    func testDeleteWordBackFromMiddle() {
        var f = QueryField()
        f.insert("foo bar")
        f.moveCursor(by: -2)   // caret before "ar"
        f.deleteWordBack()
        XCTAssertEqual(f.text, "foo ar")
        XCTAssertEqual(f.cursor, 4)
    }

    func testWordMovement() {
        var f = QueryField()
        f.insert("foo bar")
        f.moveWord(by: -1)
        XCTAssertEqual(f.cursor, 4)   // start of "bar"
        f.moveWord(by: -1)
        XCTAssertEqual(f.cursor, 0)   // start of "foo"
        f.moveWord(by: 1)
        XCTAssertEqual(f.cursor, 3)   // end of "foo"
    }

    func testSelectAllThenTypeReplaces() {
        var f = QueryField()
        f.insert("hello")
        f.selectAll()
        XCTAssertTrue(f.selectedAll)
        f.insert("x")
        XCTAssertEqual(f.text, "x")
        XCTAssertEqual(f.cursor, 1)
        XCTAssertFalse(f.selectedAll)
    }

    func testSelectAllThenBackspaceClears() {
        var f = QueryField()
        f.insert("hello")
        f.selectAll()
        f.backspace()
        XCTAssertTrue(f.isEmpty)
        XCTAssertEqual(f.cursor, 0)
    }

    func testSelectAllCollapsesOnArrow() {
        var f = QueryField()
        f.insert("hello")
        f.selectAll()
        f.moveCursor(by: -1)
        XCTAssertFalse(f.selectedAll)
        XCTAssertEqual(f.cursor, 0)
        f.selectAll()
        f.moveCursor(by: 1)
        XCTAssertEqual(f.cursor, 5)
    }

    func testSelectAllEmptyIsNoSelection() {
        var f = QueryField()
        f.selectAll()
        XCTAssertFalse(f.selectedAll)
    }
}
