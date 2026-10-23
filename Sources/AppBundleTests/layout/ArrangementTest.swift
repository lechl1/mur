@testable import AppBundle
import Common
import Foundation
import Testing

@Suite("Arrangement")
struct ArrangementTest {
    private func w(_ title: String, _ app: String = "app") -> ArrangedWindow { ArrangedWindow(appId: app, title: title) }
    private func col(_ windows: ArrangedWindow...) -> ArrangedColumn { ArrangedColumn(width: 0.4, windows: windows) }

    /// The reported bug: creeper sits under a terminal, the app restarts,
    /// and the saved arrangement must keep its spot while it's gone.
    @Test func closedWindowStaysBesideItsNeighbours() {
        let creeper = w("creeper", "lab.home.creeper")
        let saved = [col(w("a")), col(w("b"), creeper), col(w("c"))]
        let live = [col(w("a")), col(w("b")), col(w("c"))]
        #expect(Arrangement.merge(saved: saved, live: live).columns == saved)
    }

    @Test func closedColumnStaysBetweenItsNeighbours() {
        let saved = [col(w("a")), col(w("x", "other")), col(w("c"))]
        let live = [col(w("a")), col(w("c"))]
        #expect(Arrangement.merge(saved: saved, live: live).columns.map { $0.windows } == [[w("a")], [w("x", "other")], [w("c")]])
    }

    @Test func liveOrderWinsOverTheSavedOne() {
        // The user swapped two columns: the live screen is the truth.
        let saved = [col(w("a")), col(w("b"))]
        let live = [col(w("b")), col(w("a"))]
        #expect(Arrangement.merge(saved: saved, live: live).columns == live)
    }

    @Test func renamedWindowIsNotAlsoAGhost() {
        // A browser whose title changed is the same window, not a new one
        // plus a ghost of the old.
        let saved = [col(w("tab 1", "brave")), col(w("a"))]
        let live = [col(w("tab 2", "brave")), col(w("a"))]
        #expect(Arrangement.merge(saved: saved, live: live).columns == live)
    }

    @Test func windowMovedToAnotherWorkspaceIsNoGhostHere() {
        let saved = [col(w("a")), col(w("b"))]
        let live = [col(w("a"))]
        let merged = Arrangement.merge(saved: saved, live: live, heldElsewhere: [w("b")])
        #expect(merged.columns == live)
    }

    @Test func ghostCellDescribesTheLiveNeighbours() {
        let creeper = w("creeper", "lab.home.creeper")
        let columns = [col(w("a")), col(w("b"), creeper), col(w("c"))]
        let ids: [Arrangement.Path: WindowId] = [
            .init(column: 0, row: 0): 1, .init(column: 1, row: 0): 2, .init(column: 2, row: 0): 3,
        ]
        let found = Arrangement.ghostCell(appId: "lab.home.creeper", in: columns, windowAt: { ids[$0] })
        #expect(found?.path == .init(column: 1, row: 1))
        #expect(found?.cell.above == [2])
        #expect(found?.cell.left == [[1]])
        #expect(found?.cell.right == [[3]])
        #expect(Arrangement.ghostCell(appId: "nope", in: columns, windowAt: { ids[$0] }) == nil)
    }

    @Test func reopenedWindowLandsInItsOldSpot() {
        // Terminals in three columns, creeper was under the middle one and
        // its app restarted: the new window goes back there.
        let layout = StackingLayout(shape: .landscapeDefault)
        layout.place(1, at: .soleSlot(lane: 0))
        layout.place(2, at: .soleSlot(lane: 1))
        layout.place(3, at: .soleSlot(lane: 2))
        let creeper = w("creeper", "lab.home.creeper")
        let columns = [col(w("a")), col(w("b"), creeper), col(w("c"))]
        let ids: [Arrangement.Path: WindowId] = [
            .init(column: 0, row: 0): 1, .init(column: 1, row: 0): 2, .init(column: 2, row: 0): 3,
        ]
        let cell = Arrangement.ghostCell(appId: "lab.home.creeper", in: columns, windowAt: { ids[$0] })!.cell
        #expect(layout.placeBeside(9, cell))
        #expect(layout.placements[9] == .single(lane: 1, slot: 1))
    }

    @Test func storeClaimsByIdentityThenCwdThenApp() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mur-arr-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = ArrangementStore(url: url)
        let t1 = ArrangedWindow(appId: "term", title: "one", cwd: "/a")
        let t2 = ArrangedWindow(appId: "term", title: "two", cwd: "/b")
        store.update(live: ["2": [col(t1), col(t2)], "1": [col(w("x"))]], ids: ["2": [[1], [2]], "1": [[3]]], restoring: false)
        let reloaded = ArrangementStore(url: url)
        // Same cwd, title changed: still that terminal's spot.
        let a = reloaded.claim(ArrangedWindow(appId: "term", title: "renamed", cwd: "/b"))
        #expect(a?.workspace == "2")
        #expect(a?.path == .init(column: 1, row: 0))
        #expect(a?.isAppGuess == false)
        // Each entry is handed out once.
        let b = reloaded.claim(ArrangedWindow(appId: "term", title: "zzz", cwd: "/zzz"))
        #expect(b?.path == .init(column: 0, row: 0))
        #expect(b?.isAppGuess == true)
        #expect(reloaded.claim(ArrangedWindow(appId: "term", title: "more")) == nil)
    }
}
