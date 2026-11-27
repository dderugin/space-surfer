import Darwin
import Foundation
import ScanCore

func foundationScan(_ url: URL) throws -> (items: UInt64, bytes: UInt64, skipped: UInt64) {
    let keys: Set<URLResourceKey> = [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
    var items: UInt64 = 0
    var skipped: UInt64 = 0
    var bytes: UInt64 = 0
    guard let entries = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys), errorHandler: { _, _ in
        skipped += 1
        return true
    }) else { throw POSIXError(.ENOENT) }
    for case let entry as URL in entries {
        items += 1
        do {
            let values = try entry.resourceValues(forKeys: keys)
            if values.isRegularFile == true {
                bytes += UInt64(max(0, values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0))
            }
        } catch {
            skipped += 1
        }
    }
    return (items, bytes, skipped)
}

let arguments = CommandLine.arguments
let workers = arguments.count == 4 ? UInt32(arguments[3]) : ScanSnapshot.defaultWorkerCount
guard (3...4).contains(arguments.count), ["bulk", "posix", "foundation"].contains(arguments[1]),
      arguments.count == 3 || arguments[1] != "foundation",
      let workers, (1...ScanSnapshot.maximumWorkerCount).contains(workers) else {
    let usage = """
    Usage: SpaceSurfBench bulk|posix <folder> [workers (1–\(ScanSnapshot.maximumWorkerCount))]
           SpaceSurfBench foundation <folder>

    """
    FileHandle.standardError.write(Data(usage.utf8))
    exit(64)
}

let mode = arguments[1]
let folder = URL(fileURLWithPath: arguments[2], isDirectory: true)
do {
    let start = ContinuousClock.now
    let totals: (items: UInt64, bytes: UInt64, skipped: UInt64)
    if mode == "foundation" {
        totals = try foundationScan(folder)
    } else {
        let snapshot = try ScanSnapshot.scan(folder, control: ScanControl(), useBulk: mode == "bulk", workerCount: workers)
        totals = (UInt64(snapshot.item(ScanSnapshot.root).descendants),
                  snapshot.item(ScanSnapshot.root).allocated, snapshot.progress.skipped)
    }
    let elapsed = start.duration(to: .now).components
    let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    print(String(format: "%@ %.6f s | %llu entries | %llu bytes | %llu skipped | %.1f MiB peak RSS",
                 mode, seconds, totals.items, totals.bytes, totals.skipped, Double(usage.ru_maxrss) / 1_048_576))
} catch {
    FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
    exit(1)
}
