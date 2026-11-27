import Darwin
import Foundation

public struct VolumeSpace: Sendable {
    public let total: UInt64
    public let free: UInt64
    public let isWholeVolume: Bool
    public let sharesAPFSSpace: Bool

    public var used: UInt64 { total - free }

    /// Only a completed whole-volume scan can be compared with volume usage.
    public func unaccountedBytes(scannedBytes: UInt64?) -> UInt64? {
        guard isWholeVolume, let scannedBytes else { return nil }
        return used - min(used, scannedBytes)
    }

    init(total: UInt64, free: UInt64, isWholeVolume: Bool, sharesAPFSSpace: Bool) {
        self.total = total
        self.free = min(total, free)
        self.isWholeVolume = isWholeVolume
        self.sharesAPFSSpace = sharesAPFSSpace
    }

    public static func read(for url: URL) -> Self? {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let path = url.resolvingSymlinksInPath().path(percentEncoded: false)
        var info = statfs()
        guard statfs(path, &info) == 0, info.f_blocks > 0, info.f_bsize > 0 else { return nil }

        // APFS reports capacity against shared container space. Total minus
        // free is the occupied portion of that reported capacity.
        let (total, overflow) = info.f_blocks.multipliedReportingOverflow(by: UInt64(info.f_bsize))
        guard !overflow else { return nil }
        let free = min(info.f_blocks, info.f_bfree) * UInt64(info.f_bsize)
        let mountPath = field(&info.f_mntonname)
        return Self(total: total, free: free, isWholeVolume: path == mountPath,
                    sharesAPFSSpace: field(&info.f_fstypename) == "apfs")
    }

    private static func field<Value>(_ value: inout Value) -> String {
        withUnsafeBytes(of: &value) { String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self) }
    }
}

extension ScanSnapshot {
    /// Reads filesystem counters without traversing the scan or taking its index lock.
    public func readVolumeSpace() -> VolumeSpace? {
        VolumeSpace.read(for: url)
    }
}
