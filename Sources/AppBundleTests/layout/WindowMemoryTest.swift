@testable import AppBundle
import Common
import Foundation
import Testing

@Suite("WindowMemory")
struct WindowMemoryTest {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("mur-test-\(UUID().uuidString).json")
    }

    @Test func roundTripsTiledAndFloatingKeyedByTitle() {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let shape = LayoutShape.landscapeDefault
        let mem = WindowMemory(storeURL: url)
        mem.remember(appId: "com.app", title: "Doc A", shape: shape, span: .single(lane: 2, slot: 1))
        mem.rememberFloating(appId: "com.app", title: "Doc B", shape: shape)
        mem.save()

        // Reload from disk — mode + span survive, and the title
        // distinguishes the two windows of the same app.
        let reloaded = WindowMemory(storeURL: url)
        let a = reloaded.recall(appId: "com.app", title: "Doc A", shape: shape)
        let b = reloaded.recall(appId: "com.app", title: "Doc B", shape: shape)
        #expect(a?.floating == false)
        #expect(a?.span == TileSpan.single(lane: 2, slot: 1))
        #expect(b?.floating == true)
        #expect(reloaded.recall(appId: "com.app", title: "Doc C", shape: shape) == nil)
    }

    @Test func rememberFloatingKeepsPreviousSpan() {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let shape = LayoutShape.landscapeDefault
        let mem = WindowMemory(storeURL: url)
        mem.remember(appId: "x", title: "t", shape: shape, span: .single(lane: 3, slot: 0))
        mem.rememberFloating(appId: "x", title: "t", shape: shape)
        let s = mem.recall(appId: "x", title: "t", shape: shape)
        #expect(s?.floating == true)
        #expect(s?.span == TileSpan.single(lane: 3, slot: 0)) // span preserved for a later re-tile
    }
}
