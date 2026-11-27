import ScanCore
import SwiftUI

struct SunburstMap: View {
    let snapshot: ScanSnapshot
    let folder: UInt32
    let ids: [UInt32]
    let selected: Set<UInt32>
    let revision: UInt64
    let isScanning: Bool
    let activate: (UInt32) -> Void
    let openParent: () -> Void
    let menu: (UInt32) -> ItemContextMenu

    @Environment(\.colorScheme) private var colorScheme
    @ViewState private var children: [UInt32: [UInt32]] = [:]

    var body: some View {
        let root = snapshot.item(folder)
        let inner = layoutSunburst(entries(ids), from: -90, to: 270, total: Double(root.allocated))
        let parents = inner.filter { $0.end - $0.start >= 12 && snapshot.item($0.entry.id).kind == .folder }
            .prefix(12).map(\.entry.id)
        let request = SunburstRequest(revision: revision, isScanning: isScanning, parents: parents)

        Group {
            if inner.isEmpty {
                Text(isScanning ? "Waiting for items…" : "No allocated file space in this folder.")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                chart(inner, root: root)
            }
        }
        .task(id: request) { await loadChildren(for: request.parents) }
    }

    private func chart(_ inner: [SunburstSector], root: ScanItem) -> some View {
        let outer = inner.flatMap { parent -> [SunburstSector] in
            let ids = children[parent.entry.id] ?? []
            return layoutSunburst(entries(ids, color: parent.entry.color), from: parent.start,
                                  to: parent.end, total: parent.entry.weight)
        }
        let highlighted = Set(selected.flatMap(snapshot.trail(to:)))
        return GeometryReader { geometry in
            let diameter = max(0, min(geometry.size.width, geometry.size.height) - 12)
            ZStack {
                Circle().fill(.quaternary.opacity(0.5))
                    .frame(width: diameter * 0.67, height: diameter * 0.67)
                    .accessibilityHidden(true)
                ForEach(inner) { sector in
                    sectorButton(sector, diameter: diameter, inner: 0.35, outer: 0.67,
                                 highlighted: highlighted.contains(sector.id))
                }
                ForEach(outer) { sector in
                    sectorButton(sector, diameter: diameter, inner: 0.68, outer: 1,
                                 highlighted: highlighted.contains(sector.id))
                }
                center(root, width: diameter * 0.32)
            }
            .frame(width: diameter, height: diameter)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Storage sunburst")
    }

    private func entries(_ ids: [UInt32], color: Color? = nil) -> [MapEntry] {
        let items = ids.map(snapshot.item)
        let placeholderWeight = max(1, items.reduce(0.0) { $0 + Double($1.allocated) } / 50)
        return items.enumerated().compactMap { position, item in
            guard item.allocated > 0 || isScanning else { return nil }
            return MapEntry(id: item.id, allocated: item.allocated,
                            weight: item.allocated > 0 ? Double(item.allocated) : placeholderWeight,
                            color: color ?? SpaceMap.colors[position % SpaceMap.colors.count])
        }
    }

    private func center(_ root: ScanItem, width: CGFloat) -> some View {
        VStack(spacing: 3) {
            Text(folder == ScanSnapshot.root ? Design.scanName(snapshot.url) : snapshot.name(folder))
                .font(.caption.weight(.semibold)).lineLimit(1).truncationMode(.middle)
            Text(Design.size(root.allocated)).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            if root.parent != nil {
                Button("Up one level", systemImage: "arrow.up", action: openParent)
                    .labelStyle(.iconOnly).buttonStyle(.borderless).help("Up one level")
            }
        }
        .frame(width: max(0, width - 8))
    }

    private func sectorButton(_ sector: SunburstSector, diameter: CGFloat, inner: CGFloat, outer: CGFloat,
                              highlighted: Bool) -> some View {
        let shape = SunburstWedge(start: sector.start, end: sector.end, inner: inner, outer: outer)
        let name = snapshot.name(sector.id)
        let isFolder = snapshot.item(sector.id).kind == .folder
        let size = isFolder && isScanning && sector.entry.allocated == 0 ? "Size pending" : Design.size(sector.entry.allocated)
        let opacity = colorScheme == .dark ? (outer == 1 ? 0.38 : 0.58) : (outer == 1 ? 0.67 : 0.92)
        return Button { activate(sector.id) } label: {
            shape.fill(sector.entry.color.opacity(opacity))
                .overlay { if highlighted { shape.stroke(.primary, lineWidth: 2).clipShape(shape) } }
                .overlay { sectorLabel(name, sector: sector, diameter: diameter, radius: diameter * (inner + outer) / 4) }
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .contextMenu { menu(sector.id) }
        .accessibilityLabel("\(name), \(size)")
        .accessibilityHint(isFolder ? "Focus folder" : "Select file")
        .help("\(name) · \(size)")
    }

    @ViewBuilder private func sectorLabel(_ name: String, sector: SunburstSector, diameter: CGFloat, radius: CGFloat) -> some View {
        let span = CGFloat((sector.end - sector.start) * Double.pi / 180)
        let width = min(diameter * 0.24, radius * span - 12)
        if width >= 48, diameter > 230 {
            let angle = (sector.start + sector.end) * Double.pi / 360
            let x: CGFloat = diameter / 2 + CGFloat(cos(angle)) * radius
            let y: CGFloat = diameter / 2 + CGFloat(sin(angle)) * radius
            Text(name)
                .font(.caption.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                .foregroundStyle(colorScheme == .dark ? Color.white : Color.black.opacity(0.84))
                .frame(width: width).position(x: x, y: y)
                .allowsHitTesting(false)
        }
    }

    private func loadChildren(for parents: [UInt32]) async {
        var next: [UInt32: [UInt32]] = [:]
        for parent in parents {
            guard let page = try? await snapshot.ranked(in: parent, mode: .contents, limit: 6),
                  !Task.isCancelled else { return }
            next[parent] = page.ids
        }
        if !Task.isCancelled { children = next }
    }
}

private struct SunburstRequest: Equatable {
    let revision: UInt64
    let isScanning: Bool
    let parents: [UInt32]
}

struct SunburstSector: Identifiable {
    let entry: MapEntry
    let start: Double
    let end: Double
    var id: UInt32 { entry.id }
}

func layoutSunburst(_ entries: [MapEntry], from start: Double, to end: Double, total: Double) -> [SunburstSector] {
    let denominator = max(total, entries.reduce(0) { $0 + $1.weight })
    guard denominator > 0, end > start else { return [] }
    var angle = start
    return entries.map { entry in
        let next = min(end, angle + (end - start) * entry.weight / denominator)
        let sector = SunburstSector(entry: entry, start: angle, end: next)
        angle = next
        return sector
    }
}

private struct SunburstWedge: Shape {
    let start: Double
    let end: Double
    let inner: CGFloat
    let outer: CGFloat

    func path(in rect: CGRect) -> Path {
        let radius = min(rect.width, rect.height) / 2
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let gap = min(0.7, (end - start) / 4)
        let leading = Angle.degrees(start + gap)
        let trailing = Angle.degrees(end - gap)
        return Path { path in
            path.addArc(center: center, radius: radius * outer, startAngle: leading, endAngle: trailing, clockwise: false)
            path.addArc(center: center, radius: radius * inner, startAngle: trailing, endAngle: leading, clockwise: true)
            path.closeSubpath()
        }
    }
}
