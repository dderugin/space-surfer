import ScanCore
import SwiftUI

struct OutlineRow: View {
    let snapshot: ScanSnapshot
    let id: UInt32
    let depth: Int
    let revision: UInt64
    let isScanning: Bool
    @Binding var selected: Set<UInt32>
    @Binding var expanded: Set<UInt32>
    let menu: (UInt32) -> ItemContextMenu

    var body: some View {
        let isExpanded = expanded.contains(id)
        ItemRow(snapshot: snapshot, id: id, depth: depth, expanded: isExpanded,
                selected: selected.contains(id), menu: menu(id)) {
            if isCommandClick { toggleSelection(id, in: &selected); return }
            selected = [id]
            if isExpanded { expanded.remove(id) }
            else { expanded.insert(id) }
        }
        if isExpanded {
            OutlineChildren(snapshot: snapshot, folder: id, depth: depth + 1, revision: revision,
                            isScanning: isScanning, selected: $selected, expanded: $expanded, menu: menu)
        }
    }
}

private struct OutlineChildren: View {
    let snapshot: ScanSnapshot
    let folder: UInt32
    let depth: Int
    let revision: UInt64
    let isScanning: Bool
    @Binding var selected: Set<UInt32>
    @Binding var expanded: Set<UInt32>
    let menu: (UInt32) -> ItemContextMenu
    @ViewState private var page: RankedPage?
    @ViewState private var limit = pageSize

    var body: some View {
        let request = PageRequest(limit: limit, revision: revision, isScanning: isScanning)
        return LazyVStack(alignment: .leading, spacing: 0) {
            if let page = page?.items, !page.ids.isEmpty {
                ForEach(page.ids, id: \.self) { id in
                    OutlineRow(snapshot: snapshot, id: id, depth: depth, revision: revision,
                               isScanning: isScanning, selected: $selected, expanded: $expanded, menu: menu)
                }
                if page.total > page.ids.count {
                    Button("Show More Folders") { limit += pageSize }
                        .padding(.leading, CGFloat(min(depth, 8)) * 14)
                }
            } else if let page {
                Text(page.failed ? "Folder couldn’t load." : isScanning ? "Looking for subfolders…" : "No subfolders")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, CGFloat(min(depth, 8)) * 14 + 6)
                    .padding(.vertical, 4)
            }
        }
        .task(id: request) {
            if let page = await RankedPage.load(request, from: snapshot, folder: folder, mode: .folders) {
                self.page = page
            }
        }
    }
}
