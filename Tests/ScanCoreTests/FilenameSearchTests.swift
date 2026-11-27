import Foundation
import ScanCore
import Testing

@Test func filenameSearchResumesFromLiveCursorAndPagesWithoutDuplicates() async throws {
    let root = try makeTemporaryScanDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let folder = root.appending(path: "Reports", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    for name in ["report.txt", "REPORT final.pdf", "notes.txt"] {
        try Data([1]).write(to: folder.appending(path: name))
    }
    let live = try ScanSnapshot(root, control: ScanControl())
    let early = try await live.searchFilenames("report", limit: 1)
    #expect(early.ids.isEmpty && !early.complete)

    _ = try await Task.detached { try live.walk() }.value
    var page = try await live.searchFilenames("report", from: early.next, limit: 1)
    var found: [String] = []
    while !page.complete {
        found.append(contentsOf: page.ids.map(live.name))
        #expect(page.ids.count == 1)
        page = try await live.searchFilenames("report", from: page.next, limit: 1)
    }
    found.append(contentsOf: page.ids.map(live.name))
    #expect(found.sorted() == ["REPORT final.pdf", "Reports", "report.txt"])
}

@Test func filenameSearchHandlesUnicodeAndExcludesDetachedBranches() async throws {
    let root = try makeTemporaryScanDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let folder = root.appending(path: "Old", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    try Data([1]).write(to: folder.appending(path: "Cafe\u{0301}.txt"))
    let snapshot = try ScanSnapshot.scan(root, control: ScanControl())

    let found = try await snapshot.searchFilenames("CAFÉ", limit: 16)
    #expect(found.complete)
    #expect(found.ids.map(snapshot.name) == ["Café.txt"])
    let folders = try await snapshot.searchFilenames("old", limit: 16)
    let folderID = try #require(folders.ids.first)
    let target = try snapshot.prepareRemoval(of: folderID)
    #expect(try snapshot.remove(target, using: .permanent))
    #expect(try await snapshot.searchFilenames("café", limit: 16).ids.isEmpty)
}
