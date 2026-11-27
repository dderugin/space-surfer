import AppKit
import SwiftUI

struct ScanSourcesSidebar: View {
    let session: ScanSession
    let favorites: [String]
    let addFavorite: @MainActor (URL) -> Void
    let removeFavorite: (String) -> Void
    @ViewState private var drives = [MountedDrive.startup]
    @ViewState private var mountRevision = 0

    var body: some View {
        List {
            Section("Mounted Drives") {
                ForEach(drives) { drive in
                    sourceRow(drive.name, icon: drive.icon, url: drive.url)
                }
            }
            Section("Favorites") {
                ForEach(favorites, id: \.self) { path in
                    let url = URL(filePath: path, directoryHint: .isDirectory)
                    sourceRow(url.lastPathComponent.isEmpty ? path : url.lastPathComponent, icon: "folder", url: url)
                        .contextMenu {
                            Button("Remove Favorite") { removeFavorite(path) }
                        }
                }
                Button("Add Favorite…", systemImage: "plus") { session.chooseFavorite(add: addFavorite) }
                    .buttonStyle(.plain)
                    .disabled(!session.canStartScan)
            }
        }
        .listStyle(.sidebar)
        .accessibilityLabel("Scan sources")
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didMountNotification)) { _ in
            mountRevision += 1
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification)) { _ in
            mountRevision += 1
        }
        .task(id: mountRevision) {
            let mounted = await Task.detached(priority: .utility) { MountedDrive.discover() }.value
            if !Task.isCancelled { drives = mounted }
        }
    }

    private func sourceRow(_ name: String, icon: String, url: URL) -> some View {
        let path = url.standardizedFileURL.path(percentEncoded: false)
        let selected = session.result?.url.standardizedFileURL.path(percentEncoded: false) == path
        return Button {
            session.scan(url)
        } label: {
            Label(name, systemImage: icon)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
                .background(selected ? Design.accent.opacity(0.21) : .clear, in: RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!session.canStartScan)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityHint("Scan this location")
        .help(path)
    }

}

private struct MountedDrive: Identifiable, Sendable {
    static let startup = Self(url: URL(filePath: "/", directoryHint: .isDirectory),
                              name: "Macintosh HD", icon: "internaldrive")
    let url: URL
    let name: String
    let icon: String
    var id: String { url.path(percentEncoded: false) }

    static func discover() -> [Self] {
        let keys: Set<URLResourceKey> = [.volumeLocalizedNameKey, .volumeIsInternalKey, .volumeIsLocalKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: Array(keys),
                                                        options: .skipHiddenVolumes) ?? []
        let drives = urls.compactMap { url -> Self? in
            let path = url.path(percentEncoded: false)
            guard path != "/", !path.hasPrefix("/System/Volumes/") else { return nil }
            let values = try? url.resourceValues(forKeys: keys)
            let icon = values?.volumeIsLocal == false ? "network" :
                values?.volumeIsInternal == true ? "internaldrive" : "externaldrive"
            return Self(url: url, name: values?.volumeLocalizedName ?? url.lastPathComponent, icon: icon)
        }
        return [startup] + drives.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
