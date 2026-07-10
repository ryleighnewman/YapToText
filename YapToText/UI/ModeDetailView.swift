import SwiftUI

/// The editor for one mode, laid out as the flow you set it up in: what it is (name, icon,
/// description), the transcription model, the AI cleanup, its dictionaries, and where the text
/// goes. Every field auto-saves. Built-in modes offer "Reset to default"; custom modes "Delete".
struct ModeDetailView: View {
    @Environment(AppState.self) private var state
    let mode: Mode
    var onSelect: (UUID) -> Void

    @State private var draft: Mode
    @State private var sampleText = ""
    @State private var previewOutput: String?
    @State private var previewError: String?
    @State private var isPreviewing = false

    init(mode: Mode, onSelect: @escaping (UUID) -> Void) {
        self.mode = mode
        self.onSelect = onSelect
        _draft = State(initialValue: mode)
    }

    private let icons = ["wand.and.stars", "sparkles", "waveform", "text.bubble", "note.text", "envelope",
                         "bubble.left.and.bubble.right", "chevron.left.forwardslash.chevron.right",
                         "list.bullet", "checklist", "doc.text", "globe"]

    private var isActive: Bool { state.settings.activeModeID == mode.id }
    private var isBuiltIn: Bool { BuiltInModes.isBuiltIn(mode.id) }
    private var defaultSpeechName: String {
        state.models.model(id: state.settings.selectedSpeechModelID)?.displayName ?? "Apple Speech"
    }

    var body: some View {
        SettingsPage {
            header
            basics
            transcription
            recording
            cleanup
            dictionaries
            output
            testBench
            footerActions
        }
        .navigationTitle(draft.name.isEmpty ? "Mode" : draft.name)
        .onChange(of: draft) {
            state.modeStore.update(draft)
            if state.settings.activeModeID == mode.id { state.controller.refreshActiveMode() }
        }
        // If the store mutates this mode elsewhere (Reset to Default / Restore), pull the fresh
        // value into the draft, and drop any preview computed against the now-stale instructions.
        .onChange(of: mode) {
            draft = mode
            previewOutput = nil
            previewError = nil
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                IconBadge(symbol: draft.iconSystemName, size: 44)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(draft.name.isEmpty ? "Untitled Mode" : draft.name).font(.title2.weight(.semibold))
                        if isActive { StatusPill(text: "Current", tint: .green) }
                    }
                    Text(draft.usesAI ? "Cleans up your words with AI before typing them"
                                      : "Types exactly what you say, word for word")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Button(isActive ? "Current Mode" : "Use This Mode") { state.controller.selectMode(mode) }
                    .buttonStyle(.solid)
                    .disabled(isActive)
            }
            // At-a-glance pipeline: what happens to your voice, start to finish, in this mode.
            pipelineSummary
        }
    }

    /// A compact "voice -> text -> where it lands" flow so the whole mode reads at a glance.
    private var pipelineSummary: some View {
        HStack(spacing: 6) {
            stepChip("waveform", "Listen")
            stepArrow
            if draft.usesAI {
                stepChip("sparkles", "AI cleanup")
                stepArrow
            }
            stepChip(outputIcon, outputShort)
            Spacer(minLength: 0)
        }
    }

    private func stepChip(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.caption2)
            Text(text).font(.caption).lineLimit(1)
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Color.secondary.opacity(0.08), in: Capsule())
        .foregroundStyle(.secondary)
    }

    private var stepArrow: some View {
        Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.tertiary)
    }

    private var outputShort: String {
        switch draft.outputTarget {
        case .insertAtCursor: return "Type at cursor"
        case .clipboardOnly: return "Copy"
        case .sendAndSubmit: return "Type + Return"
        }
    }

    private var outputIcon: String {
        switch draft.outputTarget {
        case .insertAtCursor: return "text.cursor"
        case .clipboardOnly: return "doc.on.clipboard"
        case .sendAndSubmit: return "return"
        }
    }

    // MARK: 1. Basics

    private var basics: some View {
        CardSection("Basics", subtitle: "Name this mode and how it appears.") {
            LabeledContent("Name") {
                TextField("", text: $draft.name).labelsHidden()
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .innerWell(radius: 7)
                    .frame(maxWidth: 260)
            }
            LabeledContent("Icon") {
                Picker("", selection: $draft.iconSystemName) {
                    ForEach(icons, id: \.self) { Image(systemName: $0).tag($0) }
                }
                .labelsHidden().pickerStyle(.menu).frame(maxWidth: 90)
            }
            LabeledContent("Description") {
                TextField("What this mode is for", text: $draft.summary).labelsHidden()
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .innerWell(radius: 7)
                    .frame(maxWidth: 260)
            }
            Toggle(isOn: engagedBinding) {
                Text("Show in the quick switcher")
            }
            .toggleStyle(.switch).controlSize(.small)
        }
    }

    // MARK: 2. Transcription model

    private var transcription: some View {
        CardSection("Speech model",
                    subtitle: "Which model turns your voice into words.") {
            Picker("Model", selection: $draft.speechModelID) {
                Text("Default (\(defaultSpeechName))").tag(String?.none)
                ForEach(state.models.speechModels.filter { state.models.isSelectable($0) }) { model in
                    Text(model.displayName).tag(Optional(model.id))
                }
            }
        }
    }

    // MARK: 2b. Recording (per-mode preferences)

    private static let locales = ["en_US", "en_GB", "en_AU", "es_ES", "es_MX", "fr_FR", "de_DE",
                                  "it_IT", "pt_BR", "nl_NL", "sv_SE", "ja_JP", "zh_CN", "ko_KR",
                                  "ru_RU", "hi_IN", "ar_SA"]

    private var recording: some View {
        CardSection("Recording & language",
                    subtitle: "The spoken language and when recording stops.") {
            Picker("Language", selection: $draft.localeIdentifier) {
                Text("Default (system language)").tag(String?.none)
                ForEach(Self.locales, id: \.self) { id in
                    Text(Locale.current.localizedString(forIdentifier: id) ?? id).tag(Optional(id))
                }
            }
            Toggle(isOn: usesGlobalRecording) {
                Text("Use the app-wide recording settings")
            }
            .toggleStyle(.switch).controlSize(.small)
            SubOptions {
                if draft.silenceTimeout == nil && draft.maxRecordingSeconds == nil {
                    Caption("Auto-stop and maximum length follow Settings \u{203A} Recording.")
                } else {
                    modeSlider("Auto-stop after silence",
                               value: overrideBinding(\.silenceTimeout, default: state.settings.silenceTimeout),
                               range: 0...5, step: 0.5,
                               display: (draft.silenceTimeout ?? 0) == 0 ? "Off" : String(format: "%.1fs", draft.silenceTimeout ?? 0))
                    modeSlider("Maximum length",
                               value: overrideBinding(\.maxRecordingSeconds, default: state.settings.maxRecordingSeconds),
                               range: 0...300, step: 15,
                               display: (draft.maxRecordingSeconds ?? 0) == 0 ? "Off" : "\(Int(draft.maxRecordingSeconds ?? 0))s")
                }
            }
        }
    }

    private var usesGlobalRecording: Binding<Bool> {
        Binding(
            get: { draft.silenceTimeout == nil && draft.maxRecordingSeconds == nil },
            set: { useGlobal in
                if useGlobal {
                    draft.silenceTimeout = nil
                    draft.maxRecordingSeconds = nil
                } else {
                    draft.silenceTimeout = state.settings.silenceTimeout
                    draft.maxRecordingSeconds = state.settings.maxRecordingSeconds
                }
            })
    }

    private func overrideBinding(_ keyPath: WritableKeyPath<Mode, Double?>, default def: Double) -> Binding<Double> {
        Binding(get: { draft[keyPath: keyPath] ?? def },
                set: { draft[keyPath: keyPath] = $0 })
    }

    private func modeSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>,
                            step: Double, display: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(display).foregroundStyle(.secondary).monospacedDigit()
            }
            Slider(value: value, in: range, step: step)
                .accessibilityLabel(title)
                .accessibilityValue(display)
        }
    }

    // MARK: 3. Cleanup (AI)

    private static let templates: [(String, String)] = [
        ("Clean Up", BuiltInModes.clean.instructions),
        ("Note", BuiltInModes.note.instructions),
        ("Email", BuiltInModes.email.instructions),
        ("Message", BuiltInModes.message.instructions),
        ("Code", BuiltInModes.code.instructions),
    ]

    private var cleanup: some View {
        CardSection("AI cleanup",
                    subtitle: draft.usesAI ? "Your words are rewritten before they're typed."
                                           : "Off. Your words are typed exactly as spoken.") {
            Toggle("Rewrite the transcript with AI", isOn: $draft.usesAI).toggleStyle(.switch).controlSize(.small)
            if draft.usesAI {
                SubOptions {
                    Picker("Cleanup model", selection: $draft.languageModelID) {
                        Text("Apple Intelligence").tag(String?.none)
                        ForEach(state.models.languageModels.filter { state.models.isSelectable($0) && !$0.isBuiltIn }) { model in
                            Text(model.displayName).tag(Optional(model.id))
                        }
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Instructions").font(.caption).foregroundStyle(.secondary)
                        TextEditor(text: $draft.instructions)
                            .font(.body)
                            .editorBox(minHeight: 120)
                    }
                    HStack(spacing: 6) {
                        Text("Start from:").font(.caption).foregroundStyle(.secondary)
                        ForEach(Self.templates, id: \.0) { name, instructions in
                            Button(name) { draft.instructions = instructions }
                                .buttonStyle(.solidSecondary).controlSize(.small)
                        }
                    }
                    Caption("Templates replace the instructions above, so tweak from there.")
                    Text("Context the AI can see").font(.caption).foregroundStyle(.secondary)
                        .padding(.top, 2)
                    Toggle("The app you're dictating into", isOn: $draft.includeAppContext).toggleStyle(.switch).controlSize(.small)
                    Toggle("Text you have selected", isOn: $draft.includeSelectedText).toggleStyle(.switch).controlSize(.small)
                    Toggle("Your clipboard", isOn: $draft.includeClipboard).toggleStyle(.switch).controlSize(.small)
                    if !FoundationModelsTransformer.isAvailable {
                        Caption("Apple Intelligence is off right now, so this mode will insert the raw transcript until it's enabled.")
                    }
                }
            } else {
                Caption("This mode types your words exactly, with no AI cleanup.")
            }
        }
    }

    // MARK: 4. Dictionaries

    private var dictionaries: some View {
        CardSection("Dictionaries",
                    subtitle: "Fix names and spellings automatically.") {
            Toggle("Use every dictionary that's turned on", isOn: useAllDictionariesBinding).toggleStyle(.switch).controlSize(.small)
            SubOptions {
                if draft.dictionaryIDs != nil {
                    if state.vocabulary.dictionaries.isEmpty {
                        Caption("No dictionaries yet. Create them in the Dictionaries tab.")
                    } else {
                        ForEach(state.vocabulary.dictionaries) { dict in
                            Toggle(dict.name, isOn: dictionaryBinding(dict.id)).toggleStyle(.switch).controlSize(.small)
                        }
                    }
                } else {
                    Caption("This mode applies whichever dictionaries are enabled in the Dictionaries tab.")
                }
            }
        }
    }

    // MARK: 5. Output

    private var output: some View {
        CardSection("Where the text goes",
                    subtitle: "How the finished text is delivered.") {
            Picker("Deliver as", selection: $draft.outputTarget) {
                ForEach(OutputTarget.allCases) { Text($0.label).tag($0) }
            }
            SubOptions {
                Caption(outputDescription(draft.outputTarget))
                if draft.outputTarget != .clipboardOnly {
                    Picker("Method", selection: $draft.insertionMethod) {
                        Text("Default (\((state.settings.insertionMethod).label))").tag(InsertionMethod?.none)
                        ForEach(InsertionMethod.allCases.filter { $0 != .clipboardOnly }) { Text($0.label).tag(Optional($0)) }
                    }
                }
                Picker("Trim trailing whitespace", selection: $draft.trimTrailingNewlines) {
                    Text("Default (\(state.settings.trimTrailingNewlines ? "on" : "off"))").tag(Bool?.none)
                    Text("On").tag(Optional(true))
                    Text("Off").tag(Optional(false))
                }
            }
        }
    }

    private func outputDescription(_ target: OutputTarget) -> String {
        switch target {
        case .insertAtCursor: return "Types the text into whatever field your cursor is in."
        case .clipboardOnly: return "Copies the text to the clipboard; nothing is typed."
        case .sendAndSubmit: return "Types the text, then presses Return. Handy for chat apps."
        }
    }

    // MARK: Test bench

    private var testBench: some View {
        CardSection("Try it out",
                    subtitle: "Preview what this mode does to a sample, without dictating.") {
            TextEditor(text: $sampleText)
                .font(.body)
                .editorBox(minHeight: 60)
            HStack {
                Button {
                    runPreview()
                } label: {
                    if isPreviewing {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(draft.usesAI ? "Preview with AI" : "Preview")
                    }
                }
                .buttonStyle(.solid)
                .disabled(isPreviewing || sampleText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Spacer()
            }
            if let previewOutput {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Result").font(.caption).foregroundStyle(.secondary)
                    Text(previewOutput.isEmpty ? "(empty)" : previewOutput)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.06)))
                }
            }
            if let previewError {
                Caption(previewError)
            }
        }
    }

    private func runPreview() {
        isPreviewing = true
        previewError = nil
        previewOutput = nil
        let input = sampleText
        let mode = draft
        Task {
            do {
                previewOutput = try await state.controller.preview(input, mode: mode)
            } catch {
                previewError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            isPreviewing = false
        }
    }

    // MARK: Footer

    private var footerActions: some View {
        HStack {
            if isBuiltIn {
                Button("Reset to Default") {
                    if let def = BuiltInModes.all.first(where: { $0.id == mode.id }) { draft = def }
                }
                .buttonStyle(.solidSecondary)
            } else {
                Button("Delete Mode", role: .destructive) {
                    state.modeStore.delete(mode)
                    state.settings.perAppModeOverrides = state.settings.perAppModeOverrides.filter { $0.value != mode.id }
                    NotificationCenter.default.post(name: .yapShowHome, object: nil)
                }
                .buttonStyle(SolidButton(tint: .red, prominent: false))
            }
            Spacer()
            Button("Duplicate") {
                let copy = state.modeStore.duplicate(draft)
                onSelect(copy.id)
            }
            .buttonStyle(.solidSecondary)
        }
    }

    // MARK: Bindings for optional fields

    private var engagedBinding: Binding<Bool> {
        Binding(get: { draft.isEngaged }, set: { draft.isEnabled = $0 })
    }

    private var useAllDictionariesBinding: Binding<Bool> {
        Binding(
            get: { draft.dictionaryIDs == nil },
            set: { useAll in
                if useAll {
                    draft.dictionaryIDs = nil
                } else {
                    draft.dictionaryIDs = state.vocabulary.dictionaries.filter(\.enabled).map(\.id)
                }
            })
    }

    private func dictionaryBinding(_ id: UUID) -> Binding<Bool> {
        Binding(
            get: { draft.dictionaryIDs?.contains(id) ?? false },
            set: { on in
                var ids = draft.dictionaryIDs ?? []
                if on {
                    if !ids.contains(id) { ids.append(id) }
                } else {
                    ids.removeAll { $0 == id }
                }
                draft.dictionaryIDs = ids
            })
    }
}
