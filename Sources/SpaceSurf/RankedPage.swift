import ScanCore

let pageSize = 128

struct PageRequest: Equatable, Sendable {
    let limit: Int
    let revision: UInt64
    let isScanning: Bool
}

/// A page is reusable only for the same size limit and scan revision. The final
/// request also runs when scanning ends without a change to the item count.
struct RankedPage: Sendable {
    let request: PageRequest
    let items: RankedItems?

    var failed: Bool { items == nil }

    static func load(_ request: PageRequest, from snapshot: ScanSnapshot,
                     folder: UInt32, mode: Ranking) async -> RankedPage? {
        do {
            let items = try await snapshot.ranked(in: folder, mode: mode, limit: request.limit)
            try Task.checkCancellation()
            return RankedPage(request: request, items: items)
        } catch is CancellationError {
            return nil
        } catch {
            return Task.isCancelled ? nil : RankedPage(request: request, items: nil)
        }
    }
}
