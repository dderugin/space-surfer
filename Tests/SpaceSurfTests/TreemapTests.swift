import CoreGraphics
@testable import SpaceSurf
import SwiftUI
import Testing

@Test(arguments: [CGSize(width: 320, height: 100), CGSize(width: 100, height: 320)])
func treemapUsesAllocatedWeightsWithoutOverlapping(size: CGSize) {
    let entries = [19, 14, 9, 6, 2].enumerated().map { index, weight in
        MapEntry(id: UInt32(index), allocated: UInt64(weight), weight: Double(weight), color: .blue)
    }
    let bounds = CGRect(origin: CGPoint(x: 10, y: 20), size: size)
    let tiles = layoutTreemap(entries[...], in: bounds)
    #expect(tiles.map(\.entry.id) == entries.map(\.id))

    let area = bounds.width * bounds.height
    let totalWeight = entries.reduce(0.0) { $0 + $1.weight }
    for (index, tile) in tiles.enumerated() {
        #expect(bounds.insetBy(dx: -0.001, dy: -0.001).contains(tile.frame))
        #expect(abs(tile.frame.width * tile.frame.height - area * tile.entry.weight / totalWeight) < 0.001)
        for other in tiles.dropFirst(index + 1) {
            let overlap = tile.frame.intersection(other.frame)
            #expect(overlap.isNull || overlap.width * overlap.height < 0.001)
        }
    }
}

@Test func treemapHandlesEmptyAndSingleItemInputs() throws {
    let bounds = CGRect(x: 5, y: 9, width: 88, height: 44)
    #expect(layoutTreemap([], in: bounds).isEmpty)
    let entry = MapEntry(id: 42, allocated: 0, weight: 1, color: .blue)
    let tile = try #require(layoutTreemap([entry], in: bounds).first)
    #expect(tile.entry.id == entry.id)
    #expect(tile.frame == bounds)
}
