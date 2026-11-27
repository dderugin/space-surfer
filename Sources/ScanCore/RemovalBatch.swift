import Foundation

/// Captures the topmost selected paths before confirmation. Selecting a folder
/// and a descendant results in one operation on the folder.
public struct RemovalBatch: Sendable {
    public let id = UUID()
    public let targets: [RemovalTarget]

    public init(snapshot: ScanSnapshot, ids: Set<UInt32>) throws {
        guard ids.allSatisfy(snapshot.containsItem) else { throw RemovalError("An item is outside the current scan.") }
        targets = try ids.sorted().filter { id in
            snapshot.trail(to: id).dropLast().allSatisfy { !ids.contains($0) }
        }.map(snapshot.prepareRemoval(of:))
    }

    /// Reports successful and failed targets separately so the UI can keep the
    /// index current even when only part of a batch succeeds.
    public func run(on snapshot: ScanSnapshot, using method: RemovalMethod) -> RemovalBatchResult {
        var result = RemovalBatchResult()
        for target in targets {
            do {
                if try !snapshot.remove(target, using: method) { result.needsRefresh = true }
                result.removed[target.id] = target.parent
            } catch {
                result.needsRefresh = result.needsRefresh || (error as? RemovalError)?.needsRefresh == true
                result.failures.append("\(target.name): \(error.localizedDescription)")
            }
        }
        return result
    }
}

public struct RemovalBatchResult: Sendable {
    public fileprivate(set) var removed: [UInt32: UInt32] = [:]
    public fileprivate(set) var failures: [String] = []
    public fileprivate(set) var needsRefresh = false
}
