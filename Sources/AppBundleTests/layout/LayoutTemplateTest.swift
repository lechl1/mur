@testable import AppBundle
import Common
import Foundation
import Testing

/// mur — layout templates: `save-layout` writes one, `open-layout` rebuilds
/// it on a free workspace with windows arriving in any order.
@Suite("LayoutTemplate")
struct LayoutTemplateTest {
    private typealias Item = LayoutTemplate.Item
    private typealias Cell = LayoutTemplate.Cell

    /// Workspace 3 when this was written: a browser over two terminals, an IDE beside them.
    private let workspace3 = LayoutTemplate(column: [
        .init(width: 0.412, window: [
            Item(app: "net.imput.helium", height: 0.557, launch: "open -n -b net.imput.helium --args --new-window http://localhost:8011/browse"),
            Item(app: "com.mitchellh.ghostty", height: 0.177, launch: #"open -n -b com.mitchellh.ghostty --args --working-directory="$MUR_DIR" --input=claude$'\n'"#),
            Item(app: "com.mitchellh.ghostty", height: 0.267, launch: "it's quoted"),
        ]),
        .init(width: 0.601, window: [
            Item(app: "com.jetbrains.rustrover", height: 1, launch: #"open -b com.jetbrains.rustrover "$MUR_DIR""#),
        ]),
    ])

    @Test func tomlRoundTrips() throws {
        var noted = workspace3
        noted.column[0].window[0].note = "localhost:8011/browse - Helium"
        let toml = noted.toToml(header: ["saved from workspace 3"])
        // A launch ending in a quote comes back with the space that kept it
        // off the ''' delimiter.
        var expected = workspace3
        expected.column[0].window[1].launch += " "
        #expect(try LayoutTemplate.parse(toml) == expected)
        #expect(toml.contains("# was: localhost:8011/browse - Helium"))
    }

    @Test func handWrittenTomlWithoutHeights() throws {
        let toml = """
            [[column]]
            width = 1
            [[column.window]]
            app = "a"
            launch = "open -b a"
            """
        let template = try LayoutTemplate.parse(toml)
        #expect(template.column.first?.width == 1)
        #expect(template.column.first?.window.first?.height == nil)
    }

    @Test func tomlStringEscapes() {
        #expect(LayoutTemplate.tomlString(#"a "b""#) == #"'a "b"'"#)
        #expect(LayoutTemplate.tomlString("it's") == "'''it's'''")
        #expect(LayoutTemplate.tomlString("'a'") == "''' 'a' '''")
        #expect(LayoutTemplate.tomlString("a\nb's") == #""a\nb's""#)
    }

    // MARK: launch guesses

    private func launch(_ app: String, _ title: String, cwd: String? = nil, url: String? = nil, base: String? = "/src/ws") -> String {
        LaunchGuess.launch(for: CapturedWindow(appId: app, title: title, cwd: cwd, url: url), base: base)
    }

    @Test func terminalRunsWhatItsTitleShows() {
        #expect(LaunchGuess.terminalCommand(title: "slipway dev creeper --web") == "slipway dev creeper --web")
        #expect(LaunchGuess.terminalCommand(title: "◐ Starting Creeper in local dev") == "claude")
        #expect(LaunchGuess.terminalCommand(title: "~/src/workspace") == nil)
        #expect(LaunchGuess.terminalCommand(title: "") == nil)
        #expect(launch("com.mitchellh.ghostty", "slipway dev creeper --web", cwd: "/src/ws")
            == #"open -n -b com.mitchellh.ghostty --args --working-directory="$MUR_DIR" --input='slipway dev creeper --web'$'\n'"#)
        #expect(launch("com.mitchellh.ghostty", "~", cwd: "/src/ws/app")
            == #"open -n -b com.mitchellh.ghostty --args --working-directory="$MUR_DIR"/app"#)
        #expect(launch("com.mitchellh.ghostty", "~", cwd: "/elsewhere/x y")
            == "open -n -b com.mitchellh.ghostty --args --working-directory='/elsewhere/x y'")
    }

    @Test func otherAppsOpenANewWindow() {
        #expect(launch("net.imput.helium", "t", url: "http://localhost:8011/browse")
            == "open -n -b net.imput.helium --args --new-window http://localhost:8011/browse")
        #expect(launch("com.jetbrains.rustrover", "p – f") == #"open -b com.jetbrains.rustrover "$MUR_DIR""#)
        #expect(launch("dev.zed.Zed", "x") == #"open -b dev.zed.Zed "$MUR_DIR""#)
        #expect(launch("lab.home.creeper", "creeper") == "open -b lab.home.creeper")
    }

    @Test func baseIsWhereMostTerminalsAre() {
        #expect(LaunchGuess.baseDirectory(["/a", "/b", "/b"]) == "/b")
        #expect(LaunchGuess.baseDirectory([]) == nil)
    }

    @Test func shellQuoting() {
        #expect(shellQuote("plain/path-1.x") == "plain/path-1.x")
        #expect(shellQuote("it's") == #"'it'\''s'"#)
        #expect(shellQuote("") == "''")
    }

    // MARK: rebuilding in the grid

    /// Place windows 1…4 into `template`'s cells in `order`, as they'd arrive.
    private func rebuild(_ template: LayoutTemplate, order: [Int]) -> (StackingLayout, [WindowId: Cell]) {
        let cells = template.cells.map(\.cell)
        let layout = StackingLayout(shape: .landscapeDefault)
        var placed: [WindowId: Cell] = [:]
        for i in order {
            let id = WindowId(i + 1)
            layout.placeFromTemplate(id, at: cells[i], placed: placed)
            placed[id] = cells[i]
            layout.applyTemplateSizes(template, placed: placed)
        }
        return (layout, placed)
    }

    @Test(arguments: [[0, 1, 2, 3], [3, 2, 1, 0], [3, 1, 0, 2], [2, 3, 0, 1]])
    func anyArrivalOrderGivesTheSavedGrid(order: [Int]) {
        let (layout, _) = rebuild(workspace3, order: order)
        #expect(layout.placements[1] == .single(lane: 0, slot: 0))
        #expect(layout.placements[2] == .single(lane: 0, slot: 1))
        #expect(layout.placements[3] == .single(lane: 0, slot: 2))
        #expect(layout.placements[4] == .single(lane: 1, slot: 0))
        #expect(abs(layout.laneWeight(lane: 0) - 0.412) < 1e-9)
        #expect(abs(layout.laneWeight(lane: 1) - 0.601) < 1e-9)
        let heights = (0 ..< 3).map { layout.slotWeight(lane: 0, slot: $0) }
        #expect(zip(heights, [0.557, 0.177, 0.267]).allSatisfy { abs($0 - $1) < 1e-9 })
    }

    @Test func aMissingWindowLeavesNoGap() {
        // Column 0 never got its first row (the window didn't appear).
        let (layout, _) = rebuild(workspace3, order: [3, 2, 1])
        #expect(layout.placements[2] == .single(lane: 0, slot: 0))
        #expect(layout.placements[3] == .single(lane: 0, slot: 1))
        #expect(layout.placements[4] == .single(lane: 1, slot: 0))
    }

    @Test func middleColumnArrivingLastIsInsertedBetween() {
        let three = LayoutTemplate(column: (0 ..< 3).map { _ in
            .init(width: 0.3, window: [Item(app: "a", launch: "x")])
        })
        let (layout, _) = rebuild(three, order: [2, 0, 1])
        #expect(layout.placements[1]?.lane0 == 0)
        #expect(layout.placements[2]?.lane0 == 1)
        #expect(layout.placements[3]?.lane0 == 2)
    }
}
