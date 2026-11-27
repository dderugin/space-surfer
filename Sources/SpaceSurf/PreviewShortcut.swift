import AppKit
import SwiftUI

/// Scope the Space shortcut to the scan window and leave text editing alone.
struct PreviewShortcut: NSViewRepresentable {
    let preview: () -> Bool

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let coordinator = context.coordinator
        coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak view, weak coordinator] event in
            guard let window = view?.window, event.window === window, window.attachedSheet == nil,
                  !(window.firstResponder is NSTextView), event.charactersIgnoringModifiers == " ",
                  event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
                  !event.isARepeat, coordinator?.preview?() == true else { return event }
            return nil
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) { context.coordinator.preview = preview }
    func makeCoordinator() -> Coordinator { Coordinator() }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        if let monitor = coordinator.monitor { NSEvent.removeMonitor(monitor) }
        coordinator.monitor = nil
        coordinator.preview = nil
    }

    final class Coordinator {
        var monitor: Any?
        var preview: (() -> Bool)?
    }
}
