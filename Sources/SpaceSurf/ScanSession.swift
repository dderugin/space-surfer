import AppKit
import Observation
import ScanCore

struct RemovalChange: Equatable {
    let id = UUID()
    let removed: [UInt32: UInt32]
    let method: RemovalMethod
}

@MainActor
@Observable
final class ScanSession {
    private static let startupDisk = URL(filePath: "/", directoryHint: .isDirectory)

    /// The window has one active operation. In particular, a pending deletion
    /// confirmation keeps its snapshot in place until the user decides.
    private enum Activity {
        case idle
        case choosingFolder
        case scanning(URL, ScanControl, stopping: Bool)
        case preparingRemoval
        case confirmingRemoval(RemovalBatch)
        case removing
    }

    private var activity = Activity.idle
    private(set) var result: ScanSnapshot?
    private(set) var volumeSpace: VolumeSpace?
    private(set) var isReadingVolume = false
    private var volumeRequest: Task<Void, Never>?
    var failure: String?
    private(set) var scanned: UInt64 = 0
    private(set) var elapsed: Duration?
    private(set) var stoppedEarly = false
    var removalFailure: String?
    private(set) var removalChange: RemovalChange?

    var source: URL? {
        if case let .scanning(url, _, _) = activity { return url }
        return nil
    }

    var isStopping: Bool {
        if case let .scanning(_, _, stopping) = activity { return stopping }
        return false
    }

    var isRemoving: Bool {
        switch activity {
        case .preparingRemoval, .removing: true
        default: false
        }
    }

    var permanentRemoval: RemovalBatch? {
        if case let .confirmingRemoval(batch) = activity { return batch }
        return nil
    }

    var canStartScan: Bool {
        if case .idle = activity { return true }
        return false
    }

    var completedScanBytes: UInt64? {
        guard elapsed != nil, source == nil else { return nil }
        return result?.item(ScanSnapshot.root).allocated
    }

    func scanStartupDisk() {
        scan(Self.startupDisk)
    }

    func scanHomeFolder() {
        scan(FileManager.default.homeDirectoryForCurrentUser)
    }

    func chooseFolder() {
        chooseDirectory(prompt: "Scan", message: "Choose a folder or mounted drive to scan.") { [weak self] in
            self?.scan($0)
        }
    }

    func chooseFavorite(add: @escaping @MainActor (URL) -> Void) {
        chooseDirectory(prompt: "Add Favorite", message: "Choose a folder to add to the sidebar.", action: add)
    }

    private func chooseDirectory(prompt: String, message: String, action: @escaping @MainActor (URL) -> Void) {
        guard canStartScan else { return }
        activity = .choosingFolder
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = prompt
        panel.message = message
        let choose: @MainActor @Sendable (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self else { return }
            activity = .idle
            if response == .OK, let url = panel.url { action(url) }
        }
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            panel.beginSheetModal(for: window, completionHandler: choose)
        } else {
            panel.begin(completionHandler: choose)
        }
    }

    func cancel() {
        guard case let .scanning(url, control, _) = activity else { return }
        activity = .scanning(url, control, stopping: true)
        control.cancel()
    }

    func requestRemoval(_ ids: Set<UInt32>, using method: RemovalMethod) {
        guard canStartScan, let snapshot = result, !ids.isEmpty, !ids.contains(ScanSnapshot.root) else { return }
        activity = .preparingRemoval
        Task {
            do {
                let batch = try await Task.detached(priority: .userInitiated) { try RemovalBatch(snapshot: snapshot, ids: ids) }.value
                if method == .trash {
                    activity = .removing
                    await remove(batch, from: snapshot, using: method)
                } else {
                    activity = .confirmingRemoval(batch)
                }
            } catch {
                activity = .idle
                removalFailure = error.localizedDescription
            }
        }
    }

    func confirmRemoval(_ batch: RemovalBatch) {
        guard permanentRemoval?.id == batch.id, let snapshot = result else { return }
        activity = .removing
        Task { await remove(batch, from: snapshot, using: .permanent) }
    }

    func dismissRemovalConfirmation() {
        if case .confirmingRemoval = activity { activity = .idle }
    }

    private func remove(_ batch: RemovalBatch, from snapshot: ScanSnapshot, using method: RemovalMethod) async {
        let outcome = await Task.detached(priority: .userInitiated) { batch.run(on: snapshot, using: method) }.value
        activity = .idle
        if outcome.needsRefresh {
            scan(snapshot.url)
        } else if !outcome.removed.isEmpty {
            removalChange = RemovalChange(removed: outcome.removed, method: method)
            refreshVolumeSpace(for: snapshot)
        }
        if !outcome.failures.isEmpty {
            let failures = outcome.failures.prefix(8).joined(separator: "\n")
            let extra = outcome.failures.count > 8 ? "\n\(outcome.failures.count - 8) more items couldn’t be removed." : ""
            removalFailure = "\(outcome.removed.count) removed, \(outcome.failures.count) failed.\n\n\(failures)\(extra)"
        }
    }

    func scan(_ url: URL) {
        guard canStartScan else { return }
        do {
            let control = try ScanControl()
            let snapshot = try ScanSnapshot(url, control: control)
            activity = .scanning(url, control, stopping: false)
            result = snapshot
            volumeSpace = nil
            failure = nil
            removalChange = nil
            scanned = 0
            elapsed = nil
            stoppedEarly = false
            refreshVolumeSpace(for: snapshot)
            Task { await walk(snapshot, control: control) }
        } catch {
            failure = error.localizedDescription
        }
    }

    private func refreshVolumeSpace(for snapshot: ScanSnapshot) {
        volumeRequest?.cancel()
        isReadingVolume = true
        let url = snapshot.url
        volumeRequest = Task { [weak self] in
            let space = await Task.detached(priority: .userInitiated) { VolumeSpace.read(for: url) }.value
            guard let self, !Task.isCancelled else { return }
            if let space { volumeSpace = space }
            isReadingVolume = false
            volumeRequest = nil
        }
    }

    private func walk(_ snapshot: ScanSnapshot, control: ScanControl) async {
        let worker = Task.detached(priority: .userInitiated) { try snapshot.walk() }
        let ticker = Task {
            while !Task.isCancelled {
                scanned = control.progress.visited
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        defer {
            ticker.cancel()
            scanned = control.progress.visited
            activity = .idle
        }
        do {
            elapsed = try await worker.value
            refreshVolumeSpace(for: snapshot)
        } catch is CancellationError {
            stoppedEarly = true
        } catch {
            stoppedEarly = true
            failure = "Couldn’t scan \(Design.scanName(snapshot.url)). \(error.localizedDescription)"
            if control.progress.visited == 0 {
                volumeRequest?.cancel()
                volumeRequest = nil
                isReadingVolume = false
                result = nil
            }
        }
    }
}
