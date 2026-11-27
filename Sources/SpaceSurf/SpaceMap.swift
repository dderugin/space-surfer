import ScanCore
import SwiftUI

struct SpaceMap: View {
    let snapshot: ScanSnapshot
    let ids: [UInt32]
    let selected: Set<UInt32>
    let isScanning: Bool
    let activate: (UInt32) -> Void
    let menu: (UInt32) -> ItemContextMenu
    @Environment(\.colorScheme) private var colorScheme

    static let colors: [Color] = [
        Color(red: 0.57, green: 0.77, blue: 0.68),
        Color(red: 0.75, green: 0.84, blue: 0.60),
        Color(red: 0.90, green: 0.77, blue: 0.51),
        Color(red: 0.65, green: 0.77, blue: 0.84),
        Color(red: 0.86, green: 0.69, blue: 0.60),
        Color(red: 0.77, green: 0.71, blue: 0.85),
    ]

    var body: some View {
        let items = ids.map(snapshot.item)
        let total = items.reduce(0.0) { $0 + Double($1.allocated) }
        let placeholderWeight = max(1, total / 50)
        let entries = items.enumerated().compactMap { position, item -> MapEntry? in
            guard item.allocated > 0 || isScanning else { return nil }
            return MapEntry(id: item.id, allocated: item.allocated,
                            weight: item.allocated == 0 ? placeholderWeight : Double(item.allocated),
                            color: Self.colors[position % Self.colors.count])
        }
        if entries.isEmpty {
            Text(isScanning ? "Waiting for items…" : "No allocated file space in this folder.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            GeometryReader { geometry in
                let bounds = CGRect(origin: .zero, size: geometry.size)
                let highlighted = Set(selected.compactMap { id in
                    let trail = snapshot.trail(to: id)
                    return trail.drop(while: { !ids.contains($0) }).first
                })
                ForEach(layoutTreemap(entries[...], in: bounds), id: \.entry.id) { tile in
                    tileView(tile, highlighted: highlighted.contains(tile.entry.id))
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Storage treemap")
        }
    }

    private func tileView(_ tile: MapTile, highlighted: Bool) -> some View {
        let inset = min(2, tile.frame.width / 6, tile.frame.height / 6)
        let frame = tile.frame.insetBy(dx: inset, dy: inset)
        let name = snapshot.name(tile.entry.id)
        let allocation = isScanning && tile.entry.allocated == 0 && snapshot.item(tile.entry.id).kind == .folder
            ? "Size pending" : Design.size(tile.entry.allocated)
        let cornerRadius = min(8, frame.width / 4, frame.height / 4)
        let shape = RoundedRectangle(cornerRadius: cornerRadius)
        let fill = colorScheme == .dark ? tile.entry.color.opacity(0.35) : tile.entry.color
        return Button {
            activate(tile.entry.id)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                if frame.width >= 70 && frame.height >= 42 {
                    Text(name).font(.callout.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                    Text(allocation).font(.caption).lineLimit(1).monospacedDigit()
                }
            }
            .padding(min(9, frame.width / 7, frame.height / 7))
            .frame(width: frame.width, height: frame.height, alignment: .bottomLeading)
            .foregroundStyle(colorScheme == .dark ? Color.white : Color(red: 0.12, green: 0.17, blue: 0.16))
            .background(fill, in: shape)
            .overlay { if highlighted { shape.strokeBorder(Design.accent, lineWidth: 2) } }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .itemContextMenu(menu(tile.entry.id), cornerRadius: cornerRadius)
        .accessibilityLabel("\(name), \(allocation)")
        .accessibilityHint(snapshot.item(tile.entry.id).kind == .folder ? "Focus folder" : "Select file")
        .help("\(name) · \(allocation)")
        .position(x: frame.midX, y: frame.midY)
    }
}

struct MapEntry {
    let id: UInt32
    let allocated: UInt64
    let weight: Double
    let color: Color
}

struct MapTile {
    let entry: MapEntry
    let frame: CGRect
}

func layoutTreemap(_ entries: ArraySlice<MapEntry>, in frame: CGRect) -> [MapTile] {
    guard let first = entries.first else { return [] }
    guard entries.count > 1 else { return [MapTile(entry: first, frame: frame)] }

    let total = entries.reduce(0.0) { $0 + $1.weight }
    var firstTotal = first.weight
    var split = entries.startIndex + 1
    while split < entries.endIndex - 1 && firstTotal + entries[split].weight / 2 < total / 2 {
        firstTotal += entries[split].weight
        split += 1
    }
    let axis: CGRectEdge = frame.width >= frame.height ? .minXEdge : .minYEdge
    let extent = axis == .minXEdge ? frame.width : frame.height
    let (left, right) = frame.divided(atDistance: extent * (firstTotal / total), from: axis)
    return layoutTreemap(entries[..<split], in: left) + layoutTreemap(entries[split...], in: right)
}
