import AppKit
import SwiftUI

// Use the property wrapper on toolchains that also declare a State macro.
typealias ViewState<Value> = SwiftUI.State<Value>

@main
struct SpaceSurfApp: App {
    var body: some Scene {
        Window("Space Surfer", id: "main") {
            ScanWindow()
                .frame(minWidth: 680, minHeight: 480)
        }
        .commands {
            AboutCommands()
            FilenameSearchCommands()
        }
        .defaultSize(width: 1000, height: 640)
    }
}

private struct AboutCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About Space Surfer", action: showAbout)
        }
    }

    private func showAbout() {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let credits = NSMutableAttributedString(
            string: "A disk space analyzer for macOS.\nLicensed under the MIT License.\n\n",
            attributes: [.paragraphStyle: paragraph, .foregroundColor: NSColor.labelColor]
        )
        credits.append(NSAttributedString(string: "View Space Surfer on GitHub", attributes: [
            .paragraphStyle: paragraph,
            .link: "https://github.com/dderugin/space-surfer",
        ]))
        NSApplication.shared.orderFrontStandardAboutPanel(options: [.credits: credits])
    }
}

private struct FilenameSearchCommands: Commands {
    @FocusedValue(\.focusFilenameSearch) private var focusSearch

    var body: some Commands {
        CommandGroup(after: .textEditing) {
            Button("Find Files…") { focusSearch?() }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(focusSearch == nil)
        }
    }
}

extension FocusedValues {
    var focusFilenameSearch: (() -> Void)? {
        get { self[FocusFilenameSearchKey.self] }
        set { self[FocusFilenameSearchKey.self] = newValue }
    }
}

private struct FocusFilenameSearchKey: FocusedValueKey {
    typealias Value = () -> Void
}
