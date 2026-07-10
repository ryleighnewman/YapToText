import SwiftUI

/// Editor for AI Actions - the one-shot rewrites you run on selected text in any app. Ships a
/// set of defaults; each is editable and you can add your own. Triggered by the AI Actions
/// shortcut set in Settings.
struct ActionsView: View {
    @Environment(AppState.self) private var state

    private let icons = ["wand.and.stars", "sparkles", "checkmark.circle", "scissors", "briefcase",
                         "face.smiling", "list.bullet", "globe", "text.line.first.and.arrowtriangle.forward",
                         "bubble.left.and.bubble.right", "doc.text", "pencil"]

    var body: some View {
        SettingsPage {
            Text("AI Actions rewrite whatever text you've selected in any app: improve it, fix grammar, make it shorter, summarize, translate, all entirely on device. Run them from the Utility page on any text you paste in.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            CardSection("Where to run them") {
                Caption("Run these on any text from the Utility page. To rewrite SELECTED text in another app, use the menu bar's Regenerate menu and pick a mode.")
            }

            ForEach(state.actions.actions) { action in
                card(action)
            }

            HStack {
                Button { _ = state.actions.add() } label: { Label("New Action", systemImage: "plus") }
                    .buttonStyle(.solid)
                Spacer()
                Button("Restore Defaults") { state.actions.restoreDefaults() }
                    .buttonStyle(.solidSecondary)
            }
        }
        .navigationTitle("AI Actions")
    }

    private func card(_ action: AIAction) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Picker("", selection: iconBinding(action)) {
                    ForEach(icons, id: \.self) { Image(systemName: $0).tag($0) }
                }
                .labelsHidden().pickerStyle(.menu).frame(width: 70)
                TextField("Name", text: nameBinding(action))
                    .textFieldStyle(.plain).font(.headline)
                Spacer()
                Button { state.actions.delete(action) } label: {
                    Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Delete action")
                .accessibilityLabel("Delete \(action.name)")
            }
            Caption("A general rewrite prompt. It runs on the cleanup model your current mode uses.")
            DisclosureGroup("Instructions") {
                TextEditor(text: instructionsBinding(action))
                    .font(.callout)
                    .editorBox(minHeight: 90)
                    .padding(.top, 4)
            }
            .font(.caption)
        }
        .padding(Metrics.cardPad)
        .innerWell(radius: Metrics.sectionRadius)
    }

    // MARK: Bindings

    private func current(_ action: AIAction) -> AIAction? { state.actions.action(withID: action.id) }

    private func nameBinding(_ action: AIAction) -> Binding<String> {
        Binding(get: { current(action)?.name ?? action.name },
                set: { var a = current(action) ?? action; a.name = $0; state.actions.update(a) })
    }
    private func iconBinding(_ action: AIAction) -> Binding<String> {
        Binding(get: { current(action)?.iconSystemName ?? action.iconSystemName },
                set: { var a = current(action) ?? action; a.iconSystemName = $0; state.actions.update(a) })
    }
    private func instructionsBinding(_ action: AIAction) -> Binding<String> {
        Binding(get: { current(action)?.instructions ?? action.instructions },
                set: { var a = current(action) ?? action; a.instructions = $0; state.actions.update(a) })
    }
}
