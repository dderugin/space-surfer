import Darwin
import Foundation
import ScanCore
import Testing

@Test func scanAndRankAllocatedFiles() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    let nested = root.appending(path: "Projects", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let large = nested.appending(path: "master.mov")
    let small = root.appending(path: "notes.txt")
    try Data(repeating: 65, count: 96_000).write(to: large)
    try Data(repeating: 66, count: 15_000).write(to: small)
    try FileManager.default.linkItem(at: large, to: nested.appending(path: "hard-link"))
    try FileManager.default.createSymbolicLink(at: nested.appending(path: "parent"), withDestinationURL: root)

    let fast = try ScanSnapshot.scan(root, control: ScanControl())
    let reference = try ScanSnapshot.scan(root, control: ScanControl(), useBulk: false)
    let expected = try [large, small].reduce(UInt64(0)) { $0 + (try allocated($1)) }
    #expect(fast.item(0).allocated == expected)
    #expect(reference.item(0).allocated == expected)
    #expect(fast.item(0).descendants == 5)
    #expect(fast.progress.visited == 5)
    #expect(fast.progress.skipped == 0)

    let direct = try await fast.ranked(in: 0, mode: .contents, limit: 1)
    #expect(direct.total == 2)
    let folder = try #require(direct.ids.first)
    #expect(fast.name(folder) == "Projects")
    let outline = try await fast.ranked(in: 0, mode: .folders, limit: 10)
    #expect(outline.ids == [folder])
    let biggest = try await fast.ranked(in: 0, mode: .files, limit: 2)
    #expect(biggest.total == 3)
    let first = try #require(biggest.ids.first)
    #expect(fast.item(first).parent == folder)
    #expect(fast.trail(to: first) == [0, folder, first])
    #expect(fast.url(for: first).deletingLastPathComponent() == nested)
    #expect(fast.name(biggest.ids[1]) == "notes.txt")
    let children = try await fast.ranked(in: folder, mode: .contents, limit: 10)
    #expect(children.ids.map(fast.name).contains("parent"))
    #expect(children.ids.contains { fast.item($0).kind == .symbolicLink })
    #expect(try await fast.ranked(in: folder, mode: .folders, limit: 10).ids.isEmpty)
}

@Test(arguments: [true, false])
func cancelledScanDoesNotReturnPartialResult(useBulk: Bool) throws {
    let root = try makeTemporaryScanDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let control = try ScanControl()
    control.cancel()
    #expect(throws: CancellationError.self) {
        try ScanSnapshot.scan(root, control: control, useBulk: useBulk)
    }
}

@Test(arguments: [true, false])
func liveIndexCanBeQueriedBeforeAndDuringTraversal(useBulk: Bool) async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    for index in 0..<12 {
        let folder = root.appending(path: "Folder \(index)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        for file in 0..<50 { try Data().write(to: folder.appending(path: "File \(file)")) }
    }
    let live = try ScanSnapshot(root, control: ScanControl())
    #expect(try await live.ranked(in: 0, mode: .folders, limit: 20).ids.isEmpty)
    let traversal = Task.detached { try live.walk(useBulk: useBulk, workerCount: ScanSnapshot.maximumWorkerCount) }
    var previous = live.progress
    for _ in 0..<8 {
        let discovered = try await live.ranked(in: 0, mode: .folders, limit: 20)
        #expect(discovered.total <= 12)
        for id in discovered.ids {
            #expect(live.item(id).kind == .folder)
            #expect(live.name(id).hasPrefix("Folder "))
        }
        let progress = live.progress
        #expect(progress.visited >= previous.visited)
        #expect(progress.skipped >= previous.skipped)
        previous = progress
    }
    _ = try await traversal.value
    #expect(live.item(0).descendants == 612)
    #expect(live.progress.visited == 612)
    #expect(try await live.ranked(in: 0, mode: .files, limit: 20).total == 600)
}

func allocated(_ url: URL) throws -> UInt64 {
    var attributes = stat()
    guard lstat(url.path(percentEncoded: false), &attributes) == 0 else { throw POSIXError(.ENOENT) }
    return UInt64(attributes.st_blocks) * 512
}
