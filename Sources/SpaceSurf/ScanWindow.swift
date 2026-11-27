import ScanCore
import SwiftUI

struct ScanWindow: View {
    @ViewState private var session = ScanSession()
    @ViewState private var searchText = ""
    @AppStorage("showsScanSources") private var showsSidebar = true
    @AppStorage("favoriteFolderPaths") private var favoriteData = Data()
    @FocusState private var searchFocused: Bool

    private var favorites: [String] {
        (try? JSONDecoder().decode([String].self, from: favoriteData)) ?? []
    }

    var body: some View {
        HStack(spacing: 0) {
            if showsSidebar {
                ScanSourcesSidebar(session: session, favorites: favorites, addFavorite: addFavorite,
                                   removeFavorite: { path in saveFavorites(favorites.filter { $0 != path }) })
                    .frame(width: 185)
                Divider()
            }
            scanContent.frame(minWidth: 680)
        }
        .focusedSceneValue(\.focusFilenameSearch, session.result == nil ? nil : { searchFocused = true })
        .onDisappear(perform: session.cancel)
        .onChange(of: session.result.map(ObjectIdentifier.init)) {
            searchText = ""
            searchFocused = false
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button(showsSidebar ? "Hide Sidebar" : "Show Sidebar", systemImage: "sidebar.left") {
                    showsSidebar.toggle()
                }
                .labelStyle(.iconOnly)
                .help(showsSidebar ? "Hide Sidebar" : "Show Sidebar")
                .keyboardShortcut("s", modifiers: [.command, .control])
            }
            ToolbarItemGroup(placement: .primaryAction) {
                scanButtons(openShortcut: KeyboardShortcut("o", modifiers: .command))
                    .controlSize(.regular)
            }
        }
        .scanAlerts(for: session)
    }

    private var scanContent: some View {
        VStack(spacing: 0) {
            if let result = session.result {
                VolumeSpaceSummary(space: session.volumeSpace, isLoading: session.isReadingVolume,
                                   completedScanBytes: session.completedScanBytes)
                scanControls(skipped: result.progress.skipped)
                ResultsView(snapshot: result, revision: session.scanned, isScanning: session.source != nil,
                            canRemove: session.canStartScan,
                            removalChange: session.removalChange, removeItem: session.requestRemoval,
                            favoritePaths: Set(favorites), addFavorite: addFavorite,
                            searchText: $searchText, searchFocused: $searchFocused)
                    .id(ObjectIdentifier(result))
            } else {
                emptyState
            }
        }
    }

    private func addFavorite(_ url: URL) {
        let path = url.standardizedFileURL.path(percentEncoded: false)
        let current = favorites
        guard !current.contains(path) else { return }
        saveFavorites(current + [path])
    }

    private func saveFavorites(_ paths: [String]) {
        if let data = try? JSONEncoder().encode(paths) { favoriteData = data }
    }
}

private extension View {
    @MainActor func scanAlerts(for session: ScanSession) -> some View {
        self
        .alert("Scan couldn’t finish", isPresented: Binding(
            get: { session.failure != nil },
            set: { if !$0 { session.failure = nil } }
        )) {
            Button("OK") { session.failure = nil }
        } message: {
            Text(session.failure ?? "")
        }
        .alert("Delete permanently?", isPresented: Binding(
            get: { session.permanentRemoval != nil },
            set: { if !$0 { session.dismissRemovalConfirmation() } }
        ), presenting: session.permanentRemoval) { batch in
            Button("Cancel", role: .cancel, action: session.dismissRemovalConfirmation)
            Button("Delete Permanently", role: .destructive) { session.confirmRemoval(batch) }
        } message: { batch in
            if let target = batch.targets.first, batch.targets.count == 1 {
                let item = target.kind == .folder ? "“\(target.name)” and all its contents" : "“\(target.name)”"
                Text("Permanently delete \(item)?\n\n\(target.url.path(percentEncoded: false))")
            } else {
                let names = batch.targets.prefix(5).map(\.name).joined(separator: "\n")
                let more = batch.targets.count > 5 ? "\nAnd \(batch.targets.count - 5) more" : ""
                Text("Permanently delete \(batch.targets.count) items, including the contents of selected folders?\n\n\(names)\(more)")
            }
        }
        .alert("Couldn’t remove item", isPresented: Binding(
            get: { session.removalFailure != nil },
            set: { if !$0 { session.removalFailure = nil } }
        )) {
            Button("OK") { session.removalFailure = nil }
        } message: {
            Text(session.removalFailure ?? "")
        }
    }
}

private extension ScanWindow {
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: "square.grid.2x2.fill")
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(Design.accent)
                .accessibilityHidden(true)
            Text("See what takes up space")
                .font(.largeTitle.weight(.semibold))
            Text("Scan the startup drive, your home folder, or a folder you choose.")
                .foregroundStyle(.secondary)
            HStack(spacing: 8) { scanButtons() }
                .controlSize(.large)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func scanButtons(openShortcut: KeyboardShortcut? = nil) -> some View {
        Group {
            Button("Scan Macintosh HD", systemImage: "internaldrive", action: session.scanStartupDisk)
                .buttonStyle(ScanSourceButtonStyle(prominent: true))
            Button("Scan Home Folder", systemImage: "house", action: session.scanHomeFolder)
                .buttonStyle(ScanSourceButtonStyle())
            Button("Scan Folder…", systemImage: "folder", action: session.chooseFolder)
                .buttonStyle(ScanSourceButtonStyle())
                .keyboardShortcut(openShortcut)
        }
        .disabled(!session.canStartScan)
    }

    private func scanControls(skipped: UInt64) -> some View {
        HStack(spacing: 10) {
            if let source = session.source {
                scanProgress(source, skipped: skipped)
            } else {
                scanSummary(skipped: skipped)
            }
            Spacer(minLength: 10)
            searchField
        }
        .padding(.horizontal, 22)
        .frame(height: 44)
        .background(session.source == nil ? Color.clear : Design.accent.opacity(0.10))
    }

    @ViewBuilder private func scanProgress(_ source: URL, skipped: UInt64) -> some View {
        ProgressView().controlSize(.small).accessibilityLabel("Reading file metadata")
        Text(session.isStopping ? "Stopping scan" : "Scanning \(Design.scanName(source))")
            .fontWeight(.medium)
            .lineLimit(1)
        ViewThatFits(in: .horizontal) {
            scanCounts(skipped: skipped)
            scanCounts(skipped: 0)
        }
        Button("Stop Scan", action: session.cancel)
            .fixedSize()
            .disabled(session.isStopping)
    }

    private func scanCounts(skipped: UInt64) -> some View {
        HStack(spacing: 7) {
            Text("\(session.scanned.formatted()) items scanned")
            if skipped > 0 { skippedCount(skipped) }
        }
        .foregroundStyle(.secondary)
        .monospacedDigit()
        .fixedSize()
    }

    @ViewBuilder private func scanSummary(skipped: UInt64) -> some View {
        Group {
            if session.isRemoving {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Working…")
                }
            } else if let change = session.removalChange {
                Label(change.method == .trash ? "Moved to Trash" : "Deleted permanently", systemImage: "checkmark.circle")
            } else if session.stoppedEarly {
                Label("Scan stopped · Partial results", systemImage: "stop.circle")
            } else {
                Label("Scan complete", systemImage: "checkmark.circle")
            }
        }
        .fontWeight(.medium)
        .lineLimit(1)
        if skipped > 0 { skippedCount(skipped).lineLimit(1) }
        if let elapsed = session.elapsed {
            Text(elapsed.formatted(.units(allowed: [.seconds], fractionalPart: .show(length: 2))))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
        }
    }

    private func skippedCount(_ skipped: UInt64) -> some View {
        Text("· \(skipped.formatted()) skipped")
            .foregroundStyle(.secondary)
            .help("Some entries could not be read, required a download, or were on another mounted volume.")
    }

    private var searchField: some View {
        let isEmpty = searchText.isEmpty
        let shape = RoundedRectangle(cornerRadius: 7)
        return HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Search filenames", text: $searchText)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .onExitCommand {
                    searchText = ""
                    searchFocused = false
                }
            Button("Clear Search", systemImage: "xmark.circle.fill") {
                searchText = ""
                searchFocused = true
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .opacity(isEmpty ? 0 : 1)
            .disabled(isEmpty)
            .accessibilityHidden(isEmpty)
        }
        .font(.callout)
        .padding(.horizontal, 8)
        .frame(width: 230, height: 28)
        .background(.background, in: shape)
        .overlay {
            shape.strokeBorder(searchFocused ? Color.accentColor : Color.primary.opacity(0.14),
                               lineWidth: searchFocused ? 2 : 1)
                .allowsHitTesting(false)
        }
        .help("Search filenames in the current scan (⌘F)")
    }
}
