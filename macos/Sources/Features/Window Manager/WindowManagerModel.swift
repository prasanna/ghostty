import AppKit
import SwiftUI

/// The model behind the "Windows & Tabs" manager.
///
/// On macOS every Ghostty tab is its own `NSWindow` and a "window" (as the
/// user sees it) is a native `NSWindowTabGroup`. This model holds an editable
/// draft of the current windows and tabs as a flat list of rows: each window
/// row is followed by the tab rows that belong to it. The user rearranges the
/// draft freely (create, rename, and delete windows, move and close tabs) and
/// nothing happens to the real windows until `apply()` is called.
@MainActor
final class WindowManagerModel: ObservableObject {
    struct WindowRow: Equatable {
        let id: String
        var name: String
        let isNew: Bool

        /// Why tabs can't be moved into or out of this window, if they can't.
        let lockReason: String?
    }

    struct TabRow: Equatable {
        let id: String
        let isNew: Bool
        let title: String
        let subtitle: String?
        let color: NSColor?
        let needsConfirmQuit: Bool

        /// The window this tab was in when the draft was loaded.
        let originalWindowID: String?

        /// Why this tab can't be moved, if it can't.
        let lockReason: String?
    }

    enum Row: Identifiable, Equatable {
        case window(WindowRow)
        case tab(TabRow)

        var id: String {
            switch self {
            case .window(let w): return "w:\(w.id)"
            case .tab(let t): return "t:\(t.id)"
            }
        }
    }

    /// A window and its tabs, derived from the flat row list.
    struct Section {
        let window: WindowRow
        let tabs: [TabRow]
    }

    /// The draft being edited.
    @Published private(set) var rows: [Row] = []

    /// The rows as they were when the draft was loaded.
    @Published private(set) var original: [Row] = []

    /// True if windows or tabs changed outside the manager while the draft
    /// had unapplied edits.
    @Published private(set) var isStale = false

    /// True while changes are being applied.
    @Published private(set) var isApplying = false

    /// A user-facing error from the last operation, if any.
    @Published var errorMessage: String?

    /// A tab to highlight, e.g. the tab that was right-clicked to open the manager.
    @Published var highlightedTabID: String?

    var isDirty: Bool { rows != original }

    var sections: [Section] {
        var result: [Section] = []
        var current: WindowRow?
        var tabs: [TabRow] = []
        for row in rows {
            switch row {
            case .window(let w):
                if let current { result.append(.init(window: current, tabs: tabs)) }
                current = w
                tabs = []
            case .tab(let t):
                tabs.append(t)
            }
        }
        if let current { result.append(.init(window: current, tabs: tabs)) }
        return result
    }

    /// Existing tabs that will be closed when the draft is applied.
    var tabsToClose: [TabRow] {
        let kept = Set(rows.compactMap { row -> String? in
            if case .tab(let t) = row, !t.isNew { return t.id }
            return nil
        })
        return original.compactMap { row -> TabRow? in
            if case .tab(let t) = row, !kept.contains(t.id) { return t }
            return nil
        }
    }

    private let ghostty: Ghostty.App?

    /// Where the current windows come from. Real windows unless a test
    /// supplies its own.
    private let snapshotSource: (@MainActor () -> [Row])?

    /// Stable display order of window IDs. AppKit's window order changes as
    /// windows are focused, which would make the list jump around.
    private var order: [String] = []

    private var timer: Timer?

    init(_ ghostty: Ghostty.App) {
        self.ghostty = ghostty
        self.snapshotSource = nil
    }

    /// A model that reads its windows and tabs from `snapshot` instead of the
    /// real windows. For testing the draft editing logic. Applying a draft
    /// still acts on real windows.
    init(snapshot: @escaping @MainActor () -> [Row]) {
        self.ghostty = nil
        self.snapshotSource = snapshot
    }

    // MARK: Lifecycle

    /// Load the current windows and keep them up to date while there are no
    /// edits. Called when the manager is shown.
    func start() {
        if !isDirty { reload() }

        guard timer == nil else { return }

        // There's no notification for tab group membership or title changes,
        // so poll at a low frequency while visible.
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    /// Stop updating. Called when the manager is closed.
    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Discard any edits and reload the draft from the current windows.
    func reload() {
        let snapshot = currentSnapshot()
        rows = snapshot
        original = snapshot
        isStale = false
    }

    /// Refresh from the current windows. Called periodically while shown.
    func poll() {
        guard !isApplying else { return }
        let snapshot = currentSnapshot()

        // With no edits we just track reality (titles, new tabs, etc.).
        guard isDirty else {
            if snapshot != rows {
                rows = snapshot
                original = snapshot
            }
            isStale = false
            return
        }

        // With edits we keep the draft but flag if the layout changed
        // underneath it. Titles changing doesn't count.
        isStale = snapshot.map(\.id) != original.map(\.id)
    }

    // MARK: Editing

    /// Add a new window to the draft, with one new tab.
    func addWindow() {
        rows.append(.window(Self.newWindowRow()))
        rows.append(.tab(Self.newTabRow()))
    }

    /// Add a new tab at the end of a window.
    func addTab(to windowID: String) {
        guard let range = sectionRange(windowID) else { return }
        rows.insert(.tab(Self.newTabRow()), at: range.upperBound)
    }

    func rename(_ windowID: String, to name: String) {
        guard let i = rows.firstIndex(where: { $0.id == "w:\(windowID)" }),
              case .window(var w) = rows[i] else { return }
        w.name = name
        rows[i] = .window(w)
    }

    /// Remove a window and all of its tabs from the draft.
    func deleteWindow(_ windowID: String) {
        guard let range = sectionRange(windowID) else { return }
        rows.removeSubrange(range)
    }

    /// Remove a tab from the draft.
    func deleteTab(_ tabID: String) {
        rows.removeAll { $0.id == "t:\(tabID)" }
    }

    /// Move a tab to the end of another window.
    func moveTab(_ tabID: String, to windowID: String) {
        let before = rows
        guard let i = rows.firstIndex(where: { $0.id == "t:\(tabID)" }) else { return }
        let row = rows.remove(at: i)
        guard let range = sectionRange(windowID) else {
            rows = before
            return
        }
        rows.insert(row, at: range.upperBound)
        rejectIfLocked(revertingTo: before)
    }

    /// Move a tab into a new window of its own.
    func moveTabToNewWindow(_ tabID: String) {
        guard let i = rows.firstIndex(where: { $0.id == "t:\(tabID)" }) else { return }
        let row = rows.remove(at: i)
        rows.append(.window(Self.newWindowRow()))
        rows.append(row)
    }

    /// Handle a drag reorder in the list. A tab belongs to the nearest window
    /// row above it, so moving a tab row below another window's row moves it
    /// into that window.
    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        let before = rows
        rows.move(fromOffsets: source, toOffset: destination)

        // Tabs dragged above the first window join the first window.
        if let firstWindow = rows.firstIndex(where: { if case .window = $0 { return true }; return false }),
           firstWindow > 0 {
            let leading = rows[0..<firstWindow]
            rows.removeSubrange(0..<firstWindow)
            rows.insert(contentsOf: leading, at: 1)
        }

        rejectIfLocked(revertingTo: before)
    }

    func name(of windowID: String) -> String {
        for case .window(let w) in rows where w.id == windowID { return w.name }
        return ""
    }

    func defaultName(of windowID: String) -> String {
        var index = 0
        for case .window(let w) in rows {
            index += 1
            if w.id == windowID { break }
        }
        return "Window \(index)"
    }

    func tabCount(in windowID: String) -> Int {
        sectionRange(windowID).map { $0.count - 1 } ?? 0
    }

    /// Windows a tab can be moved to.
    func moveTargets(for tabID: String) -> [WindowRow] {
        sections
            .filter { $0.window.lockReason == nil && !$0.tabs.contains { $0.id == tabID } }
            .map(\.window)
    }

    // MARK: Immediate Actions

    /// Bring a tab (and its window) to the front and focus it. This doesn't
    /// change the layout so it happens immediately.
    func focus(_ tabID: String) {
        guard let window = window(forTab: tabID) else { return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.tabGroup?.selectedWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Highlight the given tab in the list.
    func highlight(_ window: NSWindow?) {
        highlightedTabID = window.map(Self.tabID(for:))
    }

    // MARK: Apply

    /// A summary of tabs that will be closed by applying, for confirmation.
    var closeSummary: String? {
        let closing = tabsToClose
        guard !closing.isEmpty else { return nil }
        var message = closing.count == 1
            ? "1 tab will be closed."
            : "\(closing.count) tabs will be closed."
        let running = closing.filter(\.needsConfirmQuit).map { "\u{201C}\($0.title)\u{201D}" }
        switch running.count {
        case 0:
            break
        case 1:
            message += " \(running[0]) has a running process that will be killed."
        default:
            message += " \(running.count) of them have running processes that will be killed: \(Self.list(running))."
        }
        return message
    }

    /// Apply the draft to the real windows.
    func apply() {
        guard isDirty, !isApplying else { return }

        if let error = lockViolation() {
            errorMessage = error
            return
        }

        isApplying = true
        let sections = self.sections

        // Close removed tabs first so they don't get in the way of moves.
        for tab in tabsToClose {
            guard let controller = window(forTab: tab.id)?.windowController as? TerminalController else { continue }
            controller.closeTabImmediately()
        }

        // Let AppKit settle its tab group state after closing before
        // rearranging.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let failed = self.arrange(sections)

            for controller in TerminalController.all {
                controller.relabelTabs()
                controller.window?.invalidateRestorableState()
            }

            if failed {
                self.errorMessage = "Some tabs couldn't be moved. The list shows the current windows."
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.isApplying = false
                self?.reload()
            }
        }
    }

    /// Rearrange the real windows to match the given sections. Returns true
    /// if anything failed.
    private func arrange(_ sections: [Section]) -> Bool {
        var failed = false

        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        defer { NSAnimationContext.endGrouping() }

        // Each window is built around its first tab (its "anchor") by adding
        // the rest of its tabs after it in order. Anchors that currently
        // share a native tab group must be split apart first or two windows
        // would collapse into one.
        var claimed = Set<ObjectIdentifier>()
        for section in sections {
            guard let first = section.tabs.first, !first.isNew,
                  let window = window(forTab: first.id) else { continue }
            if let group = window.tabGroup, claimed.contains(ObjectIdentifier(group)) {
                detach(window)
            }
            if let group = window.tabGroup {
                claimed.insert(ObjectIdentifier(group))
            }
        }

        for section in sections where !section.tabs.isEmpty {
            var previous: NSWindow?
            var controllers: [TerminalController] = []

            for tab in section.tabs {
                let window: NSWindow?
                if tab.isNew {
                    guard let ghostty else { continue }
                    if let previous {
                        window = TerminalController.newTab(ghostty, from: previous)?.window
                    } else {
                        window = TerminalController.newWindow(ghostty).window
                    }
                } else {
                    window = self.window(forTab: tab.id)
                }

                // The tab may have been closed outside the manager.
                guard let window else { continue }

                if let previous, !place(window, after: previous) {
                    failed = true
                }

                previous = window
                if let controller = window.windowController as? TerminalController {
                    controllers.append(controller)
                }
            }

            let name = section.window.name.trimmingCharacters(in: .whitespacesAndNewlines)
            for controller in controllers {
                controller.windowName = name.isEmpty ? nil : name
            }
        }

        return failed
    }

    /// Put `window` in the same native tab group as `previous`, directly
    /// after it. Returns false if AppKit refused.
    private func place(_ window: NSWindow, after previous: NSWindow) -> Bool {
        // Already in place
        if let group = previous.tabGroup,
           let i = group.windows.firstIndex(of: previous),
           i + 1 < group.windows.count,
           group.windows[i + 1] == window {
            return true
        }

        // Strange things happen when tabbing into or out of minimized windows.
        if window.isMiniaturized { window.deminiaturize(nil) }
        if let selected = previous.tabGroup?.selectedWindow, selected.isMiniaturized {
            selected.deminiaturize(nil)
        }

        if let group = window.tabGroup, group.windows.count > 1 {
            group.removeWindow(window)
        }

        return previous.addTabbedWindowSafely(window, ordered: .above)
    }

    /// Move a tab out of its native tab group into a window of its own.
    private func detach(_ window: NSWindow) {
        guard let group = window.tabGroup, group.windows.count > 1 else { return }
        let frame = window.frame
        group.removeWindow(window)

        // Offset the new window so it doesn't sit exactly on top of the old one.
        window.setFrame(frame.offsetBy(dx: 30, dy: -30), display: true)
        window.orderFront(nil)
    }

    // MARK: Validation

    /// Returns why the draft can't be applied because of a locked window, if so.
    private func lockViolation() -> String? {
        for section in sections {
            if let reason = section.window.lockReason,
               section.tabs.contains(where: { $0.isNew || $0.originalWindowID != section.window.id }) {
                return reason
            }

            if let tab = section.tabs.first(where: { $0.lockReason != nil && $0.originalWindowID != section.window.id }) {
                return tab.lockReason
            }
        }

        return nil
    }

    private func rejectIfLocked(revertingTo before: [Row]) {
        if let error = lockViolation() {
            rows = before
            errorMessage = error
        }
    }

    // MARK: Snapshot

    private func currentSnapshot() -> [Row] {
        snapshotSource?() ?? makeSnapshot()
    }

    private func makeSnapshot() -> [Row] {
        var found: [String: [Row]] = [:]
        var foundOrder: [String] = []

        for controller in TerminalController.all {
            guard let window = controller.window else { continue }
            let windowID = Self.groupID(for: window)
            guard found[windowID] == nil else { continue }

            let windows = window.tabGroup?.windows ?? [window]
            let controllers = windows.compactMap { $0.windowController as? TerminalController }
            guard !controllers.isEmpty else { continue }

            // Skip windows that aren't on screen (e.g. mid-close).
            guard windows.contains(where: { $0.isVisible || $0.isMiniaturized }) else { continue }

            let lockReason: String?
            if windows.contains(where: { $0.tabbingMode == .disallowed }) {
                lockReason = "Windows using the hidden titlebar style don't support tabs."
            } else if controllers.contains(where: { $0.fullscreenStyle?.isFullscreen ?? false }) {
                lockReason = "Tabs can't be moved into or out of a fullscreen window. Exit fullscreen and try again."
            } else {
                lockReason = nil
            }

            let name = controllers.lazy.compactMap(\.windowName).first { !$0.isEmpty } ?? ""
            var rows: [Row] = [.window(.init(id: windowID, name: name, isNew: false, lockReason: lockReason))]
            for c in controllers {
                guard let w = c.window else { continue }
                rows.append(.tab(.init(
                    id: Self.tabID(for: w),
                    isNew: false,
                    title: Self.title(for: c),
                    subtitle: c.focusedSurface?.pwd?.abbreviatedPath,
                    color: Self.color(for: w),
                    needsConfirmQuit: c.surfaceTree.contains(where: { $0.needsConfirmQuit }),
                    originalWindowID: windowID,
                    lockReason: lockReason
                )))
            }

            found[windowID] = rows
            foundOrder.append(windowID)
        }

        // Keep the existing order and append new windows at the end.
        order = order.filter { found[$0] != nil } + foundOrder.filter { !order.contains($0) }
        return order.flatMap { found[$0] ?? [] }
    }

    // MARK: Helpers

    /// Join names into an English list, e.g. "a, b, and c".
    private static func list(_ names: [String]) -> String {
        switch names.count {
        case 0: return ""
        case 1: return names[0]
        case 2: return "\(names[0]) and \(names[1])"
        default: return names.dropLast().joined(separator: ", ") + ", and \(names[names.count - 1])"
        }
    }

    /// The range of rows for a window: its window row and its tab rows.
    private func sectionRange(_ windowID: String) -> Range<Int>? {
        guard let start = rows.firstIndex(where: { $0.id == "w:\(windowID)" }) else { return nil }
        var end = start + 1
        while end < rows.count, case .tab = rows[end] { end += 1 }
        return start..<end
    }

    private static func newWindowRow() -> WindowRow {
        .init(id: "new-\(UUID().uuidString)", name: "", isNew: true, lockReason: nil)
    }

    private static func newTabRow() -> TabRow {
        .init(
            id: "new-\(UUID().uuidString)",
            isNew: true,
            title: "New Tab",
            subtitle: nil,
            color: nil,
            needsConfirmQuit: false,
            originalWindowID: nil,
            lockReason: nil
        )
    }

    private func window(forTab id: String) -> NSWindow? {
        TerminalController.all.lazy
            .compactMap(\.window)
            .first { Self.tabID(for: $0) == id }
    }

    private static func tabID(for window: NSWindow) -> String {
        ObjectIdentifier(window).hexString
    }

    private static func groupID(for window: NSWindow) -> String {
        if let tabGroup = window.tabGroup {
            return "group-\(ObjectIdentifier(tabGroup).hexString)"
        }

        return "window-\(ObjectIdentifier(window).hexString)"
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

    private static func color(for window: NSWindow) -> NSColor? {
        guard let color = (window as? TerminalWindow)?.tabColor,
              color != TerminalTabColor.none else { return nil }
        return color.displayColor
    }
}
