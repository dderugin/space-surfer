import ScanCore
import SwiftUI

enum FileView: String, CaseIterable, Identifiable {
    case contents = "Contents"
    case outline = "Folders Outline"
    case biggest = "Biggest Files"

    var id: Self { self }
}

struct FolderPanels: View {
    let snapshot: ScanSnapshot
    let folder: UInt32
    let revision: UInt64
    let isScanning: Bool
    @Binding var selected: Set<UInt32>
    @Binding var mode: FileView
    @Binding var mapMode: SpaceMapMode
    let query: String
    let removal: UUID?
    let selectMatch: (UInt32) -> Void
    let navigate: (UInt32) -> Void
    let clearFolder: () -> Void
    let openParent: () -> Void
    let menu: (UInt32) -> ItemContextMenu

    @ViewState private var direct: RankedPage?
    @ViewState private var folders: RankedPage?
    @ViewState private var biggest: RankedPage?
    @ViewState private var directLimit = pageSize
    @ViewState private var foldersLimit = pageSize
    @ViewState private var biggestLimit = pageSize
    @ViewState private var expanded: Set<UInt32> = []

    private var directRequest: PageRequest {
        PageRequest(limit: directLimit, revision: revision, isScanning: isScanning)
    }

    private var browserRequest: PageRequest? {
        guard query.isEmpty, mode != .contents else { return nil }
        return PageRequest(limit: mode == .outline ? foldersLimit : biggestLimit, revision: revision, isScanning: isScanning)
    }

    var body: some View {
        let directRequest = directRequest
        let browserRequest = BrowserRequest(mode: mode, page: browserRequest)
        return HSplitView {
            mapPanel
                .frame(minWidth: 290, idealWidth: 550, maxWidth: .infinity, maxHeight: .infinity)
            browserPanel
                .frame(minWidth: 335, idealWidth: 390, maxWidth: .infinity, maxHeight: .infinity)
        }
        .task(id: directRequest) {
            if let page = await RankedPage.load(directRequest, from: snapshot, folder: folder, mode: .contents) {
                direct = page
            }
        }
        .task(id: browserRequest) {
            guard let request = browserRequest.page else { return }
            let outline = browserRequest.mode == .outline
            let cached = outline ? folders : biggest
            if let cached, cached.request == request, !cached.failed { return }
            guard let page = await RankedPage.load(request, from: snapshot, folder: folder,
                                                   mode: outline ? .folders : .files) else { return }
            if outline { folders = page } else { biggest = page }
        }
    }

    private var mapPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Picker("Space map", selection: $mapMode) {
                    ForEach(SpaceMapMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()
                if folder != ScanSnapshot.root {
                    Button(action: clearFolder) {
                        Label {
                            Text(snapshot.name(folder)).lineLimit(1)
                        } icon: {
                            Image(systemName: "xmark.circle.fill")
                        }
                    }
                    .controlSize(.small)
                    .accessibilityLabel("Clear \(snapshot.name(folder)) folder focus")
                    .help("Return to All Folders")
                }
                Spacer(minLength: 0)
            }
            .frame(height: 24)
            if direct?.failed == true {
                emptyMessage("Space map couldn’t load.")
            } else if let direct = direct?.items {
                let ids = Array(direct.ids.prefix(36))
                switch mapMode {
                case .treemap:
                    SpaceMap(snapshot: snapshot, ids: ids, selected: selected,
                             isScanning: isScanning, activate: navigate, menu: menu)
                case .sunburst:
                    SunburstMap(snapshot: snapshot, folder: folder, ids: ids, selected: selected, revision: revision,
                                isScanning: isScanning, activate: navigate, openParent: openParent, menu: menu)
                }
                if direct.total > 36 {
                    Text("Largest 36 items")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(8)
    }

    private var browserPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Group {
                if query.isEmpty {
                    Picker("File view", selection: $mode) {
                        ForEach(FileView.allCases) { view in Text(view.rawValue).tag(view) }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                } else {
                    HStack {
                        Text("Search Results").fontWeight(.semibold)
                        Spacer()
                        Text("Entire scan").foregroundStyle(.secondary)
                    }
                    .font(.callout)
                }
            }
            .frame(height: 24)

            Divider()
            if query.isEmpty {
                browserContents
            } else {
                FilenameSearch(snapshot: snapshot, query: query, selected: selected, select: selectMatch, menu: menu)
                    .id(SearchIdentity(query: query, removal: removal))
            }
        }
        .padding(8)
    }

    @ViewBuilder private var browserContents: some View {
        let page = switch mode {
        case .contents: direct
        case .outline: folders
        case .biggest: biggest
        }
        if page?.failed == true {
            emptyMessage("Files couldn’t load.")
        } else if let items = page?.items, items.ids.isEmpty {
            let message = switch mode {
            case .contents: isScanning ? "Waiting for items…" : "This folder is empty."
            case .outline: isScanning ? "Looking for folders…" : "No subfolders."
            case .biggest: isScanning ? "Looking for files…" : "No files in this folder."
            }
            emptyMessage(message)
        } else if let items = page?.items {
            fileList(items).id(mode)
        } else {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func fileList(_ page: RankedItems) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if mode == .biggest, selected.count == 1, let selected = selected.first,
                       snapshot.item(selected).kind == .file, !page.ids.contains(selected) {
                        Text("Selected file")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                        row(selected)
                    }
                    ForEach(page.ids, id: \.self) { id in
                        if mode == .outline {
                            OutlineRow(snapshot: snapshot, id: id, depth: 0, revision: revision,
                                       isScanning: isScanning, selected: $selected, expanded: $expanded, menu: menu)
                                .id(id)
                        } else {
                            row(id).id(id)
                        }
                    }
                    if page.total > page.ids.count {
                        Button(mode == .biggest ? "Show More Files" : mode == .outline ? "Show More Folders" : "Show More Items") {
                            switch mode {
                            case .contents: directLimit += pageSize
                            case .outline: foldersLimit += pageSize
                            case .biggest: biggestLimit += pageSize
                            }
                        }
                        .padding(6)
                    }
                }
            }
            .onChange(of: selected) { _, ids in
                if ids.count == 1, let id = ids.first, page.ids.contains(id) { proxy.scrollTo(id) }
            }
            .onAppear {
                if selected.count == 1, let id = selected.first, page.ids.contains(id) { proxy.scrollTo(id) }
            }
        }
    }

    private func row(_ id: UInt32) -> some View {
        ItemRow(snapshot: snapshot, id: id, parent: mode == .biggest ? parentPath(id) : nil,
                selected: selected.contains(id), menu: menu(id), action: { navigate(id) })
    }

    private func parentPath(_ id: UInt32) -> String {
        snapshot.trail(to: id).drop(while: { $0 != folder }).dropLast().map(snapshot.name).joined(separator: " › ")
    }
}

enum SpaceMapMode: String, CaseIterable {
    case treemap = "Treemap"
    case sunburst = "Sunburst"
}

private struct SearchIdentity: Hashable {
    let query: String
    let removal: UUID?
}

private struct BrowserRequest: Equatable {
    let mode: FileView
    let page: PageRequest?
}

private func emptyMessage(_ text: String) -> some View {
    Text(text)
        .font(.callout)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
}
