import SwiftUI

/// The "Windows & Tabs" manager: lists every terminal window and its tabs
/// and lets the user create, rename, and delete windows and move and close
/// tabs. Edits are staged and only take effect when the user clicks Apply.
struct WindowManagerView: View {
    @ObservedObject var model: WindowManagerModel

    @State private var confirmingApply = false

    var body: some View {
        VStack(spacing: 0) {
            Text("Drag tabs to rearrange them. Changes take effect when you click Apply.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

            if model.isStale {
                staleBanner
            }

            Divider()

            ScrollViewReader { proxy in
                List {
                    ForEach(model.rows) { row in
                        switch row {
                        case .window(let window):
                            WindowHeaderRow(window: window, model: model)
                                .moveDisabled(true)

                        case .tab(let tab):
                            TabRowView(tab: tab, model: model)
                                .moveDisabled(tab.lockReason != nil)
                                .listRowBackground(
                                    model.highlightedTabID == tab.id
                                        ? Color.accentColor.opacity(0.18)
                                        : Color.clear
                                )
                        }
                    }
                    .onMove { source, destination in
                        model.move(fromOffsets: source, toOffset: destination)
                    }
                }
                .listStyle(.inset)
                .onReceive(model.$highlightedTabID) { id in
                    guard let id else { return }
                    DispatchQueue.main.async {
                        proxy.scrollTo("t:\(id)", anchor: .center)
                    }
                }
            }

            Divider()

            footer
        }
        .frame(minWidth: 380, minHeight: 300)
        .confirmationDialog(
            "Apply Changes?",
            isPresented: $confirmingApply
        ) {
            Button("Apply and Close Tabs", role: .destructive) {
                model.apply()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(model.closeSummary ?? "")
        }
        .alert(
            "Can't Make That Change",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private var staleBanner: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text("Windows changed since you started editing.")
                .font(.caption)
            Spacer()
            Button("Reload") { model.reload() }
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private var footer: some View {
        HStack {
            Button {
                model.addWindow()
            } label: {
                Label("New Window", systemImage: "macwindow.badge.plus")
            }

            Spacer()

            if model.isDirty {
                Text("Unsaved changes")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button("Revert") {
                model.reload()
            }
            .disabled(!model.isDirty || model.isApplying)

            Button("Apply") {
                if model.closeSummary == nil {
                    model.apply()
                } else {
                    confirmingApply = true
                }
            }
            .keyboardShortcut("s", modifiers: .command)
            .buttonStyle(.borderedProminent)
            .disabled(!model.isDirty || model.isApplying)
            .help("Apply changes (⌘S)")
        }
        .padding(10)
    }
}

// MARK: - Window Row

private struct WindowHeaderRow: View {
    let window: WindowManagerModel.WindowRow
    @ObservedObject var model: WindowManagerModel

    var body: some View {
        let tabCount = model.tabCount(in: window.id)

        HStack(spacing: 6) {
            Image(systemName: "macwindow")
                .foregroundStyle(.secondary)

            TextField(
                model.defaultName(of: window.id),
                text: Binding(
                    get: { model.name(of: window.id) },
                    set: { model.rename(window.id, to: $0) }
                )
            )
            .textFieldStyle(.plain)
            .font(.headline)
            .help("Rename this window")

            if window.isNew {
                Badge(text: "New")
            }

            if let reason = window.lockReason {
                Image(systemName: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help(reason)
            }

            if tabCount == 0 {
                Text(window.isNew ? "Empty, won't be created" : "Empty, will be closed")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                model.addTab(to: window.id)
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .disabled(window.lockReason != nil)
            .help("Add a new tab to this window")

            Button {
                model.deleteWindow(window.id)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Delete this window and its tabs")
        }
        .padding(.top, 8)
        .padding(.bottom, 2)
    }
}

// MARK: - Tab Row

private struct TabRowView: View {
    let tab: WindowManagerModel.TabRow
    @ObservedObject var model: WindowManagerModel

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .opacity(tab.lockReason == nil ? 1 : 0)

            Circle()
                .fill(tab.color.map { Color(nsColor: $0) } ?? Color.clear)
                .overlay(Circle().strokeBorder(Color.secondary.opacity(tab.color == nil ? 0.4 : 0), lineWidth: 1))
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 1) {
                Text(tab.title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .italic(tab.isNew)

                if let subtitle = tab.subtitle, !tab.title.contains(subtitle) {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }

            if tab.isNew {
                Badge(text: "New")
            }

            Spacer()

            if tab.needsConfirmQuit {
                Image(systemName: "gearshape.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("A process is running in this tab")
            }

            Menu {
                menuItems
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Move or close this tab")
        }
        .padding(.leading, 12)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .contextMenu { menuItems }
    }

    @ViewBuilder
    private var menuItems: some View {
        Button("Show Tab") {
            model.focus(tab.id)
        }
        .disabled(tab.isNew)

        Divider()

        let targets = model.moveTargets(for: tab.id)
        Menu("Move to Window") {
            ForEach(targets, id: \.id) { target in
                Button(target.name.isEmpty ? model.defaultName(of: target.id) : target.name) {
                    model.moveTab(tab.id, to: target.id)
                }
            }

            if !targets.isEmpty {
                Divider()
            }

            Button("New Window") {
                model.moveTabToNewWindow(tab.id)
            }
        }
        .disabled(tab.lockReason != nil)

        Divider()

        Button("Close Tab") {
            model.deleteTab(tab.id)
        }
    }
}

private struct Badge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(Color.accentColor.opacity(0.2)))
    }
}
