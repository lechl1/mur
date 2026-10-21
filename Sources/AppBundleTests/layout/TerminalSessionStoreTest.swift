@testable import AppBundle
import Common
import Foundation
import Testing

@Suite("TerminalSessionStore")
struct TerminalSessionStoreTest {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("mur-test-\(UUID().uuidString).json")
    }

    /// Two terminals in one repo must keep a saved cell each. One slot per
    /// cwd restored both into the same cell, stacking them as rows of one
    /// column on every restart.
    @Test func keepsEveryTerminalInACwdInScreenOrder() {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = TerminalSessionStore(url: url)
        store.replace(cwd: "/repo", with: [
            TerminalSession(cwd: "/repo", kind: .claude, workspace: "2", span: .single(lane: 1, slot: 0), title: "b"),
            TerminalSession(cwd: "/repo", kind: .shell, workspace: "2", span: .single(lane: 0, slot: 0), title: "a"),
        ])
        store.replace(cwd: "/other", with: [
            TerminalSession(cwd: "/other", kind: .shell, workspace: "1", span: .single(lane: 0, slot: 0)),
        ])
        store.save()

        let reloaded = TerminalSessionStore(url: url)
        #expect(reloaded.sessions(cwd: "/repo").map(\.lane0) == [0, 1])
        #expect(reloaded.sessions(cwd: "/repo").map(\.title) == ["a", "b"])
        #expect(reloaded.all.count == 3)
    }

    @Test func replaceOverwritesOnlyThatCwd() {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = TerminalSessionStore(url: url)
        store.replace(cwd: "/repo", with: [
            TerminalSession(cwd: "/repo", kind: .shell, workspace: "2", span: .single(lane: 0, slot: 0)),
            TerminalSession(cwd: "/repo", kind: .shell, workspace: "2", span: .single(lane: 1, slot: 0)),
        ])
        store.replace(cwd: "/other", with: [
            TerminalSession(cwd: "/other", kind: .shell, workspace: "1", span: .single(lane: 0, slot: 0)),
        ])
        // One of the two /repo terminals closed: the next sweep rewrites /repo.
        store.replace(cwd: "/repo", with: [
            TerminalSession(cwd: "/repo", kind: .shell, workspace: "2", span: .single(lane: 1, slot: 0)),
        ])
        #expect(store.sessions(cwd: "/repo").map(\.lane0) == [1])
        #expect(store.sessions(cwd: "/other").count == 1)
    }

    /// The title tells two terminals in one cwd apart: each goes back to
    /// its own cell even when they map in the opposite order.
    @Test func titleDistinguishesTerminalsInOneCwd() {
        let left = TerminalSession(cwd: "/repo", kind: .claude, workspace: "2", span: .single(lane: 0, slot: 0), title: "src/workspace")
        let right = TerminalSession(cwd: "/repo", kind: .claude, workspace: "2", span: .single(lane: 1, slot: 0), title: "hz-wayden exit node")
        let saved = [left, right]
        // Claude's status glyph is ignored.
        #expect(pickTerminalSession(from: saved, claimed: [], title: "✳ hz-wayden exit node") == right)
        #expect(pickTerminalSession(from: saved, claimed: [right], title: "~/src/workspace") == left)
        // No title match: next unclaimed in screen order, never a claimed one.
        #expect(pickTerminalSession(from: saved, claimed: [], title: "something else") == left)
        #expect(pickTerminalSession(from: saved, claimed: [left], title: "") == right)
        #expect(pickTerminalSession(from: saved, claimed: [left, right], title: "src/workspace") == nil)
    }
}
