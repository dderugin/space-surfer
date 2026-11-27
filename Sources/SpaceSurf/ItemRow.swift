import ScanCore
import SwiftUI

struct ItemContextMenu: View {
    let title: String
    let canRemove: Bool
    let preview: () -> Void
    let info: () -> Void
    let addToFavorites: (() -> Void)?
    let remove: (RemovalMethod) -> Void

    var body: some View {
        Section(title) {
            Button("Quick Look", action: preview)
            Button("Get Info", action: info)
            if let addToFavorites {
                Button("Add to Favorites", action: addToFavorites)
            }
            Divider()
            Button("Move to Trash") { remove(.trash) }
                .disabled(!canRemove)
            Button("Delete Permanently…", role: .destructive) { remove(.permanent) }
                .disabled(!canRemove)
        }
    }
}

struct ItemRow: View {
    let snapshot: ScanSnapshot
    let id: UInt32
    var parent: String?
    var depth = 0
    var expanded: Bool?
    let selected: Bool
    let menu: ItemContextMenu
    let action: () -> Void

    var body: some View {
        let item = snapshot.item(id)
        let name = snapshot.name(id)
        let size = Design.size(item.allocated)
        Button(action: action) {
            HStack(spacing: 7) {
                if let expanded {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .frame(width: 9)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                Image(systemName: icon(for: item.kind))
                    .frame(width: 15)
                    .foregroundStyle(item.kind == .folder ? Design.accent : .secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).lineLimit(1).truncationMode(.middle)
                    if let parent {
                        Text(parent)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                }
                Spacer(minLength: 3)
                Text(size).monospacedDigit().fixedSize()
                if item.kind == .folder && expanded == nil {
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
            }
            .padding(.vertical, 6)
            .padding(.trailing, 6)
            .padding(.leading, 6 + CGFloat(min(depth, 8)) * 14)
            .frame(minHeight: 30)
            .contentShape(Rectangle())
            .background(selected ? Design.accent.opacity(0.19) : .clear, in: RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .itemContextMenu(menu, cornerRadius: 5)
        .accessibilityLabel("\(name), \(size)")
        .accessibilityValue(expanded.map { $0 ? "Expanded" : "Collapsed" } ?? (selected ? "Selected" : ""))
        .help(parent.map { "\($0) › \(name)" } ?? name)
        Divider().padding(.leading, 6 + CGFloat(min(depth, 8)) * 14)
    }
}

func icon(for kind: ItemKind) -> String {
    switch kind {
    case .folder: "folder.fill"
    case .symbolicLink: "link"
    case .file, .other: "doc"
    }
}
