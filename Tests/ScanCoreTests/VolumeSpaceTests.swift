import Foundation
@testable import ScanCore
import Testing

@Test func volumeSpaceComparesOnlyCompletedWholeVolumeScans() {
    let whole = VolumeSpace(total: 1_000, free: 250, isWholeVolume: true, sharesAPFSSpace: false)
    #expect(whole.used == 750)
    #expect(whole.unaccountedBytes(scannedBytes: nil) == nil)
    #expect(whole.unaccountedBytes(scannedBytes: 500) == 250)
    #expect(whole.unaccountedBytes(scannedBytes: 0) == 750)
    #expect(whole.unaccountedBytes(scannedBytes: 800) == 0)

    let folder = VolumeSpace(total: 1_000, free: 250, isWholeVolume: false, sharesAPFSSpace: false)
    #expect(folder.unaccountedBytes(scannedBytes: 500) == nil)
}

@Test func capacityIsReadableBeforeTraversalAndDistinguishesMountRootFromFolder() throws {
    let folder = try makeTemporaryScanDirectory()
    defer { try? FileManager.default.removeItem(at: folder) }
    let snapshot = try ScanSnapshot(folder, control: ScanControl())
    let space = try #require(snapshot.readVolumeSpace())
    #expect(!space.isWholeVolume)
    #expect(space.total > 0 && space.used + space.free == space.total)
    #expect(snapshot.progress.visited == 0)

    let startup = try #require(VolumeSpace.read(for: URL(filePath: "/", directoryHint: .isDirectory)))
    #expect(startup.isWholeVolume)
    #expect(startup.total > 0 && startup.used + startup.free == startup.total)
}
