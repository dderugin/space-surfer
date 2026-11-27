import Foundation
import ScanCore
@testable import SpaceSurf
import Testing

@MainActor
@Test func scanSessionKeepsConfirmationAndRemovalInSync() async throws {
    let root = try makeSessionFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appending(path: "Selected.bin")
    let contents = Data([3, 1, 4])
    try contents.write(to: file)

    let session = ScanSession()
    session.scan(root)
    #expect(session.source == root)
    #expect(!session.canStartScan)
    #expect(session.isReadingVolume)
    #expect(session.completedScanBytes == nil)
    try await waitForState { session.source == nil }
    let snapshot = try #require(session.result)
    #expect(session.elapsed != nil)
    #expect(session.scanned == 1)
    let page = try await snapshot.ranked(in: ScanSnapshot.root, mode: .contents, limit: 1)
    let id = try #require(page.ids.first)
    try await waitForState { !session.isReadingVolume }
    #expect(session.completedScanBytes == snapshot.item(id).allocated)
    #expect(session.volumeSpace?.isWholeVolume == false)

    session.requestRemoval([id], using: .permanent)
    try await waitForState { !session.isRemoving }
    let dismissed = try #require(session.permanentRemoval)
    #expect(dismissed.targets.map(\.id) == [id])
    #expect(!session.canStartScan)
    session.dismissRemovalConfirmation()
    #expect(session.canStartScan)
    #expect(try Data(contentsOf: file) == contents)

    session.requestRemoval([id], using: .permanent)
    try await waitForState { !session.isRemoving }
    let current = try #require(session.permanentRemoval)
    session.confirmRemoval(dismissed)
    #expect(session.permanentRemoval?.id == current.id)
    session.confirmRemoval(current)
    try await waitForState { session.canStartScan }
    #expect(session.removalChange?.removed == [id: ScanSnapshot.root])
    #expect(snapshot.item(ScanSnapshot.root).descendants == 0)
    #expect(session.removalFailure == nil)
    #expect(!FileManager.default.fileExists(atPath: file.path(percentEncoded: false)))
}

@MainActor
@Test func rescanningReleasesCompletedAndCancelledSnapshots() async throws {
    let root = try makeSessionFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    try Data([1]).write(to: root.appending(path: "Example.bin"))
    let session = ScanSession()

    session.scan(root)
    weak var completed = session.result
    try await waitForState { session.canStartScan }
    #expect(completed != nil)

    session.scan(root)
    weak var cancelled = session.result
    session.cancel()
    try await waitForState { session.canStartScan && completed == nil }
    #expect(cancelled != nil)

    session.scan(root)
    try await waitForState { session.canStartScan && cancelled == nil }
}

@MainActor
@Test func stoppingScanLeavesABrowseableSnapshot() async throws {
    let root = try makeSessionFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    try Data([1]).write(to: root.appending(path: "Example.bin"))

    let session = ScanSession()
    session.scan(root)
    let snapshot = try #require(session.result)
    // Stop before the main actor can start the traversal task.
    session.cancel()
    #expect(session.isStopping)
    try await waitForState { session.canStartScan }
    #expect(session.stoppedEarly)
    #expect(session.completedScanBytes == nil)
    #expect(!session.isStopping)
    #expect(session.failure == nil)
    #expect(session.result === snapshot)
    #expect(try await snapshot.ranked(in: ScanSnapshot.root, mode: .contents, limit: 1).ids.isEmpty)
}

@Test func rankedPageCarriesItsRequestAndDropsCancelledResults() async throws {
    let root = try makeSessionFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    try Data([1]).write(to: root.appending(path: "Example.bin"))
    let snapshot = try ScanSnapshot.scan(root, control: ScanControl())
    let request = PageRequest(limit: 1, revision: 1, isScanning: false)
    let page = try #require(await RankedPage.load(request, from: snapshot, folder: ScanSnapshot.root, mode: .files))
    #expect(page.request == request)
    #expect(page.items?.ids.map(snapshot.name) == ["Example.bin"])
    #expect(!page.failed)

    let task = Task.detached {
        withUnsafeCurrentTask { $0?.cancel() }
        return await RankedPage.load(request, from: snapshot, folder: ScanSnapshot.root, mode: .files)
    }
    #expect(await task.value == nil)
}

private func makeSessionFixture() throws -> URL {
    let files = FileManager.default
    let root = files.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try files.createDirectory(at: root, withIntermediateDirectories: false)
    return root
}

@MainActor
private func waitForState(_ isReady: () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while !isReady(), ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    try #require(isReady(), "The session did not reach the expected state")
}
