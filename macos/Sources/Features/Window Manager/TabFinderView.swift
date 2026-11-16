import SwiftUI

/// A small search box shown in the top-right of a terminal window that lets
/// the user find a tab or window by name (tab title, window name, or working
/// directory) and switch to it.
struct TabFinderView: View {
    /// The surface that this tab finder is shown over.
    let surfaceView: Ghostty.SurfaceView

    /// Set this to true to show the view. This is set to false when the
    /// user picks a result or dismisses it.
    @Binding var isPresented: Bool

    /// The configuration, for the background color.
    @ObservedObject var ghosttyConfig: Ghostty.Config

    var body: some View {
        ZStack {
            if isPresented {
                VStack {
                    HStack {
                        Spacer()

                        ResponderChainInjector(responder: surfaceView)
                            .frame(width: 0, height: 0)

                        CommandPaletteView(
                            isPresented: $isPresented,
                            backgroundColor: ghosttyConfig.backgroundColor,
                            options: options,
                            emptyQueryOptions: emptyQueryOptions,
                            selectsFirstOption: true,
                            placeholder: "Find a tab or window…",
                            maxWidth: 340,
                            compact: true
                        )
                        .frame(width: 340)
                    }

                    Spacer()
                }
                .zIndex(1)
            }
        }
        .onChange(of: isPresented) { newValue in
            // Send focus back to the surface we were overlaid on. If the
            // user switched tabs this is a different window, so this
            // doesn't steal focus from the tab they picked.
            if !newValue {
                DispatchQueue.main.async {
                    surfaceView.window?.makeFirstResponder(surfaceView)
                }
            }
        }
    }

    /// Every tab, most recently focused first, followed by named windows.
    /// The current tab is listed last, after the other tabs, since it's
    /// rarely what you're looking for.
    private var options: [CommandOption] {
        tabOptions(includingCurrent: true) + windowOptions
    }

    /// Shown before anything is typed: the other tabs, most recently
    /// focused first, so the tab you were last on is at the top. Then
    /// named windows.
    private var emptyQueryOptions: [CommandOption] {
        tabOptions(includingCurrent: false) + windowOptions
    }

    private var groups: [[TerminalController]] { WindowMenuList.windowGroups() }

    private func tabOptions(includingCurrent: Bool) -> [CommandOption] {
        let currentWindow = surfaceView.window

        // Recently focused tabs first. Tabs that were never focused keep
        // their window order after those (a stable sort).
        var rank: [ObjectIdentifier: Int] = [:]
        for (index, controller) in TerminalController.recentlyFocused.enumerated() {
            rank[ObjectIdentifier(controller)] = index
        }

        var tabs: [(controller: TerminalController, windowName: String?)] = []
        for members in groups {
            let windowName = members.lazy.compactMap(\.windowName).first { !$0.isEmpty }
            for controller in members where controller.window !== currentWindow {
                tabs.append((controller, windowName))
            }
        }
        tabs.sort {
            (rank[ObjectIdentifier($0.controller)] ?? .max) < (rank[ObjectIdentifier($1.controller)] ?? .max)
        }

        if includingCurrent,
           let current = currentWindow?.windowController as? TerminalController {
            let windowName = current.windowName.flatMap { $0.isEmpty ? nil : $0 }
            tabs.append((current, windowName))
        }

        return tabs.compactMap { controller, windowName in
            guard let window = controller.window else { return nil }
            let title = Self.title(for: controller)
            let rawPwd = controller.focusedSurface?.pwd
            let pwd = rawPwd?.abbreviatedPath
            return CommandOption(
                title: title,
                subtitle: pwd.flatMap { title.contains($0) ? nil : $0 },
                description: windowName.map { "In window \($0)" },
                leadingColor: Self.color(for: window),
                badge: windowName,
                sortKey: ObjectIdentifier(window),
                searchTiers: [
                    [Self.name(for: controller, paths: [rawPwd, pwd]), windowName ?? ""],
                    [title, pwd ?? ""],
                ]
            ) {
                Self.focus(window)
            }
        }
    }

    /// The tab's name for searching: a title the user set, or else the
    /// title with the working directory taken out, since shells often put
    /// the directory in the title. This way searching for "b" finds a tab
    /// named "b" before every tab that's merely in "~/a/b/c".
    private static func name(for controller: TerminalController, paths: [String?]) -> String {
        if let override = controller.titleOverride, !override.isEmpty {
            return override
        }

        var name = title(for: controller)
        for case let path? in paths where !path.isEmpty {
            name = name.replacingOccurrences(of: path, with: "")
        }
        return name.trimmingCharacters(in: .whitespaces)
    }

    /// Named windows can be found by name. Unnamed windows have no name to
    /// search for.
    private var windowOptions: [CommandOption] {
        groups.compactMap { members in
            guard let windowName = members.lazy.compactMap(\.windowName).first(where: { !$0.isEmpty }),
                  let target = members.first?.window else { return nil }
            let selected = target.tabGroup?.selectedWindow ?? target
            let count = members.count
            return CommandOption(
                title: windowName,
                subtitle: count == 1 ? "1 tab" : "\(count) tabs",
                leadingIcon: "macwindow",
                sortKey: ObjectIdentifier(target),
                searchTiers: [[windowName]]
            ) {
                Self.focus(selected)
            }
        }
    }

    static func focus(_ window: NSWindow) {
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.tabGroup?.selectedWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    static func title(for controller: TerminalController) -> String {
        if let override = controller.titleOverride, !override.isEmpty {
            return override
        }

        if let title = controller.window?.title, !title.isEmpty {
            return title
        }

        return "Untitled"
    }

    static func color(for window: NSWindow) -> Color? {
        guard let color = (window as? TerminalWindow)?.tabColor,
              color != TerminalTabColor.none,
              let display = color.displayColor else { return nil }
        return Color(nsColor: display)
    }
}
