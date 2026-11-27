import Foundation
@testable import ScanCore
import Testing

enum TrashDestination: CaseIterable, Sendable {
    case outsideScan, insideScan, unknown
}

@Test(arguments: TrashDestination.allCases)
func trashDestinationDeterminesWhetherTheScanNeedsRefresh(destination: TrashDestination) async throws {
    let files = FileManager.default
    let fixture = try makeTemporaryScanDirectory()
    defer { try? files.removeItem(at: fixture) }

    let root = fixture.appending(path: "Scan", directoryHint: .isDirectory)
    let trash = destination == .insideScan
        ? root.appending(path: "Trash", directoryHint: .isDirectory)
        : fixture.appending(path: "Scan backup", directoryHint: .isDirectory)
    try files.createDirectory(at: root, withIntermediateDirectories: false)
    try files.createDirectory(at: trash, withIntermediateDirectories: false)
    let payload = Data(repeating: 19, count: 8_192)
    let source = root.appending(path: "Keep recoverable.bin")
    try payload.write(to: source)
    let snapshot = try ScanSnapshot.scan(root, control: ScanControl())
    let ranked = try await snapshot.ranked(in: ScanSnapshot.root, mode: .files, limit: 1)
    let item = try snapshot.prepareRemoval(of: #require(ranked.ids.first))

    let recycled = trash.appending(path: "Recovered name.bin")
    let updated = try snapshot.remove(item, using: .trash) { original in
        #expect(original.lastPathComponent == source.lastPathComponent)
        try files.moveItem(at: original, to: recycled)
        return destination == .unknown ? nil : recycled
    }
    #expect(updated == (destination == .outsideScan))
    #expect(!files.fileExists(atPath: source.path(percentEncoded: false)))
    #expect(try Data(contentsOf: recycled) == payload)
    let expectedNames = updated ? [] : ["Keep recoverable.bin"]
    #expect(try await snapshot.ranked(in: ScanSnapshot.root, mode: .files, limit: 1).ids.map(snapshot.name) == expectedNames)
}

@Test func refusedTrashMoveKeepsTheItemAndIndex() async throws {
    let root = try makeTemporaryScanDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    let source = root.appending(path: "File.bin")
    let payload = Data([41])
    try payload.write(to: source)
    let snapshot = try ScanSnapshot.scan(root, control: ScanControl())
    let ranked = try await snapshot.ranked(in: ScanSnapshot.root, mode: .files, limit: 1)
    let item = try snapshot.prepareRemoval(of: #require(ranked.ids.first))
    #expect(throws: POSIXError(.EACCES)) {
        try snapshot.remove(item, using: .trash) { _ in throw POSIXError(.EACCES) }
    }
    #expect(try Data(contentsOf: source) == payload)
    #expect(try await snapshot.ranked(in: ScanSnapshot.root, mode: .files, limit: 1).ids == ranked.ids)
}
