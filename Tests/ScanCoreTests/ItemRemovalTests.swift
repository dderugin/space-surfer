import Foundation
import ScanCore
import Testing

@Test func batchRemovalDeduplicatesDescendantsAndReportsPartialFailure() async throws {
    let files = FileManager.default
    let root = files.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    let folder = root.appending(path: "Folder", directoryHint: .isDirectory)
    try files.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? files.removeItem(at: root) }
    for url in [folder.appending(path: "Child"), root.appending(path: "Loose"), root.appending(path: "Replaced")] {
        try Data([1]).write(to: url)
    }
    let snapshot = try ScanSnapshot.scan(root, control: ScanControl())
    let direct = try await snapshot.ranked(in: 0, mode: .contents, limit: 10)
    let folderID = try #require(direct.ids.first { snapshot.name($0) == "Folder" })
    let child = try await snapshot.ranked(in: folderID, mode: .contents, limit: 10)
    let batch = try RemovalBatch(snapshot: snapshot, ids: Set(direct.ids + child.ids))
    #expect(batch.targets.count == 3)

    let replaced = root.appending(path: "Replaced")
    try files.moveItem(at: replaced, to: root.appending(path: "Original"))
    try Data([2]).write(to: replaced)
    let result = batch.run(on: snapshot, using: .permanent)
    #expect(result.removed.count == 2)
    #expect(result.failures.count == 1)
    #expect(try Data(contentsOf: replaced) == Data([2]))
    let remaining = try await snapshot.ranked(in: 0, mode: .contents, limit: 10)
    #expect(remaining.ids.map(snapshot.name) == ["Replaced"])
}

@Test func permanentRemovalUpdatesFoldersAndBiggestFiles() async throws {
    let files = FileManager.default
    let root = files.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    let folder = root.appending(path: "Nested", directoryHint: .isDirectory)
    try files.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? files.removeItem(at: root) }

    let large = folder.appending(path: "large.bin")
    let small = root.appending(path: "keep.bin")
    try Data(repeating: 1, count: 32_768).write(to: large)
    try Data(repeating: 2, count: 4096).write(to: small)
    try files.createSymbolicLink(at: folder.appending(path: "outside"), withDestinationURL: small)
    let snapshot = try ScanSnapshot.scan(root, control: ScanControl())
    #expect(throws: RemovalError.self) { try snapshot.prepareRemoval(of: ScanSnapshot.root) }

    let initial = try await snapshot.ranked(in: ScanSnapshot.root, mode: .files, limit: 10)
    let fileID = try #require(initial.ids.first)
    #expect(snapshot.name(fileID) == "large.bin")
    let target = try snapshot.prepareRemoval(of: fileID)
    let remainingBytes = snapshot.item(ScanSnapshot.root).allocated - snapshot.item(fileID).allocated
    #expect(try snapshot.remove(target, using: .permanent))
    #expect(!files.fileExists(atPath: large.path(percentEncoded: false)))
    #expect(snapshot.item(ScanSnapshot.root).allocated == remainingBytes)
    #expect(snapshot.item(ScanSnapshot.root).descendants == 3)
    #expect(try await snapshot.ranked(in: ScanSnapshot.root, mode: .files, limit: 10).ids.map(snapshot.name) == ["keep.bin"])

    let folders = try await snapshot.ranked(in: ScanSnapshot.root, mode: .folders, limit: 10)
    let folderID = try #require(folders.ids.first)
    let folderTrail = snapshot.trail(to: folderID)
    #expect(try snapshot.remove(snapshot.prepareRemoval(of: folderID), using: .permanent))
    #expect(!files.fileExists(atPath: folder.path(percentEncoded: false)))
    #expect(files.fileExists(atPath: small.path(percentEncoded: false)))
    #expect(snapshot.item(ScanSnapshot.root).descendants == 1)
    #expect(try await snapshot.ranked(in: ScanSnapshot.root, mode: .folders, limit: 10).ids.isEmpty)
    #expect(snapshot.trail(to: folderID) == folderTrail)
    #expect(snapshot.url(for: folderID).path(percentEncoded: false) == folder.path(percentEncoded: false))
    #expect(try await snapshot.ranked(in: folderID, mode: .contents, limit: 10).ids.isEmpty)
    #expect(throws: RemovalError.self) { try snapshot.prepareRemoval(of: folderID) }
}

@Test func removalRejectsAReplacedScanRoot() async throws {
    let files = FileManager.default
    let parent = files.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    let root = parent.appending(path: "Scanned", directoryHint: .isDirectory)
    let item = root.appending(path: "Same name.bin")
    try files.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? files.removeItem(at: parent) }

    try Data([1]).write(to: item)
    let snapshot = try ScanSnapshot.scan(root, control: ScanControl())
    let page = try await snapshot.ranked(in: 0, mode: .contents, limit: 1)
    let id = try #require(page.ids.first)

    try files.moveItem(at: root, to: parent.appending(path: "Original"))
    try files.createDirectory(at: root, withIntermediateDirectories: false)
    try Data([2]).write(to: item)

    #expect(throws: RemovalError.self) { try snapshot.prepareRemoval(of: id) }
    #expect(try Data(contentsOf: item) == Data([2]))
}

@Test func confirmationRejectsAnItemReplacedAtTheSamePath() async throws {
    let files = FileManager.default
    let root = files.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try files.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? files.removeItem(at: root) }

    let item = root.appending(path: "selected.bin")
    let original = root.appending(path: "original.bin")
    try Data([1]).write(to: item)
    let snapshot = try ScanSnapshot.scan(root, control: ScanControl())
    let children = try await snapshot.ranked(in: ScanSnapshot.root, mode: .contents, limit: 1)
    let target = try snapshot.prepareRemoval(of: #require(children.ids.first))
    try files.moveItem(at: item, to: original)
    try Data([2]).write(to: item)

    #expect(throws: RemovalError.self) { try snapshot.remove(target, using: .permanent) }
    #expect(try Data(contentsOf: item) == Data([2]))
    #expect(try Data(contentsOf: original) == Data([1]))
}

@Test(arguments: [true, false])
func preparationRejectsReplacementsSinceTheScan(useBulk: Bool) async throws {
    let files = FileManager.default
    let root = try makeTemporaryScanDirectory()
    defer { try? files.removeItem(at: root) }
    let folder = root.appending(path: "Folder", directoryHint: .isDirectory)
    let originalFolder = root.appending(path: "Original", directoryHint: .isDirectory)
    let file = folder.appending(path: "File.bin")
    try files.createDirectory(at: folder, withIntermediateDirectories: false)
    try Data([1]).write(to: file)
    let snapshot = try ScanSnapshot.scan(root, control: ScanControl(), useBulk: useBulk)
    let folders = try await snapshot.ranked(in: ScanSnapshot.root, mode: .folders, limit: 1)
    let folderID = try #require(folders.ids.first)
    let ranked = try await snapshot.ranked(in: ScanSnapshot.root, mode: .files, limit: 1)
    let fileID = try #require(ranked.ids.first)
    _ = try snapshot.prepareRemoval(of: fileID)

    let original = folder.appending(path: "Original.bin")
    try files.moveItem(at: file, to: original)
    try Data([2]).write(to: file)
    #expect(throws: RemovalError.self) { try snapshot.prepareRemoval(of: fileID) }
    #expect(try Data(contentsOf: file) == Data([2]))
    try files.removeItem(at: file)
    try files.moveItem(at: original, to: file)

    try files.moveItem(at: folder, to: originalFolder)
    try files.createDirectory(at: folder, withIntermediateDirectories: false)
    try files.linkItem(at: originalFolder.appending(path: file.lastPathComponent), to: file)
    #expect(throws: RemovalError.self) { try snapshot.prepareRemoval(of: folderID) }
    #expect(throws: RemovalError.self) { try snapshot.prepareRemoval(of: fileID) }
    #expect(throws: RemovalError.self) { try RemovalBatch(snapshot: snapshot, ids: [.max]) }
    #expect(try Data(contentsOf: file) == Data([1]))
}

@Test func removingHardLinkedFilesRequestsARefresh() async throws {
    let files = FileManager.default
    let root = files.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try files.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? files.removeItem(at: root) }

    let first = root.appending(path: "shared.bin")
    let second = root.appending(path: "other-link.bin")
    try Data(repeating: 1, count: 8192).write(to: first)
    try files.linkItem(at: first, to: second)
    let snapshot = try ScanSnapshot.scan(root, control: ScanControl())
    let ranked = try await snapshot.ranked(in: ScanSnapshot.root, mode: .files, limit: 10)
    let target = try snapshot.prepareRemoval(of: #require(ranked.ids.first))

    #expect(try !snapshot.remove(target, using: .permanent))
    let refreshed = try ScanSnapshot.scan(root, control: ScanControl())
    #expect(refreshed.item(ScanSnapshot.root).descendants == 1)
    #expect(refreshed.item(ScanSnapshot.root).allocated == snapshot.item(ScanSnapshot.root).allocated)
}

@Test func removingFolderWithNestedHardLinkRequestsARefresh() async throws {
    let files = FileManager.default
    let root = try makeTemporaryScanDirectory()
    defer { try? files.removeItem(at: root) }
    let folder = root.appending(path: "Folder", directoryHint: .isDirectory)
    let nested = folder.appending(path: "Nested", directoryHint: .isDirectory)
    try files.createDirectory(at: nested, withIntermediateDirectories: true)

    let inside = nested.appending(path: "Shared.bin")
    let outside = root.appending(path: "Retained.bin")
    let payload = Data(repeating: 21, count: 8_192)
    try payload.write(to: inside)
    try files.linkItem(at: inside, to: outside)
    let snapshot = try ScanSnapshot.scan(root, control: ScanControl())
    let ranked = try await snapshot.ranked(in: ScanSnapshot.root, mode: .folders, limit: 1)
    let item = try snapshot.prepareRemoval(of: #require(ranked.ids.first))

    #expect(try !snapshot.remove(item, using: .permanent))
    #expect(!files.fileExists(atPath: folder.path(percentEncoded: false)))
    #expect(try Data(contentsOf: outside) == payload)
    let refreshed = try ScanSnapshot.scan(root, control: ScanControl())
    #expect(refreshed.item(ScanSnapshot.root).allocated == snapshot.item(ScanSnapshot.root).allocated)
}

@Test func removalRejectsAChangedParentSymlink() async throws {
    let files = FileManager.default
    let fixture = try makeTemporaryScanDirectory()
    defer { try? files.removeItem(at: fixture) }

    let root = fixture.appending(path: "Scan", directoryHint: .isDirectory)
    let parent = root.appending(path: "Folder", directoryHint: .isDirectory)
    let outside = fixture.appending(path: "Outside", directoryHint: .isDirectory)
    let name = "File.bin"
    try files.createDirectory(at: parent, withIntermediateDirectories: true)
    try files.createDirectory(at: outside, withIntermediateDirectories: false)
    try Data([1]).write(to: parent.appending(path: name))
    try Data([2]).write(to: outside.appending(path: name))
    let snapshot = try ScanSnapshot.scan(root, control: ScanControl())
    let ranked = try await snapshot.ranked(in: ScanSnapshot.root, mode: .files, limit: 1)
    let item = try snapshot.prepareRemoval(of: #require(ranked.ids.first))

    let original = root.appending(path: "Original", directoryHint: .isDirectory)
    try files.moveItem(at: parent, to: original)
    try files.createSymbolicLink(at: parent, withDestinationURL: outside)
    #expect(throws: POSIXError.self) { try snapshot.remove(item, using: .permanent) }
    #expect(try Data(contentsOf: outside.appending(path: name)) == Data([2]))
    #expect(try Data(contentsOf: original.appending(path: name)) == Data([1]))
}

@Test func removalTargetsBelongToTheirOriginalScan() async throws {
    let root = try makeTemporaryScanDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    let file = root.appending(path: "File.bin")
    try Data([18]).write(to: file)
    let original = try ScanSnapshot.scan(root, control: ScanControl())
    let other = try ScanSnapshot.scan(root, control: ScanControl())
    let ranked = try await original.ranked(in: ScanSnapshot.root, mode: .files, limit: 1)
    let item = try original.prepareRemoval(of: #require(ranked.ids.first))

    #expect(throws: RemovalError.self) { try other.remove(item, using: .permanent) }
    #expect(try Data(contentsOf: file) == Data([18]))
    #expect(other.item(ScanSnapshot.root).descendants == 1)
}
