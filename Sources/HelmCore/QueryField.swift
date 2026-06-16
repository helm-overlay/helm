import Foundation

/// The editable text buffer behind the overlay's filter/search line.
///
/// The launchers are non-activating `NSPanel`s that can't host a first-responder
/// `NSTextField`, so the views can't lean on AppKit's text editing. This is the small
/// text-editing model they share instead: a real insertion caret with left/right and
/// word movement, select-all, and arbitrary insertion (so paste and punctuation work).
/// Pure value logic, kept in `HelmCore` so it's unit-tested rather than driven through UI.
public struct QueryField: Equatable {
    public private(set) var text: String = ""
    /// Caret offset in characters, `0...text.count`. Insertions and deletions act here.
    public private(set) var cursor: Int = 0
    /// Whole-buffer selection (⌘A). The next insert, paste, or delete replaces everything.
    public private(set) var selectedAll: Bool = false

    public init() {}

    public var isEmpty: Bool { text.isEmpty }

    private var chars: [Character] { Array(text) }
    private func index(at offset: Int) -> String.Index {
        text.index(text.startIndex, offsetBy: offset)
    }

    /// Text on each side of the caret, so the view can draw the caret between them.
    public var beforeCursor: String { String(chars[..<cursor]) }
    public var afterCursor: String { String(chars[cursor...]) }

    // MARK: Editing

    /// Insert a run of text at the caret (a typed character or a pasted string). A
    /// select-all replaces the whole buffer first.
    public mutating func insert(_ s: String) {
        if selectedAll { clear() }
        text.insert(contentsOf: s, at: index(at: cursor))
        cursor += s.count
    }

    /// Delete the character before the caret, or the whole buffer if it's selected.
    public mutating func backspace() {
        if selectedAll { clear(); return }
        guard cursor > 0 else { return }
        text.remove(at: index(at: cursor - 1))
        cursor -= 1
    }

    /// Delete from the caret back to the start of the preceding word (⌥⌫).
    public mutating func deleteWordBack() {
        if selectedAll { clear(); return }
        let target = wordBoundary(before: cursor)
        guard target < cursor else { return }
        text.removeSubrange(index(at: target)..<index(at: cursor))
        cursor = target
    }

    public mutating func clear() {
        text = ""
        cursor = 0
        selectedAll = false
    }

    public mutating func selectAll() { selectedAll = !text.isEmpty }
    public mutating func deselect() { selectedAll = false }

    // MARK: Caret movement

    /// Move the caret one character. From a select-all, collapse to the matching edge.
    public mutating func moveCursor(by delta: Int) {
        if selectedAll {
            selectedAll = false
            cursor = delta < 0 ? 0 : text.count
            return
        }
        cursor = max(0, min(text.count, cursor + delta))
    }

    /// Move the caret one word left or right (⌥←/⌥→).
    public mutating func moveWord(by delta: Int) {
        selectedAll = false
        cursor = delta < 0 ? wordBoundary(before: cursor) : wordBoundary(after: cursor)
    }

    public mutating func moveToStart() { selectedAll = false; cursor = 0 }
    public mutating func moveToEnd() { selectedAll = false; cursor = text.count }

    /// Offset of the word start at or before `from`: skip spaces, then non-spaces.
    private func wordBoundary(before from: Int) -> Int {
        let c = chars
        var i = from
        while i > 0, c[i - 1] == " " { i -= 1 }
        while i > 0, c[i - 1] != " " { i -= 1 }
        return i
    }

    /// Offset of the word end at or after `from`: skip spaces, then non-spaces.
    private func wordBoundary(after from: Int) -> Int {
        let c = chars
        var i = from
        while i < c.count, c[i] == " " { i += 1 }
        while i < c.count, c[i] != " " { i += 1 }
        return i
    }
}
