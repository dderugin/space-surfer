import Darwin
import DiskWalker
import Foundation

public enum ItemKind: Sendable {
    case file, folder, symbolicLink, other
}

public struct ScanItem: Sendable {
    public let id: UInt32
    public let parent: UInt32?
    public let allocated: UInt64
    public let descendants: UInt32
    public let kind: ItemKind
}

public struct ScanProgress: Equatable, Sendable {
    public let visited: UInt64
    public let skipped: UInt64
}

public struct RankedItems: Sendable {
    public let ids: [UInt32]
    public let total: Int
}

public struct FilenameMatches: Sendable {
    public let ids: [UInt32]
    public let next: UInt32
    public let complete: Bool
}

public enum Ranking: Sendable {
    case contents, folders, files

    fileprivate var native: SSRanking {
        switch self {
        case .contents: SSContents
        case .folders: SSFolders
        case .files: SSBiggestFiles
        }
    }
}

/// Owns the native atomic progress counters and cancellation flag.
public final class ScanControl: @unchecked Sendable {
    fileprivate let handle: OpaquePointer

    public init() throws {
        guard let handle = ss_control_create() else { throw POSIXError(.ENOMEM) }
        self.handle = handle
    }

    deinit { ss_control_destroy(handle) }

    public func cancel() { ss_cancel(handle) }

    public var progress: ScanProgress {
        let progress = ss_progress(handle)
        return ScanProgress(visited: progress.visited, skipped: progress.skipped)
    }
}

/// Owns a single native scan. The index synchronizes its mutable data and
/// returns copies so Swift callers never borrow storage that the walker can move.
public final class ScanSnapshot: @unchecked Sendable {
    public static let root: UInt32 = 0
    public static let defaultWorkerCount = UInt32(SSDefaultWorkerCount)
    public static let maximumWorkerCount = UInt32(SSMaxWorkerCount)
    public let url: URL
    let removalIdentity = UUID()
    private let handle: OpaquePointer
    private let control: ScanControl

    public var progress: ScanProgress { control.progress }

    public init(_ url: URL, control: ScanControl) throws {
        var error: Int32 = 0
        guard let handle = ss_scan_create(&error) else {
            throw POSIXError(POSIXErrorCode(rawValue: error) ?? .EINVAL)
        }
        self.handle = handle
        self.url = url
        self.control = control
    }

    deinit { ss_scan_destroy(handle) }

    public static func scan(_ url: URL, control: ScanControl, useBulk: Bool = true,
                            workerCount: UInt32 = defaultWorkerCount) throws -> ScanSnapshot {
        let snapshot = try ScanSnapshot(url, control: control)
        _ = try snapshot.walk(useBulk: useBulk, workerCount: workerCount)
        return snapshot
    }

    /// Scans directories with up to `workerCount` workers. One worker uses serial traversal.
    public func walk(useBulk: Bool = true, workerCount: UInt32 = defaultWorkerCount) throws -> Duration {
        let start = ContinuousClock.now
        let error = withScanAccess {
            url.resolvingSymlinksInPath().withUnsafeFileSystemRepresentation { path in
                path.map { ss_scan_walk_with_workers(handle, $0, control.handle, useBulk, workerCount) } ?? EINVAL
            }
        }
        if error == ECANCELED { throw CancellationError() }
        if error != 0 { throw POSIXError(POSIXErrorCode(rawValue: error) ?? .EIO) }
        return start.duration(to: .now)
    }

    public func item(_ id: UInt32) -> ScanItem {
        let item = ss_item(handle, id)
        let kind: ItemKind = switch item.kind {
        case SSFile: .file
        case SSDirectory: .folder
        case SSSymbolicLink: .symbolicLink
        default: .other
        }
        return ScanItem(id: id, parent: item.parent == SSNoItem ? nil : item.parent,
                        allocated: item.allocated, descendants: item.descendants, kind: kind)
    }

    public func name(_ id: UInt32) -> String {
        if id == Self.root { return url.lastPathComponent }
        return withName(id) { String(decoding: UnsafeRawBufferPointer($0), as: UTF8.self) }
    }

    func withName<T>(_ id: UInt32, body: (UnsafeBufferPointer<CChar>) throws -> T) rethrows -> T {
        try withUnsafeTemporaryAllocation(of: CChar.self, capacity: Int(NAME_MAX) + 1) { buffer in
            let length = ss_copy_name(handle, id, buffer.baseAddress, buffer.count)
            if length < buffer.count {
                return try body(UnsafeBufferPointer(start: buffer.baseAddress, count: length))
            }
            var full = [CChar](repeating: 0, count: length + 1)
            return try full.withUnsafeMutableBufferPointer { buffer in
                _ = ss_copy_name(handle, id, buffer.baseAddress, buffer.count)
                return try body(UnsafeBufferPointer(start: buffer.baseAddress, count: length))
            }
        }
    }

    public func trail(to id: UInt32) -> [UInt32] {
        withUnsafeTemporaryAllocation(of: UInt32.self, capacity: 32) { buffer in
            let count = ss_copy_trail(handle, id, buffer.baseAddress, buffer.count)
            if count <= buffer.count {
                return Array(UnsafeBufferPointer(start: buffer.baseAddress, count: count))
            }
            // Parent IDs remain stable for the lifetime of the scan.
            var trail = [UInt32](repeating: 0, count: count)
            trail.withUnsafeMutableBufferPointer {
                _ = ss_copy_trail(handle, id, $0.baseAddress, $0.count)
            }
            return trail
        }
    }

    public func url(for id: UInt32) -> URL {
        guard id != Self.root else { return url }
        return itemURL(id, base: url)
    }

    func itemURL(_ id: UInt32, base: URL) -> URL {
        // Construct the URL from raw names so Finder can also reveal non-UTF-8 names.
        var path = base.withUnsafeFileSystemRepresentation { base in
            base.map { Array(UnsafeBufferPointer(start: $0, count: strlen($0))) } ?? []
        }
        for component in trail(to: id).dropFirst() {
            if path.last != 47 { path.append(47) }
            withName(component) { path.append(contentsOf: $0) }
        }
        path.append(0)
        return path.withUnsafeBufferPointer {
            URL(fileURLWithFileSystemRepresentation: $0.baseAddress!, isDirectory: item(id).kind == .folder, relativeTo: nil)
        }
    }

    func forgetRemovedItem(_ id: UInt32) -> Bool {
        ss_forget_removed_item(handle, id)
    }

    func containsItem(_ id: UInt32) -> Bool {
        ss_item_is_attached(handle, id)
    }

    func matchesRoot(_ descriptor: Int32) -> Bool {
        ss_scan_root_matches(handle, descriptor)
    }

    func matchesItem(_ id: UInt32, _ attributes: inout stat) -> Bool {
        ss_item_matches(handle, id, &attributes)
    }

    func withScanAccess<T>(_ action: () throws -> T) rethrows -> T {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        return try action()
    }

    /// Queries existing names only. A cursor can resume when the live index grows.
    public func searchFilenames(_ query: String, from cursor: UInt32 = 1, limit: Int) async throws -> FilenameMatches {
        let control = try ScanControl()
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) {
                var ids = [UInt32](repeating: 0, count: max(0, limit))
                let result = ids.withUnsafeMutableBufferPointer { buffer in
                    query.withCString { ss_search(self.handle, $0, cursor, buffer.baseAddress, buffer.count, control.handle) }
                }
                if ss_is_cancelled(control.handle) { throw CancellationError() }
                ids.removeLast(ids.count - result.count)
                return FilenameMatches(ids: ids, next: result.next, complete: result.complete)
            }.value
        } onCancel: {
            control.cancel()
        }
    }

    public func ranked(in folder: UInt32, mode: Ranking, limit: Int) async throws -> RankedItems {
        let control = try ScanControl()
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) {
                var ids = [UInt32](repeating: 0, count: max(0, limit))
                let total = ids.withUnsafeMutableBufferPointer {
                    ss_rank(self.handle, folder, mode.native, $0.baseAddress, $0.count, control.handle)
                }
                if ss_is_cancelled(control.handle) { throw CancellationError() }
                if ids.count > total { ids.removeLast(ids.count - total) }
                return RankedItems(ids: ids, total: total)
            }.value
        } onCancel: {
            control.cancel()
        }
    }
}
