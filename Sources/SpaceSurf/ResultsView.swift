import AppKit
import QuickLook
import ScanCore
import SwiftUI

struct ResultsView: View {
    let snapshot: ScanSnapshot
    let revision: UInt64
    let isScanning: Bool
    let canRemove: Bool
    let removalChange: RemovalChange?
    let removeItem: (Set<UInt32>, RemovalMethod) -> Void
    let favoritePaths: Set<String>
    let addFavorite: (URL) -> Void
    @Binding var searchText: String
    @FocusState.Binding var searchFocused: Bool
    @ViewState private var folder = ScanSnapshot.root
    @ViewState private var selected: Set<UInt32> = []
    @ViewState private var infoError: String?
    @ViewState private var mode = FileView.contents
    @AppStorage("spaceMapMode") private var mapMode = SpaceMapMode.treemap
    @ViewState private var previewItem: URL?
    @ViewState private var previewItems: [URL] = []

    private var trail: [UInt32] { snapshot.trail(to: folder) }
    private var targets: Set<UInt32> { selected.isEmpty ? [folder] : selected }
    private var target: UInt32 { selected.count == 1 ? selected.first ?? folder : folder }

    var body: some View {
        let canRemoveSelection = canRemove && isRemovable(selected)
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 22)
                .padding(.vertical, 16)
            FolderPanels(snapshot: snapshot, folder: folder, revision: revision, isScanning: isScanning,
                         selected: $selected, mode: $mode, mapMode: $mapMode,
                         query: query, removal: removalChange?.id, selectMatch: selectMatch,
                         navigate: navigate, clearFolder: clearFolder, openParent: openParent,
                         menu: { menu(for: $0, canRemoveSelection: canRemoveSelection) })
                .id(PanelIdentity(folder: folder, removal: removalChange?.id))
                .padding(.horizontal, 14)
            Divider()
            inspector
        }
        .background {
            PreviewShortcut {
                guard !searchFocused, !selected.isEmpty else { return false }
                if previewItem != nil { previewItem = nil } else { showPreview(selected) }
                return true
            }
        }
        .quickLookPreview($previewItem, in: previewItems)
        .onExitCommand {
            if !searchText.isEmpty || searchFocused {
                searchText = ""
                searchFocused = false
            } else if folder != ScanSnapshot.root {
                clearFolder()
            } else {
                selected.removeAll()
            }
        }
        .onChange(of: removalChange) { _, change in
            guard let change else { return }
            if let parent = snapshot.trail(to: folder).compactMap({ change.removed[$0] }).first { folder = parent }
            selected = selected.filter { id in snapshot.trail(to: id).allSatisfy { change.removed[$0] == nil } }
        }
        .alert("Couldn’t open Finder Info", isPresented: Binding(
            get: { infoError != nil }, set: { if !$0 { infoError = nil } }
        )) {
            Button("OK") { infoError = nil }
        } message: {
            Text(infoError ?? "")
        }
    }

    private var header: some View {
        let item = snapshot.item(folder)
        return HStack(alignment: .bottom, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                if folder != ScanSnapshot.root {
                    ScrollView(.horizontal) {
                        HStack(spacing: 6) {
                            ForEach(trail.dropLast(), id: \.self) { ancestor in
                                Button(ancestor == ScanSnapshot.root ? "All Folders" : snapshot.name(ancestor)) {
                                    openFolder(ancestor)
                                }
                                .buttonStyle(.link)
                                Image(systemName: "chevron.right")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                    .accessibilityHidden(true)
                            }
                        }
                    }
                    .scrollIndicators(.hidden)
                    .font(.callout)
                }
                Text(folder == ScanSnapshot.root ? Design.scanName(snapshot.url) : snapshot.name(folder))
                    .font(.system(size: 33, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(item.descendants.formatted()) items")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text(Design.size(item.allocated))
                    .font(.system(size: 29, weight: .semibold))
                    .monospacedDigit()
                Text("Allocated file size")
                    .foregroundStyle(.secondary)
            }
            .fixedSize()
        }
    }

    private var inspector: some View {
        let kind = snapshot.item(target).kind
        let url = snapshot.url(for: target)
        let path = url.path(percentEncoded: false)
        return HStack(spacing: 10) {
            Image(systemName: icon(for: kind))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(selected.count > 1 ? "\(selected.count) items selected" : path)
                .lineLimit(1)
                .truncationMode(.middle)
                .font(.callout)
                .foregroundStyle(.secondary)
                .help(selected.count > 1 ? "Selected files and folders" : path)
                .textSelection(.enabled)
            Spacer()
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(targets.sorted().map(snapshot.url(for:))) }
            if isRemovable(targets) {
                Menu("Remove", systemImage: "trash") {
                    Button("Move to Trash") { removeItem(targets, .trash) }
                    Button("Delete Permanently…", role: .destructive) { removeItem(targets, .permanent) }
                }
                .fixedSize()
                .disabled(!canRemove)
                .help(isScanning ? "Stop the scan or wait for it to finish to remove items." : "Remove the selected item")
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 9)
    }

    private func isRemovable(_ items: Set<UInt32>) -> Bool {
        !items.contains(ScanSnapshot.root) && items.allSatisfy { snapshot.item($0).kind != .other }
    }

    private func menu(for id: UInt32, canRemoveSelection: Bool) -> ItemContextMenu {
        let isSelected = selected.contains(id)
        let items: Set<UInt32> = isSelected ? selected : [id]
        let canRemoveItems = isSelected ? canRemoveSelection : canRemove && isRemovable(items)
        let title = items.count == 1 ? snapshot.name(id) : "\(items.count.formatted()) Selected Items"
        return ItemContextMenu(title: title, canRemove: canRemoveItems,
                               preview: { showPreview(items, startingAt: id) },
                               info: { infoError = FinderInfo.show(items.sorted().map(snapshot.url(for:))) },
                               addToFavorites: items.count == 1 ? favoriteAction(for: id) : nil,
                               remove: { removeItem(items, $0) })
    }

    private func favoriteAction(for id: UInt32) -> (() -> Void)? {
        guard snapshot.item(id).kind == .folder else { return nil }
        let url = snapshot.url(for: id)
        guard !favoritePaths.contains(url.standardizedFileURL.path(percentEncoded: false)) else { return nil }
        return { addFavorite(url) }
    }

    private func showPreview(_ ids: Set<UInt32>, startingAt id: UInt32? = nil) {
        previewItems = ids.sorted().map(snapshot.url(for:))
        previewItem = id.map(snapshot.url(for:)) ?? previewItems.first
    }

    private func selectMatch(_ id: UInt32) {
        searchFocused = false
        if isCommandClick { toggleSelection(id, in: &selected) } else { selected = [id] }
    }

    private func navigate(_ id: UInt32) {
        searchFocused = false
        if isCommandClick {
            toggleSelection(id, in: &selected)
        } else if snapshot.item(id).kind == .folder {
            openFolder(id)
        } else {
            selected = [id]
        }
    }

    private func openFolder(_ id: UInt32) {
        searchFocused = false
        folder = id
        selected.removeAll()
    }

    private func clearFolder() { openFolder(ScanSnapshot.root) }

    private func openParent() {
        if let parent = snapshot.item(folder).parent { openFolder(parent) }
    }
}

private struct PanelIdentity: Hashable {
    let folder: UInt32
    let removal: UUID?
}

@MainActor var isCommandClick: Bool { NSApp.currentEvent?.modifierFlags.contains(.command) == true }

func toggleSelection(_ id: UInt32, in selection: inout Set<UInt32>) {
    if !selection.insert(id).inserted { selection.remove(id) }
}
