//
//  WindowManagerModelTests.swift
//  GhosttyTests
//
//  Tests for the "Windows & Tabs" manager's draft editing: moving, closing,
//  and renaming are staged in the draft and only reach real windows on Apply.
//

import Testing
import AppKit
@testable import Ghostty

@MainActor
struct WindowManagerModelTests {
    typealias Model = WindowManagerModel

    /// Stands in for the real windows so tests can change them between polls.
    final class Source {
        var rows: [Model.Row]
        init(_ rows: [Model.Row]) { self.rows = rows }
    }

    // MARK: Fixtures

    static func window(_ id: String, name: String = "", locked: String? = nil) -> Model.Row {
        .window(.init(id: id, name: name, isNew: false, lockReason: locked))
    }

    static func tab(
        _ id: String,
        in window: String,
        title: String? = nil,
        running: Bool = false,
        locked: String? = nil
    ) -> Model.Row {
        .tab(.init(
            id: id,
            isNew: false,
            title: title ?? id,
            subtitle: nil,
            color: nil,
            needsConfirmQuit: running,
            originalWindowID: window,
            lockReason: locked
        ))
    }

    /// Two windows: A with tabs a1 and a2, and B with tab b1.
    /// Row offsets: 0 A, 1 a1, 2 a2, 3 B, 4 b1.
    static func twoWindows(
        aLocked: String? = nil,
        bLocked: String? = nil,
        a1Running: Bool = false
    ) -> [Model.Row] {
        [
            window("A", locked: aLocked),
            tab("a1", in: "A", running: a1Running, locked: aLocked),
            tab("a2", in: "A", locked: aLocked),
            window("B", locked: bLocked),
            tab("b1", in: "B", locked: bLocked),
        ]
    }

    func makeModel(_ rows: [Model.Row]? = nil) -> Model {
        let rows = rows ?? Self.twoWindows()
        let model = Model(snapshot: { rows })
        model.reload()
        return model
    }

    /// The draft as one string per window, e.g. "A: a1 a2". New windows
    /// show as "new" and new tabs as "+".
    func layout(_ model: Model) -> [String] {
        model.sections.map { section in
            let window = section.window.isNew ? "new" : section.window.id
            let tabs = section.tabs.map { $0.isNew ? "+" : $0.id }
            return ([window + ":"] + tabs).joined(separator: " ")
        }
    }

    // MARK: Loading

    @Test func loadsWithoutChanges() {
        let model = makeModel()
        #expect(layout(model) == ["A: a1 a2", "B: b1"])
        #expect(!model.isDirty)
        #expect(model.tabsToClose.isEmpty)
        #expect(model.closeSummary == nil)
    }

    @Test func reloadDiscardsEdits() {
        let model = makeModel()
        model.deleteWindow("A")
        model.rename("B", to: "Work")
        #expect(model.isDirty)

        model.reload()
        #expect(layout(model) == ["A: a1 a2", "B: b1"])
        #expect(model.name(of: "B") == "")
        #expect(!model.isDirty)
    }

    // MARK: Dragging

    @Test func draggingTabBelowAnotherWindowMovesIt() {
        let model = makeModel()
        model.move(fromOffsets: [1], toOffset: 5)
        #expect(layout(model) == ["A: a2", "B: b1 a1"])
        #expect(model.isDirty)
        #expect(model.tabsToClose.isEmpty)
    }

    @Test func draggingWithinAWindowReorders() {
        let model = makeModel()
        model.move(fromOffsets: [2], toOffset: 1)
        #expect(layout(model) == ["A: a2 a1", "B: b1"])
    }

    @Test func draggingAboveTheFirstWindowJoinsIt() {
        let model = makeModel()
        model.move(fromOffsets: [4], toOffset: 0)
        #expect(layout(model) == ["A: b1 a1 a2", "B:"])
        #expect(model.tabCount(in: "B") == 0)
    }

    @Test func draggingBackRestoresACleanDraft() {
        let model = makeModel()
        model.move(fromOffsets: [1], toOffset: 5)
        model.move(fromOffsets: [4], toOffset: 1)
        #expect(layout(model) == ["A: a1 a2", "B: b1"])
        #expect(!model.isDirty)
    }

    // MARK: Move Menu

    @Test func moveTargetsExcludeCurrentAndLockedWindows() {
        let rows = Self.twoWindows() + [Self.window("C", locked: "locked"), Self.tab("c1", in: "C", locked: "locked")]
        let model = makeModel(rows)
        #expect(model.moveTargets(for: "a1").map(\.id) == ["B"])
        #expect(model.moveTargets(for: "b1").map(\.id) == ["A"])
    }

    @Test func moveTabAppendsToTarget() {
        let model = makeModel()
        model.moveTab("a1", to: "B")
        #expect(layout(model) == ["A: a2", "B: b1 a1"])
    }

    @Test func moveTabToNewWindow() {
        let model = makeModel()
        model.moveTabToNewWindow("a1")
        #expect(layout(model) == ["A: a2", "B: b1", "new: a1"])
        #expect(model.tabsToClose.isEmpty)
    }

    // MARK: Locked Windows

    @Test func lockedWindowRejectsDraggedTab() {
        let model = makeModel(Self.twoWindows(bLocked: "B is fullscreen"))
        model.move(fromOffsets: [1], toOffset: 5)
        #expect(layout(model) == ["A: a1 a2", "B: b1"])
        #expect(model.errorMessage == "B is fullscreen")
        #expect(!model.isDirty)
    }

    @Test func lockedTabCannotLeaveItsWindow() {
        let model = makeModel(Self.twoWindows(aLocked: "A is fullscreen"))
        model.moveTab("a1", to: "B")
        #expect(layout(model) == ["A: a1 a2", "B: b1"])
        #expect(model.errorMessage == "A is fullscreen")
    }

    @Test func lockedWindowCanStillBeRenamedAndClosed() {
        let model = makeModel(Self.twoWindows(aLocked: "A is fullscreen"))
        model.rename("A", to: "Work")
        #expect(model.name(of: "A") == "Work")
        model.deleteTab("a2")
        #expect(layout(model) == ["A: a1", "B: b1"])
        #expect(model.errorMessage == nil)
    }

    // MARK: Closing

    @Test func deletingAWindowClosesItsTabs() {
        let model = makeModel()
        model.deleteWindow("A")
        #expect(layout(model) == ["B: b1"])
        #expect(model.tabsToClose.map(\.id) == ["a1", "a2"])
        #expect(model.closeSummary == "2 tabs will be closed.")
    }

    @Test func closeSummaryNamesTabsWithRunningProcesses() {
        let one = makeModel(Self.twoWindows(a1Running: true))
        one.deleteTab("a1")
        #expect(one.closeSummary == "1 tab will be closed. \u{201C}a1\u{201D} has a running process that will be killed.")

        let two = makeModel(Self.twoWindows(a1Running: true))
        two.deleteWindow("A")
        #expect(two.closeSummary == "2 tabs will be closed. \u{201C}a1\u{201D} has a running process that will be killed.")

        func closingAll(running count: Int) -> String? {
            let titles = ["vim", "top", "ssh", "make", "tail"]
            let rows = [Self.window("A")]
                + titles.enumerated().map { i, title in
                    Self.tab("a\(i)", in: "A", title: title, running: i < count)
                }
            let model = makeModel(rows)
            model.deleteWindow("A")
            return model.closeSummary
        }

        #expect(closingAll(running: 2) == "5 tabs will be closed. 2 of them have running processes that will be killed: \u{201C}vim\u{201D} and \u{201C}top\u{201D}.")
        #expect(closingAll(running: 3) == "5 tabs will be closed. 3 of them have running processes that will be killed: \u{201C}vim\u{201D}, \u{201C}top\u{201D}, and \u{201C}ssh\u{201D}.")
        #expect(closingAll(running: 5) == "5 tabs will be closed. 5 of them have running processes that will be killed: \u{201C}vim\u{201D}, \u{201C}top\u{201D}, \u{201C}ssh\u{201D}, \u{201C}make\u{201D}, and \u{201C}tail\u{201D}.")
    }

    // MARK: Adding

    @Test func addTabGoesAtTheEndOfItsWindow() {
        let model = makeModel()
        model.addTab(to: "A")
        #expect(layout(model) == ["A: a1 a2 +", "B: b1"])
        #expect(model.tabCount(in: "A") == 3)
        #expect(model.isDirty)
    }

    @Test func removingNewTabsAndWindowsLeavesNothingToApply() {
        let model = makeModel()
        model.addTab(to: "A")
        model.addWindow()
        #expect(layout(model) == ["A: a1 a2 +", "B: b1", "new: +"])

        for section in model.sections {
            if section.window.isNew { model.deleteWindow(section.window.id) }
            for tab in section.tabs where tab.isNew { model.deleteTab(tab.id) }
        }

        #expect(layout(model) == ["A: a1 a2", "B: b1"])
        #expect(model.tabsToClose.isEmpty)
        #expect(!model.isDirty)
    }

    // MARK: Naming

    @Test func renamingBackIsNotAChange() {
        let model = makeModel()
        model.rename("A", to: "Work")
        #expect(model.name(of: "A") == "Work")
        #expect(model.isDirty)

        model.rename("A", to: "")
        #expect(!model.isDirty)
    }

    @Test func defaultNamesFollowListOrder() {
        let model = makeModel()
        #expect(model.defaultName(of: "A") == "Window 1")
        #expect(model.defaultName(of: "B") == "Window 2")
    }

    // MARK: Polling

    @Test func pollFollowsWindowsWhileThereAreNoEdits() {
        let source = Source(Self.twoWindows())
        let model = Model(snapshot: { source.rows })
        model.reload()

        source.rows.append(Self.tab("b2", in: "B"))
        model.poll()

        #expect(layout(model) == ["A: a1 a2", "B: b1 b2"])
        #expect(!model.isDirty)
        #expect(!model.isStale)
    }

    @Test func pollKeepsEditsAndFlagsLayoutChanges() {
        let source = Source(Self.twoWindows())
        let model = Model(snapshot: { source.rows })
        model.reload()
        model.moveTab("a1", to: "B")

        // A title change isn't a layout change.
        source.rows[1] = Self.tab("a1", in: "A", title: "vim")
        model.poll()
        #expect(!model.isStale)
        #expect(layout(model) == ["A: a2", "B: b1 a1"])

        // A new tab is.
        source.rows.append(Self.tab("b2", in: "B"))
        model.poll()
        #expect(model.isStale)
        #expect(layout(model) == ["A: a2", "B: b1 a1"])

        model.reload()
        #expect(!model.isStale)
        #expect(layout(model) == ["A: a1 a2", "B: b1 b2"])
    }
}
