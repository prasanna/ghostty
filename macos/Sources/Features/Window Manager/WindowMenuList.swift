import AppKit

/// Lists terminal windows at the bottom of the Window menu with each
/// window's tabs indented under it.
///
/// AppKit's own window list shows every tab as a separate, flat entry, so
/// terminal windows opt out of it (`isExcludedFromWindowsMenu`) and this
/// rebuilds our own entries every time the menu is about to open.
final class WindowMenuList: NSObject, NSMenuDelegate {
    /// Marks the items we added so we can remove them on the next update.
    private static let itemTag = 0x67_68_77_6d // "ghwm"

    func install(in menu: NSMenu) {
        menu.delegate = self
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        for item in menu.items where item.tag == Self.itemTag {
            menu.removeItem(item)
        }

        let groups = Self.windowGroups()
        guard !groups.isEmpty else { return }

        // AppKit's list (for any non-terminal windows) goes at the very
        // bottom after a separator, so go just before that if it's there.
        var index = menu.items.count
        if let first = menu.items.firstIndex(where: { $0.action == #selector(NSWindow.makeKeyAndOrderFront(_:)) }),
           first > 0, menu.items[first - 1].isSeparatorItem {
            index = first - 1
        }

        func add(_ item: NSMenuItem) {
            item.tag = Self.itemTag
            menu.insertItem(item, at: index)
            index += 1
        }

        let separator = NSMenuItem.separator()
        add(separator)

        let keyWindow = NSApp.keyWindow ?? NSApp.mainWindow
        for (number, members) in groups.enumerated() {
            let windowName = members.lazy.compactMap(\.windowName).first { !$0.isEmpty }
            let header = NSMenuItem(
                title: windowName ?? "Window \(number + 1)",
                action: #selector(focusWindow(_:)),
                keyEquivalent: "")
            header.target = self
            header.representedObject = members.first?.window.map { $0.tabGroup?.selectedWindow ?? $0 }
            add(header)

            for controller in members {
                guard let window = controller.window else { continue }
                let item = NSMenuItem(
                    title: TabFinderView.title(for: controller),
                    action: #selector(focusWindow(_:)),
                    keyEquivalent: "")
                item.target = self
                item.representedObject = window
                item.indentationLevel = 1
                if window === keyWindow {
                    item.state = .on
                } else if window.isMiniaturized {
                    item.state = .mixed
                }
                add(item)
            }
        }
    }

    @objc private func focusWindow(_ sender: NSMenuItem) {
        guard let window = sender.representedObject as? NSWindow else { return }
        TabFinderView.focus(window)
    }

    /// The tabs of each visible terminal window (native tab group), in
    /// `TerminalController.all` order.
    static func windowGroups() -> [[TerminalController]] {
        var result: [[TerminalController]] = []
        var seen = Set<ObjectIdentifier>()
        for controller in TerminalController.all {
            guard let window = controller.window else { continue }
            let key = window.tabGroup.map { ObjectIdentifier($0) } ?? ObjectIdentifier(window)
            guard !seen.contains(key) else { continue }
            seen.insert(key)

            let windows = window.tabGroup?.windows ?? [window]
            guard windows.contains(where: { $0.isVisible || $0.isMiniaturized }) else { continue }
            let members = windows.compactMap { $0.windowController as? TerminalController }
            if !members.isEmpty { result.append(members) }
        }
        return result
    }
}
