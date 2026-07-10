import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Editor for spoken insert commands: two categories (Punctuation, Emoji) of trigger -> output
/// substitutions that run as you dictate. Same idea as the dictionary system, but purpose-built
/// for dropping in symbols. Everything is editable and there's a master on/off switch.
struct CommandsView: View {
    @Environment(AppState.self) private var state
    @State private var category: CommandCategory = .punctuation
    @State private var emojiTarget: UUID?

    var body: some View {
        SettingsPage {
            Text("Voice commands turn what you say into symbols while you dictate. Say a trigger phrase and it becomes the punctuation or emoji. Edit any trigger to whatever feels natural, like shortening \"exclamation point\" to just \"exclamation\".")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            Toggle("Enable voice commands", isOn: masterEnabled).toggleStyle(.switch).controlSize(.small)
            Toggle("Require the word \u{201C}insert\u{201D} before a command", isOn: requirePrefix)
                .toggleStyle(.switch).controlSize(.small)
                .disabled(!state.commands.isEnabled)
            if state.commands.requireInsertPrefix {
                SubOptions {
                    Caption("Say \u{201C}insert period\u{201D} instead of just \u{201C}period\u{201D}, so commands never replace normal speech by accident.")
                }
            }

            Picker("", selection: $category) {
                ForEach(CommandCategory.allCases) { Label($0.label, systemImage: $0.icon).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            commandList
                .opacity(state.commands.isEnabled ? 1 : 0.45)
                .disabled(!state.commands.isEnabled)

            HStack {
                Button { _ = state.commands.add(category: category) } label: {
                    Label("Add \(category.label)", systemImage: "plus")
                }
                .buttonStyle(.solid)
                Spacer()
                Button("Export All…") { exportCommands() }.buttonStyle(.solidSecondary)
                Button("Import…") { importCommands() }.buttonStyle(.solidSecondary)
                Button("Restore Defaults") { state.commands.restoreDefaults(for: category) }
                    .buttonStyle(.solidSecondary)
            }
            .disabled(!state.commands.isEnabled)
        }
        .navigationTitle("Commands")
    }

    private var commandList: some View {
        let items = state.commands.commands(in: category)
        return VStack(alignment: .leading, spacing: 8) {
            if items.isEmpty {
                Caption("No \(category.label.lowercased()) commands yet. Add one below.")
            } else {
                HStack(spacing: 8) {
                    Text("Say this (separate alternatives with commas)").frame(maxWidth: .infinity, alignment: .leading)
                    Text("Inserts").frame(width: 80)
                    Text("On").frame(width: 40)
                    Spacer().frame(width: 22)
                }
                .font(.caption).foregroundStyle(.secondary)
                ForEach(items) { command in row(command) }
                Caption(footnote(for: category))
            }
        }
    }

    private func footnote(for category: CommandCategory) -> String {
        switch category {
        case .punctuation:
            return "Give one command several phrases, like \u{201C}exclamation point, exclamation, bang\u{201D}. Type \\n in the Inserts box for a line break."
        case .emoji:
            return "Give one emoji several phrases, like \u{201C}fire emoji, flame emoji, lit emoji\u{201D}."
        case .snippet:
            return "Snippets paste whole blocks of text: addresses, sign-offs, links. Live tokens work in the Inserts box: {date}, {time}, and {clipboard}."
        }
    }

    private func row(_ command: SpokenCommand) -> some View {
        HStack(spacing: 8) {
            TextField(command.category.triggerPlaceholder, text: triggerBinding(command))
                .textFieldStyle(.plain)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .innerWell(radius: 7)
                .frame(maxWidth: .infinity)
            Image(systemName: "arrow.right").foregroundStyle(.secondary).font(.caption)
            TextField("", text: outputBinding(command))
                .textFieldStyle(.plain)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .innerWell(radius: 7)
                .multilineTextAlignment(command.category == .snippet ? .leading : .center)
                .frame(width: command.category == .snippet ? 210 : 74)
            if command.category == .emoji {
                Button { emojiTarget = command.id } label: {
                    Text("\u{1F600}").font(.system(size: 13))
                }
                .buttonStyle(.plain)
                .help("Pick an emoji")
                .popover(isPresented: Binding(get: { emojiTarget == command.id },
                                              set: { if !$0 { emojiTarget = nil } })) {
                    EmojiPickerView { emoji in
                        var c = current(command) ?? command
                        c.output = emoji
                        state.commands.update(c)
                        emojiTarget = nil
                    }
                }
            }
            Toggle("", isOn: enabledBinding(command))
                .toggleStyle(.switch).controlSize(.small).labelsHidden().frame(width: 40)
            Button { state.commands.delete(command) } label: {
                Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .frame(width: 22)
            .help("Delete")
            .accessibilityLabel("Delete command")
        }
    }


    // MARK: Export / import the whole command set (user preset for commands)

    private func exportCommands() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "YapToText Commands.yapcommands.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let snapshot = CommandStore.Snapshot(isEnabled: state.commands.isEnabled,
                                             requireInsertPrefix: state.commands.requireInsertPrefix,
                                             commands: state.commands.commands)
        if let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: url) }
    }

    private func importCommands() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url,
              let data = try? Data(contentsOf: url),
              let snapshot = try? JSONDecoder().decode(CommandStore.Snapshot.self, from: data) else { return }
        state.commands.replaceAll(with: snapshot)
    }

    // MARK: Bindings

    private var masterEnabled: Binding<Bool> {
        Binding(get: { state.commands.isEnabled }, set: { state.commands.isEnabled = $0 })
    }

    private var requirePrefix: Binding<Bool> {
        Binding(get: { state.commands.requireInsertPrefix }, set: { state.commands.requireInsertPrefix = $0 })
    }

    private func current(_ command: SpokenCommand) -> SpokenCommand? {
        state.commands.commands.first { $0.id == command.id }
    }

    private func triggerBinding(_ command: SpokenCommand) -> Binding<String> {
        Binding(get: { (current(command)?.triggers ?? command.triggers).joined(separator: ", ") },
                set: { value in
                    var c = current(command) ?? command
                    c.triggers = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    state.commands.update(c)
                })
    }

    private func outputBinding(_ command: SpokenCommand) -> Binding<String> {
        Binding(get: { escape(current(command)?.output ?? command.output) },
                set: { var c = current(command) ?? command; c.output = unescape($0); state.commands.update(c) })
    }

    private func enabledBinding(_ command: SpokenCommand) -> Binding<Bool> {
        Binding(get: { current(command)?.enabled ?? command.enabled },
                set: { state.commands.setEnabled(command, $0) })
    }

    // Show newlines as a typeable "\n" token so they can be edited in a single-line field.
    private func escape(_ s: String) -> String { s.replacingOccurrences(of: "\n", with: "\\n") }
    private func unescape(_ s: String) -> String { s.replacingOccurrences(of: "\\n", with: "\n") }
}
