import SwiftUI
import AppKit

struct VocabularySettingsView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        SettingsPage {
            Text("Dictionaries substitute words and phrases in every transcript. Use them to fix names, casing, and homophones, like turning \"swift ui\" into \"SwiftUI\". Turn a dictionary off to pause it without deleting it.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            ForEach(state.vocabulary.dictionaries) { dict in
                dictionaryCard(dict)
            }

            Button {
                _ = state.vocabulary.addDictionary(name: "New Dictionary")
            } label: {
                Label("New Dictionary", systemImage: "plus")
            }
            .buttonStyle(.solid)
        }
        .navigationTitle("Dictionaries")
    }

    private func dictionaryCard(_ dict: VocabDictionary) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "character.book.closed.fill").iconTint(Color.accentColor)
                TextField("Name", text: nameBinding(dict))
                    .textFieldStyle(.plain).font(.headline)
                Spacer()
                Toggle("Enabled", isOn: enabledBinding(dict))
                    .toggleStyle(.switch).controlSize(.small).labelsHidden().help("Enable this dictionary")
                Menu {
                    Button("Export Dictionary…") { exportDictionary(dict) }
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([Persistence.url("vocabulary.json")])
                    }
                    Divider()
                    Button("Delete Dictionary", role: .destructive) { state.vocabulary.deleteDictionary(dict) }
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).fixedSize()
            }
            Divider()
            if dict.replacements.isEmpty {
                Text("No substitutions yet.").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(dict.replacements) { r in
                    HStack(spacing: 8) {
                        Image(systemName: "line.3.horizontal")
                            .font(.caption2).foregroundStyle(.tertiary)
                            .help("Drag to reorder - substitutions run top to bottom")
                            .draggable(r.id.uuidString)
                        TextField("Heard", text: replacementBinding(r, in: dict.id, \.from))
                            .textFieldStyle(.plain).frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: "arrow.right").foregroundStyle(.secondary).font(.caption)
                        TextField("Replace with", text: replacementBinding(r, in: dict.id, \.to))
                            .textFieldStyle(.plain).frame(maxWidth: .infinity, alignment: .leading)
                        if r.wholeWord { tag("word") }
                        if r.caseSensitive { tag("Aa") }
                        Button { state.vocabulary.duplicateReplacement(r, in: dict.id) } label: {
                            Image(systemName: "plus.square.on.square").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Duplicate this substitution")
                        Button { state.vocabulary.deleteReplacement(r, in: dict.id) } label: {
                            Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Delete this substitution")
                    }
                    .font(.callout)
                    .contentShape(Rectangle())
                    .dropDestination(for: String.self) { items, _ in
                        guard let dragged = items.first, let draggedID = UUID(uuidString: dragged) else { return false }
                        state.vocabulary.moveReplacement(id: draggedID, before: r.id, in: dict.id)
                        return true
                    }
                }
            }
            AddReplacementRow { r in state.vocabulary.addReplacement(r, to: dict.id) }
        }
        .padding(Metrics.cardPad)
        .innerWell(radius: Metrics.sectionRadius)
    }

    private func tag(_ t: String) -> some View {
        Text(t).font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
            .background(.secondary.opacity(0.15), in: Capsule())
    }

    private func exportDictionary(_ dict: VocabDictionary) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(dict.name).yapdictionary.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url,
              let data = try? JSONEncoder().encode(dict) else { return }
        try? data.write(to: url)
    }

    /// Live-edit binding for a substitution's text, keyed by the replacement's stable UUID
    /// (never its position or content), so edits always land on the right entry.
    private func replacementBinding(_ r: Replacement, in dictID: UUID, _ key: WritableKeyPath<Replacement, String>) -> Binding<String> {
        Binding(
            get: {
                state.vocabulary.dictionaries.first { $0.id == dictID }?
                    .replacements.first { $0.id == r.id }?[keyPath: key] ?? r[keyPath: key]
            },
            set: { value in
                guard var cur = state.vocabulary.dictionaries.first(where: { $0.id == dictID })?
                    .replacements.first(where: { $0.id == r.id }) else { return }
                cur[keyPath: key] = value
                state.vocabulary.updateReplacement(cur, in: dictID)
            })
    }

    private func nameBinding(_ dict: VocabDictionary) -> Binding<String> {
        Binding(get: { state.vocabulary.dictionaries.first { $0.id == dict.id }?.name ?? dict.name },
                set: { state.vocabulary.rename(dict, to: $0) })
    }
    private func enabledBinding(_ dict: VocabDictionary) -> Binding<Bool> {
        Binding(get: { state.vocabulary.dictionaries.first { $0.id == dict.id }?.enabled ?? dict.enabled },
                set: { state.vocabulary.setEnabled(dict, $0) })
    }
}

private struct AddReplacementRow: View {
    let onAdd: (Replacement) -> Void
    @State private var from = ""
    @State private var to = ""
    @State private var wholeWord = true
    @State private var caseSensitive = false

    var body: some View {
        HStack(spacing: 8) {
            TextField("Heard", text: $from)
                .textFieldStyle(.plain)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .innerWell(radius: 7)
            Image(systemName: "arrow.right").foregroundStyle(.secondary).font(.caption)
            TextField("Replace with", text: $to)
                .textFieldStyle(.plain)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .innerWell(radius: 7)
            Toggle("Whole word", isOn: $wholeWord).toggleStyle(.checkbox).controlSize(.small)
            Toggle("Case", isOn: $caseSensitive).toggleStyle(.checkbox).controlSize(.small)
            Button("Add") {
                let f = from.trimmingCharacters(in: .whitespaces)
                guard !f.isEmpty else { return }
                onAdd(Replacement(from: f, to: to, caseSensitive: caseSensitive, wholeWord: wholeWord))
                from = ""; to = ""
            }
            .buttonStyle(.solidSecondary).controlSize(.small)
            .disabled(from.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .font(.callout)
    }
}
