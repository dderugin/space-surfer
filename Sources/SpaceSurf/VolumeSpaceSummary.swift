import ScanCore
import SwiftUI

struct VolumeSpaceSummary: View {
    let space: VolumeSpace?
    let isLoading: Bool
    let completedScanBytes: UInt64?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                Text("Volume space").font(.callout.weight(.semibold))
                if let space {
                    metric("Total", space.total)
                    metric("Used", space.used)
                    metric("Free", space.free)
                    if let unaccounted = space.unaccountedBytes(scannedBytes: completedScanBytes) {
                        metric("Unaccounted", unaccounted)
                            .help("Used space minus the allocated bytes found by this scan. Snapshots, filesystem metadata, and protected files can contribute to the difference.")
                    }
                } else {
                    Text(isLoading ? "Reading capacity…" : "Capacity unavailable")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            // Reserve this line so loading capacity or finishing a scan never moves search below it.
            let note = capacityNote
            Text(note ?? " ")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .accessibilityHidden(note == nil)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.25))
    }

    private var capacityNote: String? {
        guard let space else { return nil }
        if !space.isWholeVolume { return "Capacity is for the volume containing this folder." }
        if let completedScanBytes, completedScanBytes > space.used {
            return "Scan total exceeds reported usage. Shared blocks can contribute."
        }
        return space.sharesAPFSSpace ? "APFS capacity can include space shared with other volumes." : nil
    }

    private func metric(_ label: String, _ bytes: UInt64) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(label).foregroundStyle(.secondary)
            Text(Design.size(bytes)).monospacedDigit().fontWeight(.medium)
                .textSelection(.enabled)
        }
        .font(.callout)
        .fixedSize()
        .accessibilityElement(children: .combine)
    }
}
