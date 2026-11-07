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

    /// Every tab except the current one, followed by named windows. Tabs in
    /// the current window come first.
    private var options: [CommandOption] {
        let currentWindow = surfaceView.window
        let currentGroup = currentWindow?.tabGroup

        // Collect each window (native tab group) once, current first.
        var groups: [[TerminalController]] = []
        var seen = Set<ObjectIdentifier>()
        let all = TerminalController.all
        let controllers = all.filter { $0.window?.tabGroup === currentGroup }
            + all.filter { $0.window?.tabGroup !== currentGroup }
        for controller in controllers {
            guard let window = controller.window else { continue }
            let key = window.tabGroup.map { ObjectIdentifier($0) } ?? ObjectIdentifier(window)
            guard !seen.contains(key) else { continue }
            seen.insert(key)

            let windows = window.tabGroup?.windows ?? [window]
            let members = windows.compactMap { $0.windowController as? TerminalController }
            guard windows.contains(where: { $0.isVisible || $0.isMiniaturized }) else { continue }
            groups.append(members)
        }

        var tabOptions: [CommandOption] = []
        var windowOptions: [CommandOption] = []

        for members in groups {
            let windowName = members.lazy.compactMap(\.windowName).first { !$0.isEmpty }

            for controller in members {
                guard let window = controller.window, window !== currentWindow else { continue }
                let title = Self.title(for: controller)
                let pwd = controller.focusedSurface?.pwd?.abbreviatedPath
                tabOptions.append(CommandOption(
                    title: title,
                    subtitle: pwd.flatMap { title.contains($0) ? nil : $0 },
                    description: windowName.map { "In window \($0)" },
                    leadingColor: Self.color(for: window),
                    badge: windowName,
                    sortKey: ObjectIdentifier(window)
                ) {
                    Self.focus(window)
                })
            }

            // Named windows can be found by name. Unnamed windows have no
            // name to search for.
            if let windowName, let target = members.first?.window {
                let selected = target.tabGroup?.selectedWindow ?? target
                let count = members.count
                windowOptions.append(CommandOption(
                    title: windowName,
                    subtitle: count == 1 ? "1 tab" : "\(count) tabs",
                    leadingIcon: "macwindow",
                    sortKey: ObjectIdentifier(target)
                ) {
                    Self.focus(selected)
                })
            }
        }

        return tabOptions + windowOptions
    }

    private static func focus(_ window: NSWindow) {
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.tabGroup?.selectedWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private static func title(for controller: TerminalController) -> String {
        if let override = controller.titleOverride, !override.isEmpty {
            return override
        }

        if let title = controller.window?.title, !title.isEmpty {
            return title
        }

        return "Untitled"
    }

    private static func color(for window: NSWindow) -> Color? {
        guard let color = (window as? TerminalWindow)?.tabColor,
              color != TerminalTabColor.none,
              let display = color.displayColor else { return nil }
        return Color(nsColor: display)
    }
}
