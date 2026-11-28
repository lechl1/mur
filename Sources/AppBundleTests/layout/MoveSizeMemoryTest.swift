@testable import AppBundle
import AppKit
import Common
import Testing

/// A window moved back into a column of its own gets back the size it had
/// when the user started moving it; one window is remembered at a time.
@Suite("MoveSizeMemory")
struct MoveSizeMemoryTest {
    private let wide = CGSize(width: 600, height: 1000)
    private let narrow = CGSize(width: 400, height: 500)

    @Test func theFirstMoveRemembersTheRenderedSize() {
        var m = MoveSizeMemory()
        #expect(m.startMove(1, renderedSize: wide) == wide)
    }

    @Test func laterMovesOfTheSameWindowKeepTheFirstSize() {
        var m = MoveSizeMemory()
        _ = m.startMove(1, renderedSize: wide)
        // It joined a narrower column as a row; moving it out again restores 600pt.
        #expect(m.startMove(1, renderedSize: narrow) == wide)
        #expect(m.startMove(1, renderedSize: narrow) == wide)
    }

    @Test func anotherWindowsMoveReplacesIt() {
        var m = MoveSizeMemory()
        _ = m.startMove(1, renderedSize: wide)
        #expect(m.startMove(2, renderedSize: narrow) == narrow)
        // The first window is a new run of moves now: its current size.
        #expect(m.startMove(1, renderedSize: narrow) == narrow)
    }

    @Test func aWindowWithoutACellRemembersOnceItHasOne() {
        var m = MoveSizeMemory()
        #expect(m.startMove(1, renderedSize: nil) == nil)
        #expect(m.startMove(1, renderedSize: wide) == wide)
        #expect(m.startMove(1, renderedSize: nil) == wide)
    }

    @Test func aResizeForgetsIt() {
        var m = MoveSizeMemory()
        _ = m.startMove(1, renderedSize: wide)
        m.forget()
        #expect(m.startMove(1, renderedSize: narrow) == narrow)
    }

    /// The whole run: a 600pt column merged into a 400pt one, then pulled
    /// back out, is 600pt again and the other column shrinks to make room.
    @Test func extractedAgainItGetsTheRememberedWidth() {
        let avail = Rect(topLeftX: 0, topLeftY: 0, width: 1000, height: 600)
        var m = MoveSizeMemory()
        _ = m.startMove(1, renderedSize: CGSize(width: 600, height: 600))
        let l = StackingLayout(shape: .landscapeDefault)
        l.place(2, at: .single(lane: 0, slot: 0))
        l.place(1, at: .single(lane: 0, slot: 1)) // merged as a row
        var w = (0 ..< l.shape.lanes).map { l.laneWeight(lane: $0) }
        w[0] = 1
        l.setLaneWeights(w)
        let remembered = m.startMove(1, renderedSize: CGSize(width: 1000, height: 300))
        l.insertLane(at: 1)
        l.place(1, at: .soleSlot(lane: 1))
        l.keepLaneWidth((remembered?.width ?? 0) / avail.width, lane: 1)
        #expect(abs((l.resolveRect(for: 1, in: avail)?.width ?? 0) - 600) < 1)
        #expect(abs((l.resolveRect(for: 2, in: avail)?.width ?? 0) - 400) < 1)
    }
}
