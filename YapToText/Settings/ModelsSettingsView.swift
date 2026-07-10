import SwiftUI
import AppKit

struct ModelsSettingsView: View {
    @Environment(AppState.self) private var state
    @State private var locales: [Locale] = []

    var body: some View {
        @Bindable var settings = state.settings
        SettingsPage {
            // Why this page exists, in plain words.
            HStack(spacing: Space.m + 2) {
                IconBadge(symbol: "cpu", tint: .accentColor, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text("AI Models").font(.title3.weight(.semibold))
                    Text("The brains behind your dictation. Swap in newer models for better accuracy, or smaller ones that use less energy and memory. Every model runs locally on your Mac. Your audio and text never leave the device.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.bottom, 2)

            // The models actually doing the work today, pinned first.
            CardSection("Your defaults",
                        subtitle: "What the app uses out of the box: this speech model turns your voice into words; Apple Intelligence handles AI cleanup, with the bundled Phi-3.5 stepping in automatically wherever Apple Intelligence is off or unsupported.") {
                ForEach(state.models.speechModels.filter { state.models.downloads.isBundled($0) }) { modelRow($0) }
            }

            CardSection("Apple engines") {
                Picker("Speech language", selection: $settings.localeIdentifier) {
                    ForEach(localeOptions, id: \.0) { Text($0.1).tag($0.0) }
                }
                HStack(alignment: .top, spacing: 7) {
                    Circle()
                        .fill(FoundationModelsTransformer.isAvailable ? Color.green : Color.secondary.opacity(0.6))
                        .frame(width: 7, height: 7)
                        .padding(.top, 4)
                    Text(FoundationModelsTransformer.statusDescription)
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            CardSection("More speech-to-text models",
                        subtitle: "Bigger models hear better; smaller ones are lighter on battery and memory.") {
                ForEach(state.models.speechModels.filter { !state.models.downloads.isBundled($0) }) { modelRow($0) }
            }

            CardSection("Cleanup models (AI transform)",
                        subtitle: "The AI that rewrites your transcript. Pick one here to use it instead of Apple Intelligence.") {
                Caption("Phi-3.5 ships inside the app and runs fully on device. It also takes over automatically on Macs where Apple Intelligence is off or unavailable, so AI cleanup works everywhere.")
                ForEach(state.models.languageModels) { modelRow($0) }
            }

            CardSection("Storage") {
                HStack {
                    TipRow(icon: "internaldrive", title: "Stored privately on your Mac",
                           message: "Models live in the app's data folder, survive updates, and nothing is ever uploaded.")
                    Spacer()
                    Button("Reveal in Finder") { state.models.downloads.revealInFinder() }
                        .buttonStyle(.solidSecondary).controlSize(.small)
                }
            }
        }
        .navigationTitle("Models")
        .task { locales = await AppleSpeechEngine.supportedLocales() }
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
                    stars(model.quality)
                }
                Text(model.summary).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Text(model.provider); Text("·"); Text(model.languages); Text("·"); Text(model.sizeDescription)
                }
                .font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer()
            stateControl(model)
        }
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

    private func stars(_ count: Int) -> some View {
        HStack(spacing: 1) {
            ForEach(0..<5, id: \.self) { i in
                Image(systemName: i < count ? "star.fill" : "star")
                    .font(.system(size: 7))
                    .foregroundStyle(.secondary)
            }
        }
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
