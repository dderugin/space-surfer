import ScanCore
import SwiftUI

struct FilenameSearch: View {
    let snapshot: ScanSnapshot
    let query: String
    let selected: Set<UInt32>
    let select: (UInt32) -> Void
    let menu: (UInt32) -> ItemContextMenu

    @ViewState private var ids: [UInt32] = []
    @ViewState private var cursor: UInt32 = 1
    @ViewState private var limit = pageSize
    @ViewState private var hasSearched = false
    @ViewState private var complete = false
    @ViewState private var failed = false

    var body: some View {
        Group {
            if failed {
                ContentUnavailableView("Search couldn’t finish", systemImage: "exclamationmark.magnifyingglass")
            } else if ids.isEmpty {
                if complete {
                    ContentUnavailableView("No matches", systemImage: "magnifyingglass")
                } else if hasSearched {
                    ContentUnavailableView("No matches yet", systemImage: "magnifyingglass",
                                           description: Text("New matches will appear as the scan continues."))
                } else {
                    ProgressView("Searching…")
                }
            } else {
                resultList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: limit) { await loadMatches() }
    }

    private var resultList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(ids.prefix(limit), id: \.self) { id in
                    let parent = snapshot.trail(to: id).dropLast().map(snapshot.name).joined(separator: " › ")
                    ItemRow(snapshot: snapshot, id: id, parent: parent, selected: selected.contains(id),
                            menu: menu(id), action: { select(id) })
                }
                if ids.count > limit {
                    Button("Show More Matches") { limit += pageSize }.padding(6)
                } else if !complete {
                    ProgressView().controlSize(.small).padding(6)
                }
            }
        }
    }

    private func loadMatches() async {
        do {
            if cursor == 1 { try await Task.sleep(for: .milliseconds(160)) }
            while !complete && ids.count <= limit {
                let page = try await snapshot.searchFilenames(query, from: cursor, limit: limit + 1 - ids.count)
                try Task.checkCancellation()
                ids.append(contentsOf: page.ids)
                cursor = page.next
                complete = page.complete
                hasSearched = true
                if !complete && ids.count <= limit { try await Task.sleep(for: .milliseconds(250)) }
            }
        } catch is CancellationError {
            return
        } catch {
            failed = true
        }
    }
}
