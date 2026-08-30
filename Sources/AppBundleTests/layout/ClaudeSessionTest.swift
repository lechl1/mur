@testable import AppBundle
import Common
import Foundation
import Testing

/// mur — resolving the Claude Code conversation running in a directory, so a
/// restored terminal comes back in it rather than at the session picker.
@Suite("ClaudeSession")
struct ClaudeSessionTest {
    private func makeProjects() -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mur-claude-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// Write `<projects>/<encoded>/<id>.jsonl` recording `cwd`, with `mtime`.
    private func writeTranscript(
        in projects: URL, encoded: String, id: String, cwd: String, mtime: Date,
    ) {
        let dir = projects.appendingPathComponent(encoded, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(id).jsonl")
        // Leading metadata records carry no cwd — the scan has to look past them.
        let body = """
            {"type":"mode","mode":"default"}
            {"type":"user","cwd":"\(cwd)","message":"hi"}
            """
        try? body.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: url.path)
    }

    @Test func resolvesNewestTranscriptForTheDirectory() async {
        let projects = makeProjects()
        defer { try? FileManager.default.removeItem(at: projects) }
        let cwd = "/Users/x/src/mur"
        let encoded = "-Users-x-src-mur"
        writeTranscript(in: projects, encoded: encoded, id: "old", cwd: cwd, mtime: .now - 600)
        writeTranscript(in: projects, encoded: encoded, id: "live", cwd: cwd, mtime: .now)

        #expect(await claudeSessionId(forCwd: cwd, projectsDir: projects) == "live")
        // Nothing recorded for a directory mur has never seen.
        #expect(await claudeSessionId(forCwd: "/Users/x/other", projectsDir: projects) == nil)
    }

    /// The directory encoding is lossy: `/Users/x/a.b` and `/Users/x/a/b` both
    /// encode to `-Users-x-a-b`, so their transcripts share one directory. The
    /// cwd recorded INSIDE the transcript is what disambiguates them.
    @Test func lossyEncodingIsDisambiguatedByRecordedCwd() async {
        let projects = makeProjects()
        defer { try? FileManager.default.removeItem(at: projects) }
        let encoded = "-Users-x-a-b"
        writeTranscript(in: projects, encoded: encoded, id: "dotted", cwd: "/Users/x/a.b", mtime: .now)
        writeTranscript(in: projects, encoded: encoded, id: "nested", cwd: "/Users/x/a/b", mtime: .now - 60)

        // The newest transcript belongs to the OTHER directory, so the older
        // one wins for this cwd instead of the newest overall.
        #expect(await claudeSessionId(forCwd: "/Users/x/a/b", projectsDir: projects) == "nested")
        #expect(await claudeSessionId(forCwd: "/Users/x/a.b", projectsDir: projects) == "dotted")
    }
}
