import SwiftUI
import AppKit

struct VocabularySettingsView: View {
    @Environment(AppState.self) private var state
    @State private var suggestions: [SmartDictionary.Suggestion] = []
    /// Per-dictionary search: which cards have the field open, and each card's query.
    @State private var searchOpen: Set<UUID> = []
    @State private var dictSearch: [UUID: String] = [:]

    var body: some View {
        SettingsPage {
            Text("Dictionaries substitute words and phrases detected in transcripts. Use them to fix the spelling of names, casing, and homophones - like turning \"swift ui\" into \"SwiftUI\". Turn a dictionary off to pause it without deleting it.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            @Bindable var settings = state.settings
            Toggle("Suggest fixes from my dictations", isOn: $settings.smartDictionary)
                .toggleStyle(.switch).controlSize(.small)
                .onChange(of: settings.smartDictionary) { refreshSuggestions() }
            Text("YapToText notices corrections that keep recurring in your history - a name it always has to re-capitalize, a brand it re-spells - and offers them here as one-click substitutions. This runs entirely on your Mac.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            if state.settings.smartDictionary, !suggestions.isEmpty {
                suggestionsCard
            }

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
        .onAppear { refreshSuggestions() }
    }

    /// Fixes the app keeps making for you, offered once each as a permanent substitution.
    private var suggestionsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles").iconTint(Color.accentColor)
                Text("Suggested for you").font(.headline)
                Spacer()
            }
            Text("Corrections that keep happening in your dictations. Add one and it's applied instantly from then on.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Divider()
            ForEach(suggestions) { s in
                HStack(spacing: 8) {
                    Text(s.from).frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "arrow.right").foregroundStyle(.secondary).font(.caption)
                    Text(s.to).frame(maxWidth: .infinity, alignment: .leading)
                    Text("\u{00D7}\(s.count)").font(.caption2).foregroundStyle(.tertiary)
                        .help("Seen \(s.count) times in your history")
                    Button {
                        state.vocabulary.addReplacement(Replacement(from: s.from, to: s.to))
                        SmartDictionary.dismiss(s)
                        suggestions.removeAll { $0.id == s.id }
                    } label: { Image(systemName: "plus.circle.fill").foregroundStyle(Color.accentColor) }
                        .buttonStyle(.plain).help("Add to your first dictionary")
                    Button {
                        SmartDictionary.dismiss(s)
                        suggestions.removeAll { $0.id == s.id }
                    } label: { Image(systemName: "xmark.circle").foregroundStyle(.secondary) }
                        .buttonStyle(.plain).help("Don't suggest this again")
                }
                .font(.callout)
            }
        }
        .padding(Metrics.cardPad)
        .innerWell(radius: Metrics.sectionRadius)
    }

    private func refreshSuggestions() {
        guard state.settings.smartDictionary else { suggestions = []; return }
        suggestions = SmartDictionary.suggestions(history: state.history.records,
                                                  vocabulary: state.vocabulary)
    }

    private func dictionaryCard(_ dict: VocabDictionary) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "character.book.closed.fill").iconTint(Color.accentColor)
                TextField("Name", text: nameBinding(dict))
                    .textFieldStyle(.plain).font(.headline)
                Spacer()
                Button {
                    if searchOpen.contains(dict.id) {
                        searchOpen.remove(dict.id)
                        dictSearch[dict.id] = ""
                    } else {
                        searchOpen.insert(dict.id)
                    }
                } label: {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(searchOpen.contains(dict.id) ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.plain)
                .help("Search this dictionary")
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
            if searchOpen.contains(dict.id) {
                SearchField(text: Binding(get: { dictSearch[dict.id] ?? "" },
                                          set: { dictSearch[dict.id] = $0 }),
                            prompt: "Search \(dict.name)")
            }
            let query = (dictSearch[dict.id] ?? "").trimmingCharacters(in: .whitespaces)
            let visible = query.isEmpty ? dict.replacements : dict.replacements.filter {
                $0.from.localizedCaseInsensitiveContains(query)
                    || $0.to.localizedCaseInsensitiveContains(query)
            }
            if dict.replacements.isEmpty {
                Text("No substitutions yet.").font(.caption).foregroundStyle(.secondary)
            } else if visible.isEmpty {
                Text("No substitutions match \u{201C}\(query)\u{201D}.").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(visible) { r in
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
                        Button {
                            // AI sound-alikes: for a name like "Ryleigh", map the common
                            // mishearings ("riley", "rylee"...) to this spelling in one click.
                            AppDelegate.shared?.expandSoundAlikes(for: r.to)
                        } label: {
                            Image(systemName: "sparkles").foregroundStyle(Color.accentColor.opacity(0.8))
                        }
                        .buttonStyle(.plain)
                        .help("AI: also map likely mishearings of \u{201C}\(r.to)\u{201D} to this spelling")
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
        guard panel.runModalInFront() == .OK, let url = panel.url,
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


// MARK: - Suggestion chips

struct ChipItem: Identifiable {
    let id: String
    let label: String
    let icon: String
    let action: () -> Void
}

/// A simple wrapping row of add-chips.
struct FlowChips: View {
    let items: [ChipItem]
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8, alignment: .leading)],
                  alignment: .leading, spacing: 8) {
            ForEach(items) { item in
                Button(action: item.action) {
                    HStack(spacing: 6) {
                        Image(systemName: item.icon).font(.caption).iconTint(Color.accentColor)
                        Text(item.label).font(.callout).lineLimit(1)
                        Spacer(minLength: 0)
                        Image(systemName: "plus.circle.fill").font(.caption).iconTint(Color.accentColor)
                    }
                    .padding(.horizontal, 11).padding(.vertical, 7)
                    .background(Color.secondary.opacity(0.06), in: Capsule())
                    .overlay(Capsule().stroke(Color.secondary.opacity(0.12), lineWidth: 0.5))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("Add \"\(item.id)\" as a substitution")
            }
        }
    }
}
