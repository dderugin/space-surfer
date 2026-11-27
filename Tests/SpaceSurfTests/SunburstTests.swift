@testable import SpaceSurf
import Testing

@Test func sunburstSectorsAreProportionalAndStayInsideTheirParent() {
    let entries = [MapEntry(id: 1, allocated: 50, weight: 50, color: .blue),
                   MapEntry(id: 2, allocated: 25, weight: 25, color: .green)]
    let sectors = layoutSunburst(entries, from: 0, to: 180, total: 100)
    #expect(sectors.map(\.id) == [1, 2])
    #expect(sectors.map(\.start) == [0, 90])
    #expect(sectors.map(\.end) == [90, 135])
    #expect(layoutSunburst(entries, from: 0, to: 180, total: 40).last?.end == 180)
    #expect(layoutSunburst([], from: 0, to: 180, total: 0).isEmpty)
}
