import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The Modes pathway: a list of modes in the middle pane; selecting one pushes its editor.
/// New / Import / Restore live in the toolbar here rather than in the app-wide sidebar.
struct ModesView: View {
    @Environment(AppState.self) private var state
    @Binding var path: [UUID]

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    HStack(spacing: 7) {
                        Image(systemName: "hand.tap.fill").font(.caption).foregroundStyle(.secondary)
                        Text("Click any mode to edit its prompt, model, dictionaries, and output.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .listRowBackground(Color.clear)
                }
                Section {
                    autoModeRow
                }
                // ONE flat list, no categories: drag any mode anywhere; the switcher digits
                // renumber automatically because they simply follow this order.
                Section {
                    ForEach(state.modeStore.allModes) { modeRow($0) }
                        .onMove { source, destination in
                            state.modeStore.moveModes(fromOffsets: source, toOffset: destination)
                        }
                }
            }
            .scrollContentBackground(.hidden)
            .navigationTitle("Modes")
            .navigationDestination(for: UUID.self) { id in
                if let mode = state.modeStore.mode(withID: id) {
                    ModeDetailView(mode: mode, onSelect: { path = [$0] })
                } else if id == BuiltInModes.auto.id {
                    // Auto isn't stored until first edited; hand the editor the built-in
                    // definition (ModeStore.update adopts it on the first change).
                    ModeDetailView(mode: BuiltInModes.auto, onSelect: { path = [$0] })
                } else {
                    ContentUnavailableView("Mode not found", systemImage: "questionmark.circle")
                }
            }
            .toolbar {
                ToolbarItem {
                    Button {
                        state.modeStore.undoLastChange()
                    } label: { Image(systemName: "arrow.uturn.backward") }
                        .disabled(!state.modeStore.canUndo)
                        .help("Undo the last mode change (rename, prompt edit, reorder, delete)")
                }
                ToolbarItem {
                    Menu {
                        Button("New Mode") { newMode() }
                        Button("Import Mode…") { importMode() }
                        Divider()
                        Button("Restore Built-in Modes") { state.modeStore.restoreBuiltIns() }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .help("Add or restore modes")
                }
            }
        }
    }

    /// Auto mode lives at the top of the mode list, whether it's on or off. Turning it on gives
    /// it slot 1 in every switcher; turning it off removes it from switchers but never from here.
    private var autoModeRow: some View {
        @Bindable var settings = state.settings
        // A NavigationLink like every other mode: Auto opens in the editor too. The toggle
        // still flips it on/off without navigating.
        return NavigationLink(value: BuiltInModes.auto.id) {
            HStack(spacing: 10) {
                Image(systemName: "wand.and.sparkles").iconTint(Color.accentColor).frame(width: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Auto").font(.body.weight(.medium))
                    Text(settings.autoContextMode
                         ? "On. It's slot 1 in the mode switcher; press 1 mid-dictation to use it, 2-9 to override once."
                         : "Off. Turn it on to let the app read each dictation and pick the right mode by itself.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Toggle("", isOn: $settings.autoContextMode)
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
                    .onChange(of: settings.autoContextMode) { state.controller.refreshActiveMode() }
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
    }

    private func modeRow(_ mode: Mode) -> some View {
        let isActive = mode.id == state.settings.activeModeID
        // The digit this mode answers to while dictating (press 1-9 mid-sentence) - shown
        // right on the row so the numbering is never a mystery.
        let digit = state.settings.digitModeSwitching
            ? state.controller.switchableModes.prefix(9).firstIndex(where: { $0.id == mode.id }).map { $0 + 1 }
            : nil
        return NavigationLink(value: mode.id) {
            HStack(spacing: 10) {
                IconBadge(symbol: mode.iconSystemName, tint: isActive ? .green : .accentColor, size: 26)
                // The dictation digit sits right after the icon, before the name.
                if let digit {
                    Text("\(digit)")
                        .font(.system(size: 9, weight: .bold).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 15, height: 15)
                        .background(Color.secondary.opacity(0.15), in: Circle())
                        .help("Press \(digit) while dictating to switch to this mode")
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(mode.name).lineLimit(1)
                    Text(mode.usesAI ? "AI cleanup" : "Verbatim")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                Spacer(minLength: 6)
                if isActive {
                    StatusPill(text: "Current", tint: .green)
                        .accessibilityLabel("Current mode")
                }
                // AI cleanup, right on the row: one click to make any mode verbatim and
                // back - no digging into the editor to get the raw transcript.
                Toggle("", isOn: Binding(
                    get: { mode.usesAI },
                    set: { on in
                        var updated = mode
                        updated.usesAI = on
                        state.modeStore.update(updated)
                    }))
                    .toggleStyle(.switch).controlSize(.mini).labelsHidden()
                    .help(mode.usesAI ? "AI cleanup is on. Switch off to type your words exactly as spoken."
                                      : "Verbatim. Switch on to clean up the transcript with AI.")
                    .accessibilityLabel("AI cleanup for \(mode.name)")
                // Obvious "editable" affordance.
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .contextMenu {
            if !isActive {
                Button("Use This Mode") { state.controller.selectMode(mode) }
            }
            Button("Move Up") { state.modeStore.move(mode, up: true) }
            Button("Move Down") { state.modeStore.move(mode, up: false) }
            Divider()
            Button("Duplicate") { let copy = state.modeStore.duplicate(mode); path = [copy.id] }
            Button("Export Mode…") { export(mode) }
            Divider()
            if BuiltInModes.isBuiltIn(mode.id) {
                Button("Reset to Default") { state.modeStore.resetToDefault(mode) }
            } else {
                Button("Delete", role: .destructive) { delete(mode) }
            }
        }
    }

    // MARK: Actions

    private func newMode() {
        let mode = Mode(name: "New Mode", iconSystemName: "wand.and.stars",
                        summary: "", usesAI: true, instructions: "", isBuiltIn: false)
        state.modeStore.addCustomMode(mode)
        path = [mode.id]
    }

    private func delete(_ mode: Mode) {
        state.modeStore.delete(mode)
        state.settings.perAppModeOverrides = state.settings.perAppModeOverrides.filter { $0.value != mode.id }
        path.removeAll { $0 == mode.id }
    }

    private func export(_ mode: Mode) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(mode.name).yaptotextmode.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModalInFront() == .OK, let url = panel.url,
              let data = try? JSONEncoder().encode(mode) else { return }
        try? data.write(to: url)
    }

    private func importMode() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModalInFront() == .OK, let url = panel.url,
              let data = try? Data(contentsOf: url),
              var mode = try? JSONDecoder().decode(Mode.self, from: data) else { return }
        mode.id = UUID()
        mode.isBuiltIn = false
        state.modeStore.addCustomMode(mode)
        path = [mode.id]
    }
}
