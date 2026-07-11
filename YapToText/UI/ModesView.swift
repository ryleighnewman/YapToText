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
                if !state.modeStore.customModes.isEmpty {
                    Section("Custom") {
                        ForEach(state.modeStore.customModes) { modeRow($0) }
                    }
                }
                Section("Built-in") {
                    ForEach(state.modeStore.builtInModes) { modeRow($0) }
                }
            }
            .scrollContentBackground(.hidden)
            .navigationTitle("Modes")
            .navigationDestination(for: UUID.self) { id in
                if let mode = state.modeStore.mode(withID: id) {
                    ModeDetailView(mode: mode, onSelect: { path = [$0] })
                } else {
                    ContentUnavailableView("Mode not found", systemImage: "questionmark.circle")
                }
            }
            .toolbar {
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
        return HStack(spacing: 10) {
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
        }
        .padding(.vertical, 4)
    }

    private func modeRow(_ mode: Mode) -> some View {
        let isActive = mode.id == state.settings.activeModeID
        return NavigationLink(value: mode.id) {
            HStack(spacing: 10) {
                IconBadge(symbol: mode.iconSystemName, tint: isActive ? .green : .accentColor, size: 26)
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
        guard panel.runModal() == .OK, let url = panel.url,
              let data = try? JSONEncoder().encode(mode) else { return }
        try? data.write(to: url)
    }

    private func importMode() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url,
              let data = try? Data(contentsOf: url),
              var mode = try? JSONDecoder().decode(Mode.self, from: data) else { return }
        mode.id = UUID()
        mode.isBuiltIn = false
        state.modeStore.addCustomMode(mode)
        path = [mode.id]
    }
}
