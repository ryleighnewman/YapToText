import SwiftUI
import AppKit

struct ModelsSettingsView: View {
    @Environment(AppState.self) private var state
    @State private var ratingsShown: Set<String> = []
    @State private var locales: [Locale] = []
    @State private var addModelError: String?

    /// Pick a .gguf / .bin from disk; format is validated by magic bytes and the kind inferred.
    private func addUserModel() {
        addModelError = nil
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.data]
        panel.message = "Choose a whisper.cpp speech model (.bin) or a llama.cpp cleanup model (.gguf)"
        guard panel.runModalInFront() == .OK, let url = panel.url else { return }
        do {
            try state.models.addUserModel(from: url)
        } catch {
            addModelError = error.localizedDescription
        }
    }

    var body: some View {
        @Bindable var settings = state.settings
        SettingsPage {
            // Why this page exists, in plain words.
            HStack(spacing: Space.m + 2) {
                IconBadge(symbol: "cpu", tint: .accentColor, size: 34)
                Text("AI Models").font(.title3.weight(.semibold))
                Spacer(minLength: 0)
            }
            .padding(.bottom, 2)

            // The models actually doing the work today, pinned first, each under a plain
            // label saying what job it does - the two roles are the whole mental model.
            CardSection("Your defaults") {
                roleLabel("Dictation model", "Turns your voice into words")
                ForEach(state.models.speechModels.filter { state.models.downloads.isBundled($0) }) { modelRow($0) }
                // The language belongs WITH the dictation model: it is not an Apple-only
                // setting, it is the language hint every speech model receives.
                Picker("Language", selection: $settings.localeIdentifier) {
                    ForEach(localeOptions, id: \.0) { Text($0.1).tag($0.0) }
                }
                .padding(.leading, 24)
                .padding(.top, 2)

                Divider().padding(.vertical, 4)

                roleLabel("Cleanup model", "Turns those words into finished text")
                ForEach(state.models.languageModels.filter { state.models.downloads.isBundled($0) }) { modelRow($0) }
            }

            CardSection("Dictation Model Library",
                        subtitle: "Bigger models hear better; smaller ones are lighter on battery and memory.") {
                ForEach(state.models.speechModels.filter { !state.models.downloads.isBundled($0) }) { modelRow($0) }
            }

            CardSection("Cleanup Model Library",
                        subtitle: "Alternatives to the bundled processing model above.") {
                ForEach(state.models.languageModels.filter { !state.models.downloads.isBundled($0) }) { modelRow($0) }
            }

            CardSection("Your own models",
                        subtitle: "Bring any whisper.cpp speech model (.bin) or llama.cpp cleanup model (.gguf).") {
                ForEach(state.models.userModels) { model in
                    HStack(spacing: 8) {
                        modelRow(model)
                        Button {
                            if state.settings.selectedSpeechModelID == model.id { state.settings.selectedSpeechModelID = "apple" }
                            if state.settings.selectedLanguageModelID == model.id { state.settings.selectedLanguageModelID = "apple-foundation" }
                            state.models.removeUserModel(model)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                        .help("Remove this model and its file")
                    }
                }
                HStack {
                    Button {
                        addUserModel()
                    } label: {
                        Label("Add Model\u{2026}", systemImage: "plus")
                    }
                    .buttonStyle(.solidSecondary).controlSize(.small)
                    Spacer()
                }
                if let message = addModelError {
                    Caption(message).foregroundStyle(.orange)
                }
                Caption("A model that isn't a supported architecture is automatically rejected.")
            }

            CardSection("Storage") {
                HStack(spacing: Space.m) {
                    Image(systemName: "internaldrive")
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 22, alignment: .center)
                    Text("Models are stored locally on your Mac.")
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: Space.m)
                    Button("Reveal in Finder") { state.models.downloads.revealInFinder() }
                        .buttonStyle(.solidSecondary).controlSize(.small)
                }
            }
        }
        .navigationTitle("Models")
        .task {
            if #available(macOS 26.0, *) {
                locales = await AppleSpeechEngine.supportedLocales()
            } else {
                // No SpeechAnalyzer locale list pre-26; Whisper models are multilingual anyway.
                locales = []
            }
        }
    }

    private func modelRow(_ model: ModelInfo) -> some View {
        let selected = isSelected(model)
        return HStack(alignment: .top, spacing: 10) {
            Button {
                if state.models.isSelectable(model) { select(model) }
            } label: {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .disabled(!state.models.isSelectable(model))
            .accessibilityLabel(model.displayName)
            .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(model.displayName).fontWeight(.medium)
                    // The stars ARE the control: tapping them reveals this model's plain
                    // ratings, so the page isn't littered with pills by default.
                    Button {
                        if ratingsShown.contains(model.id) { ratingsShown.remove(model.id) }
                        else { ratingsShown.insert(model.id) }
                    } label: {
                        stars(model.quality, lit: ratingsShown.contains(model.id))
                    }
                    .buttonStyle(.plain)
                    .help("Show how this model rates")
                    .accessibilityLabel("\(model.quality) out of 5. Show ratings.")
                }
                Text(model.summary).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if ratingsShown.contains(model.id) { ratingLine(model) }
                HStack(spacing: 8) {
                    Text(model.provider); Text("·"); Text(model.languages); Text("·"); Text(model.sizeDescription)
                }
                .font(.caption2).foregroundStyle(.tertiary)
                // Apple Intelligence is the one model whose availability is out of the
                // app's hands, so its readiness rides on its own row instead of in a
                // separate section about engines the user may never select.
                if model.id == "apple-foundation" {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(FoundationModelsTransformer.isAvailable ? Color.green : Color.secondary.opacity(0.6))
                            .frame(width: 6, height: 6)
                        Text(FoundationModelsTransformer.statusDescription)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer()
            stateControl(model)
        }
    }

    /// One quiet line instead of a row of pills: how well it hears, how fast it runs, and
    /// whether it is the pick for most people. The colour is barely there on purpose -
    /// enough to read green as strong and orange as a tradeoff at a glance, never enough
    /// to shout over the model names.
    private func ratingLine(_ model: ModelInfo) -> some View {
        func tint(_ r: ModelInfo.Rating) -> Color {
            switch r { case .high: .green; case .balanced: .secondary; case .low: .orange }
        }
        return HStack(spacing: 6) {
            Text(model.accuracyRating.accuracyLabel)
                .foregroundStyle(tint(model.accuracyRating).opacity(0.55))
            Text("\u{00B7}").foregroundStyle(.quaternary)
            Text(model.speedRating.speedLabel)
                .foregroundStyle(tint(model.speedRating).opacity(0.55))
            if model.recommended {
                Text("\u{00B7}").foregroundStyle(.quaternary)
                Text("Recommended").foregroundStyle(Color.accentColor.opacity(0.6))
            }
        }
        .font(.caption2)
        .padding(.top, 1)
    }

    @ViewBuilder
    private func stateControl(_ model: ModelInfo) -> some View {
        if model.isBuiltIn {
            Text("Built-in").font(.caption).foregroundStyle(.secondary)
        } else if state.models.downloads.isBundled(model) {
            Menu {
                Button("Show in Finder") { revealModel(model) }
            } label: {
                HStack(spacing: 4) {
                    StatusPill(text: "Included", tint: .accentColor)
                    Image(systemName: "chevron.down").font(.system(size: 8)).foregroundStyle(.secondary)
                }
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        } else {
            switch state.models.state(for: model) {
            case .installed:
                Menu {
                    Button("Show in Finder") { revealModel(model) }
                    Button("Remove download", role: .destructive) { state.models.downloads.delete(model) }
                } label: {
                    HStack(spacing: 4) {
                        StatusPill(text: "Installed", tint: .green)
                        Image(systemName: "chevron.down").font(.system(size: 8)).foregroundStyle(.secondary)
                    }
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            case .downloading(let progress):
                HStack(spacing: 6) {
                    ProgressView(value: progress).frame(width: 70)
                    Button { state.models.downloads.cancel(model) } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }
            case .failed(let message):
                VStack(alignment: .trailing, spacing: 2) {
                    Button("Retry") { state.models.downloads.download(model) }.buttonStyle(.solidSecondary).controlSize(.small)
                    Text(message).font(.caption2).foregroundStyle(.red).lineLimit(1)
                }
            case .notInstalled:
                // Icon only: the size already lives in the row's meta line on the left, so the
                // button carries no text at all - every row's control is identical.
                Button {
                    state.models.downloads.download(model)
                } label: {
                    Image(systemName: "arrow.down.circle")
                }
                .buttonStyle(.solidSecondary)
                .controlSize(.small)
                .help("Download \(model.displayName) (\(model.sizeDescription))")
            }
        }
    }

    private func revealModel(_ model: ModelInfo) {
        if let url = state.models.downloads.localURL(for: model) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    private func isSelected(_ model: ModelInfo) -> Bool {
        model.kind == .speech
            ? state.settings.selectedSpeechModelID == model.id
            : state.settings.selectedLanguageModelID == model.id
    }

    private func select(_ model: ModelInfo) {
        if model.kind == .speech {
            state.settings.selectedSpeechModelID = model.id
            state.settings.engine = model.runtime == .apple ? .appleSpeech : .whisper
        } else {
            state.settings.selectedLanguageModelID = model.id
        }
    }

    /// A small heading inside "Your defaults" naming what a model is FOR, so someone who
    /// has never heard of Whisper still knows which row does what.
    private func roleLabel(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption.weight(.semibold))
            Text(subtitle).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func stars(_ count: Int, lit: Bool = false) -> some View {
        HStack(spacing: 1) {
            ForEach(0..<5, id: \.self) { i in
                Image(systemName: i < count ? "star.fill" : "star")
                    .font(.system(size: 7))
                    .foregroundStyle(lit ? Color.accentColor : .secondary)
            }
        }
        .contentShape(Rectangle())
    }

    private var localeOptions: [(String, String)] {
        let current = Locale.current
        let options = locales.map { loc -> (String, String) in
            let id = loc.identifier(.bcp47)
            let name = current.localizedString(forIdentifier: loc.identifier) ?? id
            return (id, name)
        }
        .sorted { $0.1 < $1.1 }
        if options.contains(where: { $0.0 == state.settings.localeIdentifier }) { return options }
        return [(state.settings.localeIdentifier, state.settings.localeIdentifier)] + options
    }
}
