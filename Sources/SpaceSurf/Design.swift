import SwiftUI

@MainActor
enum Design {
    static let accent = Color(red: 0.12, green: 0.43, blue: 0.35)

    static let sizes: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.zeroPadsFractionDigits = false
        return formatter
    }()

    static func size(_ bytes: UInt64) -> String {
        sizes.string(fromByteCount: Int64(clamping: bytes))
    }

    static func scanName(_ url: URL) -> String {
        url.path(percentEncoded: false) == "/" ? "Macintosh HD" : url.lastPathComponent
    }
}
