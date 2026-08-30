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
        mem.remember(appId: "com.app", title: "Doc A", workspace: "3", shape: shape, span: .single(lane: 2, slot: 1))
        mem.rememberFloating(appId: "com.app", title: "Doc B", workspace: "web", shape: shape)
        mem.save()

        // Reload from disk — mode + span + workspace survive, and the title
        // distinguishes the two windows of the same app.
        let reloaded = WindowMemory(storeURL: url)
        let a = reloaded.recall(appId: "com.app", title: "Doc A", shape: shape)
        let b = reloaded.recall(appId: "com.app", title: "Doc B", shape: shape)
        #expect(a?.floating == false)
        #expect(a?.span == TileSpan.single(lane: 2, slot: 1))
        #expect(a?.workspace == "3")
        #expect(b?.floating == true)
        #expect(b?.workspace == "web")
        #expect(reloaded.recall(appId: "com.app", title: "Doc C", shape: shape) == nil)
    }

    /// The app-span pool is the fallback when a title miss means mur can't
    /// tell which window is which. It must hand out cells WORKSPACE-MAJOR:
    /// ordering by cell alone interleaves the workspaces (every workspace
    /// has a lane 0), scattering an app's windows across workspaces they
    /// never lived in.
    @Test func tiledPoolIsOrderedByWorkspaceThenCell() {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let shape = LayoutShape.landscapeDefault
        let mem = WindowMemory(storeURL: url)
        mem.remember(appId: "com.app", title: "w3 right", workspace: "3", shape: shape, span: .single(lane: 1, slot: 0))
        mem.remember(appId: "com.app", title: "w3 left", workspace: "3", shape: shape, span: .single(lane: 0, slot: 0))
        mem.remember(appId: "com.app", title: "w1 left", workspace: "1", shape: shape, span: .single(lane: 0, slot: 0))
        mem.rememberFloating(appId: "com.app", title: "floater", workspace: "1", shape: shape)
        mem.remember(appId: "other.app", title: "nope", workspace: "1", shape: shape, span: .single(lane: 0, slot: 0))

        let pool = mem.recallTiledByApp(appId: "com.app", shape: shape)
        #expect(pool.map(\.workspace) == ["1", "3", "3"]) // floater and other app excluded
        #expect(pool.map { $0.span.lane0 } == [0, 0, 1])
    }

    @Test func dominantWorkspaceIsWhereMostOfTheAppLives() {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let shape = LayoutShape.landscapeDefault
        let mem = WindowMemory(storeURL: url)
        #expect(mem.dominantWorkspace(appId: "com.app", shape: shape) == nil)

        mem.remember(appId: "com.app", title: "a", workspace: "3", shape: shape, span: .single(lane: 0, slot: 0))
        mem.remember(appId: "com.app", title: "b", workspace: "3", shape: shape, span: .single(lane: 1, slot: 0))
        mem.remember(appId: "com.app", title: "c", workspace: "1", shape: shape, span: .single(lane: 0, slot: 0))
        #expect(mem.dominantWorkspace(appId: "com.app", shape: shape) == "3")

        // A tie breaks by name, so the answer doesn't flip between restarts.
        mem.remember(appId: "com.app", title: "d", workspace: "1", shape: shape, span: .single(lane: 1, slot: 0))
        #expect(mem.dominantWorkspace(appId: "com.app", shape: shape) == "1")
        #expect(mem.dominantWorkspace(appId: "unknown.app", shape: shape) == nil)
    }

    @Test func rememberFloatingKeepsPreviousSpan() {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let shape = LayoutShape.landscapeDefault
        let mem = WindowMemory(storeURL: url)
        mem.remember(appId: "x", title: "t", workspace: "1", shape: shape, span: .single(lane: 3, slot: 0))
        mem.rememberFloating(appId: "x", title: "t", workspace: "1", shape: shape)
        let s = mem.recall(appId: "x", title: "t", shape: shape)
        #expect(s?.floating == true)
        #expect(s?.span == TileSpan.single(lane: 3, slot: 0)) // span preserved for a later re-tile
        #expect(s?.workspace == "1")
    }
}
