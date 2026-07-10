import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Maps apps to modes so dictation automatically uses the right mode wherever you're typing
/// (e.g. Email in Mail, Code Comment in Xcode). Frontmost-app detection uses NSWorkspace, so
/// this needs NO Accessibility permission. The resolution itself lives in
/// `ModeStore.resolvedMode` and runs when a dictation starts.
struct PerAppModesSection: View {
    @Environment(AppState.self) private var state

    var body: some View {
        CardSection("Per-app modes") {
            let entries = sortedEntries
            if entries.isEmpty {
                Caption("Add an app to make YapToText switch to a chosen mode automatically whenever that app is in front. Everywhere else keeps using your current mode.")
            } else {
                ForEach(entries, id: \.self) { bundleID in
                    row(bundleID: bundleID)
                }
            }
            HStack {
                addMenu
                Spacer()
            }
            Divider().opacity(0.4)
            HStack(spacing: 8) {
                Image(systemName: "info.circle").foregroundStyle(.secondary)
                Text("Don't forget: you can edit each mode's prompt in Modes.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button("Edit Modes") { NotificationCenter.default.post(name: .yapShowModes, object: nil) }
                    .buttonStyle(.solidSecondary).controlSize(.small)
            }
        }
    }

    private var sortedEntries: [String] {
        state.settings.perAppModeOverrides.keys.sorted {
            AppCatalog.name(for: $0).localizedCaseInsensitiveCompare(AppCatalog.name(for: $1)) == .orderedAscending
        }
    }

    private func row(bundleID: String) -> some View {
        let binding = Binding<UUID>(
            get: {
                // Only surface an override that still resolves to a real mode; a dangling one
                // (mode deleted out from under it) falls back so the Picker never goes blank.
                if let id = state.settings.perAppModeOverrides[bundleID], state.modeStore.mode(withID: id) != nil {
                    return id
                }
                return state.settings.activeModeID
            },
            set: { state.settings.perAppModeOverrides[bundleID] = $0 })
        return HStack(spacing: 10) {
            AppIconView(bundleID: bundleID)
            Text(AppCatalog.name(for: bundleID)).lineLimit(1)
            Spacer(minLength: 8)
            Picker("", selection: binding) {
                ForEach(state.modeStore.allModes) { Text($0.name).tag($0.id) }
            }
            .labelsHidden()
            .frame(maxWidth: 190)
            Button {
                state.settings.perAppModeOverrides.removeValue(forKey: bundleID)
            } label: {
                Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Remove this app")
            .accessibilityLabel("Remove \(AppCatalog.name(for: bundleID))")
        }
    }

    private var addMenu: some View {
        Menu {
            let running = AppCatalog.runningApps().filter { state.settings.perAppModeOverrides[$0.bundleID] == nil }
            if running.isEmpty {
                Text("No other apps running")
            } else {
                ForEach(running, id: \.bundleID) { app in
                    Button(app.name) { state.settings.perAppModeOverrides[app.bundleID] = state.settings.activeModeID }
                }
            }
            Divider()
            Button("Choose App…") { chooseApp() }
        } label: {
            Label("Add app", systemImage: "plus")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK, let url = panel.url,
              let id = Bundle(url: url)?.bundleIdentifier,
              id != Bundle.main.bundleIdentifier,                       // not YapToText itself
              state.settings.perAppModeOverrides[id] == nil else { return }   // not already mapped
        state.settings.perAppModeOverrides[id] = state.settings.activeModeID
    }
}

/// Small helpers for turning a bundle identifier into a display name and icon, whether or not
/// the app is currently running.
enum AppCatalog {
    struct RunningApp { let bundleID: String; let name: String }

    static func runningApps() -> [RunningApp] {
        let selfID = Bundle.main.bundleIdentifier
        var seen = Set<String>()
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app -> RunningApp? in
                guard let id = app.bundleIdentifier, id != selfID, seen.insert(id).inserted else { return nil }
                return RunningApp(bundleID: id, name: app.localizedName ?? id)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func url(for bundleID: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }

    static func name(for bundleID: String) -> String {
        if let running = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleID }),
           let name = running.localizedName { return name }
        if let url = url(for: bundleID) {
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        return bundleID
    }

    static func icon(for bundleID: String) -> NSImage? {
        guard let url = url(for: bundleID) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}

private struct AppIconView: View {
    let bundleID: String
    var body: some View {
        Group {
            if let icon = AppCatalog.icon(for: bundleID) {
                Image(nsImage: icon).resizable().interpolation(.high)
            } else {
                Image(systemName: "app.dashed").resizable().foregroundStyle(.secondary)
            }
        }
        .frame(width: 20, height: 20)
        .accessibilityHidden(true)
    }
}
