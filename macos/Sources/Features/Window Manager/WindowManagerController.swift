import Cocoa
import SwiftUI

/// Hosts the "Windows & Tabs" manager in a floating utility panel so it
/// stays visible above terminal windows while tabs are being organized.
class WindowManagerController: NSWindowController, NSWindowDelegate {
    private static let frameAutosaveName = "GhosttyWindowManager"

    private let model: WindowManagerModel

    init(_ ghostty: Ghostty.App) {
        let model = WindowManagerModel(ghostty)
        self.model = model

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 540),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: true
        )
        panel.title = "Windows & Tabs"
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: WindowManagerView(model: model))

        let hasSavedFrame = UserDefaults.standard.string(
            forKey: "NSWindow Frame \(Self.frameAutosaveName)") != nil
        panel.setFrameAutosaveName(Self.frameAutosaveName)
        if !hasSavedFrame { panel.center() }

        super.init(window: panel)
        panel.delegate = self
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported for this view")
    }

    // MARK: Functions

    /// Show the manager, optionally highlighting the given tab.
    func show(highlighting tab: NSWindow? = nil) {
        model.start()
        model.highlight(tab)
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: First Responder

    // This is called when "escape" is pressed.
    @objc func cancel(_ sender: Any?) {
        window?.performClose(sender)
    }

    // MARK: NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard model.isDirty else { return true }

        let alert = NSAlert()
        alert.messageText = "Apply your changes to windows and tabs?"
        alert.informativeText = model.closeSummary ?? "Your changes will be lost if you don't apply them."
        alert.addButton(withTitle: "Apply")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Discard Changes")
        alert.beginSheetModal(for: sender) { [weak self] response in
            guard let self else { return }
            switch response {
            case .alertFirstButtonReturn:
                self.model.apply()
                self.window?.close()
            case .alertThirdButtonReturn:
                self.model.reload()
                self.window?.close()
            default:
                break
            }
        }

        return false
    }

    func windowWillClose(_ notification: Notification) {
        model.stop()
        model.highlightedTabID = nil
    }
}
