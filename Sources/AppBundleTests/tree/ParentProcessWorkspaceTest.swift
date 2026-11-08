@testable import AppBundle
import Foundation
import Testing

@Suite("ParentProcessWorkspace")
struct ParentProcessWorkspaceTest {
    // launchd(1) ← terminal(100) ← shell(200) ← just(300) ← app(400)
    let parents: [pid_t: pid_t] = [400: 300, 300: 200, 200: 100, 100: 1]

    func walk(
        _ pid: pid_t,
        workspaces: [pid_t: Set<String>],
        lastFocused: [pid_t: String] = [:],
        focused: String = "1",
    ) -> String? {
        parentProcessWorkspaceName(
            of: pid,
            parentOf: { parents[$0] },
            workspacesOf: { workspaces[$0] ?? [] },
            lastFocusedOf: { lastFocused[$0] },
            focused: focused,
        )
    }

    @Test func aWindowOpensOnItsNearestWindowedAncestorsWorkspace() {
        #expect(walk(400, workspaces: [100: ["2"]]) == "2")
    }

    @Test func theAppsOwnWindowsDoNotCount() {
        #expect(walk(400, workspaces: [400: ["3"], 100: ["2"]]) == "2")
    }

    @Test func noWindowedAncestorFallsBack() {
        #expect(walk(400, workspaces: [400: ["3"]]) == nil)
        #expect(walk(100, workspaces: [1: ["2"]]) == nil) // launchd is never a parent here
    }

    @Test func anAncestorOnSeveralWorkspacesUsesTheOneLastFocused() {
        let spread: [pid_t: Set<String>] = [100: ["2", "5"]]
        #expect(walk(400, workspaces: spread, lastFocused: [100: "5"]) == "5")
        #expect(walk(400, workspaces: spread, focused: "2") == "2")
        #expect(walk(400, workspaces: spread, focused: "9") == "2")
    }

    @Test func aProcessCycleEnds() {
        let looping: [pid_t: pid_t] = [10: 20, 20: 10]
        let name = parentProcessWorkspaceName(
            of: 10, parentOf: { looping[$0] }, workspacesOf: { _ in [] },
            lastFocusedOf: { _ in nil }, focused: "1",
        )
        #expect(name == nil)
    }

    @Test func theKernelKnowsThisProcessesParent() {
        #expect(parentPid(getpid()) == getppid())
    }
}
