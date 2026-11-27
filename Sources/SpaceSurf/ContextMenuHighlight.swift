import AppKit
import SwiftUI

extension View {
    func itemContextMenu(_ menu: ItemContextMenu, cornerRadius: CGFloat) -> some View {
        contextMenu { menu }
            .overlay { ContextMenuHighlight(menu: menu, cornerRadius: cornerRadius) }
    }
}

/// Handles pointer context menus without sending a click to the underlying button.
/// SwiftUI still provides the context menu for keyboard and accessibility use.
private struct ContextMenuHighlight: NSViewRepresentable {
    let menu: ItemContextMenu
    let cornerRadius: CGFloat

    func makeNSView(context: Context) -> MenuTargetView { MenuTargetView() }

    func updateNSView(_ view: MenuTargetView, context: Context) {
        view.actions = menu
        view.layer?.cornerRadius = cornerRadius
    }
}

private final class MenuTargetView: NSView, NSMenuDelegate {
    var actions: ItemContextMenu?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let event = NSApp.currentEvent,
              event.type == .rightMouseDown ||
              (event.type == .leftMouseDown && event.modifierFlags.contains(.control)) else { return nil }
        return super.hitTest(point)
    }

    override func rightMouseDown(with event: NSEvent) { openMenu(for: event) }
    override func mouseDown(with event: NSEvent) { openMenu(for: event) }

    private func openMenu(for event: NSEvent) {
        guard let actions else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        menu.addItem(.sectionHeader(title: actions.title))
        menu.addItem(ClosureMenuItem("Quick Look", action: actions.preview))
        menu.addItem(ClosureMenuItem("Get Info", action: actions.info))
        if let addToFavorites = actions.addToFavorites {
            menu.addItem(ClosureMenuItem("Add to Favorites", action: addToFavorites))
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Move to Trash", enabled: actions.canRemove) { actions.remove(.trash) })
        menu.addItem(ClosureMenuItem("Delete Permanently…", enabled: actions.canRemove) { actions.remove(.permanent) })
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    func menuWillOpen(_ menu: NSMenu) {
        layer?.borderColor = NSColor.controlAccentColor.cgColor
        layer?.borderWidth = 3
        layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.14).cgColor
    }

    func menuDidClose(_ menu: NSMenu) {
        layer?.borderWidth = 0
        layer?.backgroundColor = nil
    }
}

private final class ClosureMenuItem: NSMenuItem {
    private let perform: () -> Void

    init(_ title: String, enabled: Bool = true, action: @escaping () -> Void) {
        perform = action
        super.init(title: title, action: #selector(invoke), keyEquivalent: "")
        target = self
        isEnabled = enabled
    }

    required init(coder: NSCoder) { fatalError("Menu items are created in code") }

    @objc private func invoke() { perform() }
}
