import Darwin
import Foundation

public enum RemovalMethod: Sendable {
    case trash, permanent
}

public struct RemovalTarget: Sendable {
    public let id: UInt32
    public let parent: UInt32
    public let name: String
    public let url: URL
    public let kind: ItemKind
    fileprivate let scan: UUID
    fileprivate let base: URL
}

public struct RemovalError: LocalizedError, Sendable {
    public let errorDescription: String?
    public let needsRefresh: Bool

    init(_ message: String, needsRefresh: Bool = false) {
        errorDescription = message
        self.needsRefresh = needsRefresh
    }
}

extension ScanSnapshot {
    public func prepareRemoval(of id: UInt32) throws -> RemovalTarget {
        guard containsItem(id) else { throw RemovalError("The item is outside the current scan.") }
        let item = item(id)
        guard let parent = item.parent else { throw RemovalError("Choose an item inside the scanned folder.") }
        return try withScanAccess {
            let base = url.resolvingSymlinksInPath()
            let itemURL = itemURL(id, base: base)
            return try withParentDirectory(of: id, base: base) { fd, name in
                _ = try verifiedAttributes(of: id, parent: fd, name: name)
                return RemovalTarget(id: id, parent: parent, name: self.name(id), url: itemURL, kind: item.kind,
                                     scan: removalIdentity, base: base)
            }
        }
    }

    /// Returns false when refreshing the scan is necessary to account for the removal.
    public func remove(_ target: RemovalTarget, using method: RemovalMethod) throws -> Bool {
        try remove(target, using: method, moveToTrash: moveToSystemTrash)
    }

    func remove(_ target: RemovalTarget, using method: RemovalMethod,
                moveToTrash: (URL) throws -> URL?) throws -> Bool {
        guard target.scan == removalIdentity else { throw RemovalError("The item is outside the current scan.") }
        return try withScanAccess {
            try withParentDirectory(of: target.id, base: target.base) { fd, name in
                let attributes = try verifiedAttributes(of: target.id, parent: fd, name: name)
                if target.kind == .folder { try checkMounts(target.url, parent: fd, device: attributes.st_dev) }

                if method == .trash {
                    guard let destination = try moveToTrash(target.url), !contains(destination, in: target.base) else { return false }
                } else {
                    // Darwin's recursive removal stays on the selected filesystem.
                    let flags = target.kind == .folder ? removefile_flags_t(REMOVEFILE_RECURSIVE) : 0
                    guard removefileat(fd, name, nil, flags) == 0 else {
                        let error = posixFailure()
                        throw RemovalError(error.localizedDescription, needsRefresh: target.kind == .folder)
                    }
                }
                if target.kind == .file && attributes.st_nlink > 1 { return false }
                return forgetRemovedItem(target.id)
            }
        }
    }

    private func verifiedAttributes(of id: UInt32, parent: Int32, name: UnsafePointer<CChar>) throws -> stat {
        var attributes = stat()
        guard fstatat(parent, name, &attributes, AT_SYMLINK_NOFOLLOW) == 0 else { throw posixFailure() }
        guard matchesItem(id, &attributes) else {
            throw RemovalError("The selected item has changed. Scan the folder again.")
        }
        return attributes
    }

    private func withParentDirectory<T>(of id: UInt32, base: URL,
                                        action: (Int32, UnsafePointer<CChar>) throws -> T) throws -> T {
        guard id != Self.root, containsItem(id) else { throw RemovalError("The item is outside the current scan.") }
        let flags = O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        var parent = base.withUnsafeFileSystemRepresentation { path in path.map { open($0, flags) } ?? -1 }
        guard parent >= 0 else { throw posixFailure() }
        defer { close(parent) }
        // A scan path can be reused by a different directory or mounted drive.
        guard matchesRoot(parent) else {
            throw RemovalError("The scanned folder has changed. Scan it again before removing items.")
        }
        for component in trail(to: id).dropFirst().dropLast() {
            let child = withName(component) { openat(parent, $0.baseAddress!, flags) }
            guard child >= 0 else { throw posixFailure() }
            close(parent)
            parent = child
            var attributes = stat()
            guard fstat(child, &attributes) == 0 else { throw posixFailure() }
            guard matchesItem(component, &attributes) else {
                throw RemovalError("A folder containing the selected item has changed. Scan the folder again.")
            }
        }
        return try withName(id) { try action(parent, $0.baseAddress!) }
    }
}

private func moveToSystemTrash(_ url: URL) throws -> URL? {
    var destination: NSURL?
    try FileManager.default.trashItem(at: url, resultingItemURL: &destination)
    return destination as URL?
}

private func checkMounts(_ url: URL, parent: Int32, device: dev_t) throws {
    var attributes = stat()
    guard fstat(parent, &attributes) == 0 else { throw posixFailure() }
    guard attributes.st_dev == device else { throw RemovalError("This folder is the root of a mounted volume.") }

    var volumes: UnsafeMutablePointer<statfs>?
    let count = getmntinfo_r_np(&volumes, MNT_NOWAIT)
    guard count > 0, let volumes else { throw RemovalError("Couldn’t check mounted volumes before removing this folder.") }
    defer { free(volumes) }
    for index in 0..<Int(count) {
        var mount = volumes[index].f_mntonname
        let mountPath = withUnsafeBytes(of: &mount) {
            String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        if contains(URL(filePath: mountPath), in: url) {
            throw RemovalError("The selected folder contains a mounted volume.")
        }
    }
}

private func contains(_ url: URL, in directory: URL) -> Bool {
    let root = directory.standardizedFileURL.pathComponents
    return url.standardizedFileURL.pathComponents.starts(with: root)
}

private func posixFailure() -> POSIXError {
    POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
}
