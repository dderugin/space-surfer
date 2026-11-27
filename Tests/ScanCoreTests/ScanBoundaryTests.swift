import Darwin
import Foundation
import ScanCore
import Testing

@Test(arguments: [true, false])
func scanRestoresCallingThreadsFileProviderPolicy(useBulk: Bool) throws {
    let root = try makeTemporaryScanDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    try Data([7]).write(to: root.appending(path: "Local.bin"))

    let policy = getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD)
    try #require(policy >= 0)
    let snapshot = try ScanSnapshot.scan(root, control: ScanControl(), useBulk: useBulk, workerCount: 1)
    #expect(snapshot.progress.visited == 1)
    #expect(getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD) == policy)

    let missing = root.appending(path: "Missing", directoryHint: .isDirectory)
    #expect(throws: POSIXError(.ENOENT)) { try ScanSnapshot.scan(missing, control: ScanControl(), useBulk: useBulk) }
    #expect(getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD) == policy)
}

@Test(arguments: [true, false])
func rankedPagesAreStableAcrossBatches(useBulk: Bool) async throws {
    let files = FileManager.default
    let root = try makeTemporaryScanDirectory()
    defer { try? files.removeItem(at: root) }

    let folder = root.appending(path: "Folder", directoryHint: .isDirectory)
    try files.createDirectory(at: folder, withIntermediateDirectories: false)
    let nested = folder.appending(path: "Nested.bin")
    try Data(repeating: 7, count: 32_768).write(to: nested)
    let link = root.appending(path: "Folder link")
    try files.createSymbolicLink(at: link, withDestinationURL: folder)
    for index in 0..<1_030 {
        let length = index % 11 == 0 ? 4_096 + (index % 8) * 4_096 : 0
        try Data(repeating: 3, count: length).write(to: root.appending(path: "File \(index).bin"))
    }

    let snapshot = try ScanSnapshot.scan(root, control: ScanControl(), useBulk: useBulk)
    let all = try await snapshot.ranked(in: ScanSnapshot.root, mode: .files, limit: 2_000)
    #expect(all.total == 1_031)
    #expect(all.ids.count == all.total)
    #expect(Set(all.ids).count == all.total)
    #expect(snapshot.item(ScanSnapshot.root).descendants == 1_033)
    #expect(snapshot.progress.visited == 1_033)
    #expect(snapshot.progress.skipped == 0)
    let sizes = all.ids.map { snapshot.item($0).allocated }
    #expect(sizes == sizes.sorted(by: >))
    for (left, right) in zip(all.ids, all.ids.dropFirst()) where snapshot.item(left).allocated == snapshot.item(right).allocated {
        #expect(left < right)
    }

    for limit in [-1, 0, 1, 128, 256] {
        let page = try await snapshot.ranked(in: ScanSnapshot.root, mode: .files, limit: limit)
        #expect(page.total == all.total)
        #expect(page.ids == Array(all.ids.prefix(max(0, limit))))
    }

    let contents = try await snapshot.ranked(in: ScanSnapshot.root, mode: .contents, limit: 2_000)
    #expect(contents.total == 1_032)
    #expect(contents.ids.contains { snapshot.item($0).kind == .symbolicLink })
    #expect(!contents.ids.contains { snapshot.name($0) == "Nested.bin" })
    let folders = try await snapshot.ranked(in: ScanSnapshot.root, mode: .folders, limit: 16)
    #expect(folders.ids.map(snapshot.name) == ["Folder"])
    let childScope = try await snapshot.ranked(in: #require(folders.ids.first), mode: .files, limit: 16)
    #expect(childScope.ids.map(snapshot.name) == ["Nested.bin"])
}

@Test(arguments: [true, false])
func deepTrailsKeepRawFilenames(useBulk: Bool) async throws {
    let files = FileManager.default
    let root = try makeTemporaryScanDirectory()
    defer { try? files.removeItem(at: root) }

    let components = (0..<36).map { "Level \($0)" }
    let folder = components.reduce(root) { $0.appending(path: $1, directoryHint: .isDirectory) }
    try files.createDirectory(at: folder, withIntermediateDirectories: true)
    let filename = #".café "quoted" #1.bin"#
    let payload = Data([2, 7, 11])
    try payload.write(to: folder.appending(path: filename))

    let snapshot = try ScanSnapshot.scan(root, control: ScanControl(), useBulk: useBulk)
    let page = try await snapshot.ranked(in: ScanSnapshot.root, mode: .files, limit: 1)
    let id = try #require(page.ids.first)
    let trail = snapshot.trail(to: id)
    #expect(trail.first == ScanSnapshot.root)
    #expect(trail.dropFirst().map(snapshot.name) == components + [filename])
    #expect(try Data(contentsOf: snapshot.url(for: id)) == payload)
    #expect(snapshot.progress.visited == 37)
}

@Test(arguments: [true, false])
func emptyScansAreSingleUse(useBulk: Bool) async throws {
    let root = try makeTemporaryScanDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    let snapshot = try ScanSnapshot.scan(root, control: ScanControl(), useBulk: useBulk)
    #expect(snapshot.item(ScanSnapshot.root).allocated == 0)
    #expect(snapshot.item(ScanSnapshot.root).descendants == 0)
    for mode in [Ranking.contents, .folders, .files] {
        let page = try await snapshot.ranked(in: ScanSnapshot.root, mode: mode, limit: 128)
        #expect(page.ids.isEmpty)
        #expect(page.total == 0)
    }
    #expect(throws: POSIXError(.EINVAL)) { try snapshot.walk(useBulk: useBulk) }
}

@Test func missingAndNonDirectoryRootsReportErrors() throws {
    let root = try makeTemporaryScanDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    let missing = root.appending(path: "Missing")
    let file = root.appending(path: "File.bin")
    try Data([4]).write(to: file)
    #expect(throws: POSIXError(.ENOENT)) { try ScanSnapshot.scan(missing, control: ScanControl()) }
    #expect(throws: POSIXError(.ENOTDIR)) { try ScanSnapshot.scan(file, control: ScanControl()) }
}

@Test func cancelledRankingDoesNotReturnAPage() async throws {
    let root = try makeTemporaryScanDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    try Data([1]).write(to: root.appending(path: "File.bin"))
    let snapshot = try ScanSnapshot.scan(root, control: ScanControl())
    let task = Task.detached {
        withUnsafeCurrentTask { $0?.cancel() }
        return try await snapshot.ranked(in: ScanSnapshot.root, mode: .files, limit: 1)
    }
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(try await snapshot.ranked(in: ScanSnapshot.root, mode: .files, limit: 1).total == 1)
}

@Test(arguments: [true, false], [1, 2, ScanSnapshot.maximumWorkerCount] as [UInt32])
func hardLinkTotalsSurviveLookupTableGrowth(useBulk: Bool, workerCount: UInt32) async throws {
    let files = FileManager.default
    let root = try makeTemporaryScanDirectory()
    defer { try? files.removeItem(at: root) }
    let left = root.appending(path: "Originals", directoryHint: .isDirectory)
    let right = root.appending(path: "Links", directoryHint: .isDirectory)
    try files.createDirectory(at: left, withIntermediateDirectories: false)
    try files.createDirectory(at: right, withIntermediateDirectories: false)

    // The initial table grows once it reaches 64 occupied slots.
    let count = 70
    var expectedBytes: UInt64 = 0
    for index in 0..<count {
        let name = "File \(index).bin"
        let original = left.appending(path: name)
        try Data(repeating: UInt8(index), count: 4_096).write(to: original)
        try files.linkItem(at: original, to: right.appending(path: name))
        expectedBytes += try allocated(original)
    }

    let snapshot = try ScanSnapshot.scan(root, control: ScanControl(), useBulk: useBulk, workerCount: workerCount)
    #expect(snapshot.item(ScanSnapshot.root).allocated == expectedBytes)
    #expect(snapshot.item(ScanSnapshot.root).descendants == UInt32(count * 2 + 2))
    #expect(snapshot.progress.visited == UInt64(count * 2 + 2))
    #expect(snapshot.progress.skipped == 0)
    let ranked = try await snapshot.ranked(in: ScanSnapshot.root, mode: .files, limit: count * 2)
    let groupedByName = Dictionary(grouping: ranked.ids, by: snapshot.name)
    #expect(groupedByName.count == count)
    for ids in groupedByName.values {
        #expect(ids.count == 2)
        #expect(ids.count { snapshot.item($0).allocated > 0 } == 1)
    }
}

@Test(arguments: [true, false])
func parallelTraversalFindsTheSameFilesAndFoldersAsSerial(useBulk: Bool) async throws {
    let files = FileManager.default
    let root = try makeTemporaryScanDirectory()
    defer { try? files.removeItem(at: root) }

    // More siblings than the worker queue can hold, each with a nested directory.
    let folderCount = 96
    for index in 0..<folderCount {
        let folder = root.appending(path: "Folder \(index)/Nested", directoryHint: .isDirectory)
        try files.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data([7]).write(to: folder.appending(path: "File.bin"))
    }

    let serial = try ScanSnapshot.scan(root, control: ScanControl(), useBulk: useBulk, workerCount: 1)
    let parallel = try ScanSnapshot.scan(root, control: ScanControl(), useBulk: useBulk,
                                         workerCount: ScanSnapshot.maximumWorkerCount)
    #expect(parallel.progress == serial.progress)
    #expect(parallel.progress.visited == UInt64(folderCount * 3))
    #expect(parallel.item(ScanSnapshot.root).allocated == serial.item(ScanSnapshot.root).allocated)
    #expect(parallel.item(ScanSnapshot.root).descendants == UInt32(folderCount * 3))

    for mode in [Ranking.folders, .files] {
        let expected = try await serial.ranked(in: ScanSnapshot.root, mode: mode, limit: folderCount)
        let actual = try await parallel.ranked(in: ScanSnapshot.root, mode: mode, limit: folderCount)
        #expect(actual.total == folderCount)
        #expect(Set(actual.ids.map(parallel.url(for:))) == Set(expected.ids.map(serial.url(for:))))
    }
}

@Test(.enabled(if: geteuid() != 0), arguments: [true, false])
func unreadableFoldersAreSkippedWithoutLosingReadableSiblings(useBulk: Bool) async throws {
    let files = FileManager.default
    let root = try makeTemporaryScanDirectory()
    defer { try? files.removeItem(at: root) }
    let blocked = root.appending(path: "Blocked", directoryHint: .isDirectory)
    try files.createDirectory(at: blocked, withIntermediateDirectories: false)
    let blockedPath = blocked.path(percentEncoded: false)
    defer { _ = chmod(blockedPath, 0o700) }
    try Data([1]).write(to: blocked.appending(path: "Hidden.bin"))
    try Data([2]).write(to: root.appending(path: "Readable.bin"))
    let pipe = root.appending(path: "Pipe", directoryHint: .notDirectory)
    try #require(mkfifo(pipe.path(percentEncoded: false), 0o600) == 0)
    try #require(chmod(blockedPath, 0) == 0)

    let snapshot = try ScanSnapshot.scan(root, control: ScanControl(), useBulk: useBulk)
    #expect(snapshot.progress.skipped > 0)
    let contents = try await snapshot.ranked(in: ScanSnapshot.root, mode: .contents, limit: 10)
    let pipeID = try #require(contents.ids.first { snapshot.name($0) == "Pipe" })
    #expect(snapshot.item(pipeID).kind == .other)
    #expect(snapshot.item(pipeID).allocated == 0)
    let ranked = try await snapshot.ranked(in: ScanSnapshot.root, mode: .files, limit: 10)
    #expect(ranked.ids.map(snapshot.name) == ["Readable.bin"])
}

func makeTemporaryScanDirectory() throws -> URL {
    let files = FileManager.default
    let root = files.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try files.createDirectory(at: root, withIntermediateDirectories: false)
    return root
}
