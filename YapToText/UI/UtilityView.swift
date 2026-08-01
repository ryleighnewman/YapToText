import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The Utility hub: every YapToText capability usable right inside the app window, no global
/// hotkey required. Four glass tools - dictate into a scratchpad, transform text through any mode,
/// transcribe a file, and run an AI action on text - each with copy/insert.
struct UtilityView: View {
    @Environment(AppState.self) private var state
    private var controller: DictationController { state.controller }

    // Dictate scratchpad
    @State private var dictateText = ""
    // Transform text
    @State private var transformInput = ""
    @State private var transformOutput = ""
    @State private var transformModeID: UUID?
    @State private var transformBusy = false
    // Transcribe a file
    @State private var fileOutput = ""
    @State private var fileName: String?
    @State private var fileBusy = false
    @State private var fileError: String?
    @State private var dropTargeted = false
    @State private var fileModeID: UUID?
    // AI action on text
    @State private var actionInput = ""
    @State private var actionOutput = ""
    @State private var actionID: UUID?
    @State private var actionBusy = false
    // Transient "Copied" feedback, keyed by card.
    @State private var copiedTag: String?
    // "Send below" pipeline: which card is briefly highlighted, and the scroll target.
    @State private var flashCard: String?
    @State private var scrollTarget: String?
    /// Card ids whose INTO-connector is currently pulsing (the animated pipeline path).
    @State private var pulsePath: Set<String> = []

    private var aiModes: [Mode] { controller.switchableModes.filter(\.usesAI) }

    /// A step the "Send below" button routes text into, further down the workbench.
    private enum SendTarget {
        case transform, action
        var cardID: String { self == .transform ? "transform" : "action" }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    intro
                    flow("dictate") { dictateCard }
                    PipelineConnector(active: pulsePath.contains("transcribe"))
                    flow("transcribe") { transcribeCard }
                    PipelineConnector(active: pulsePath.contains("transform"))
                    flow("transform") { transformCard }
                    PipelineConnector(active: pulsePath.contains("action"))
                    flow("action") { actionCard }
                }
                .padding(20)
                .frame(maxWidth: Metrics.pageWidth, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.never)
            .onChange(of: scrollTarget) { _, target in
                guard let target else { return }
                withAnimation(.easeInOut(duration: 0.45)) { proxy.scrollTo(target, anchor: .center) }
            }
        }
        .navigationTitle("Utility")
        .onAppear {
            if transformModeID == nil { transformModeID = aiModes.first?.id }
            if fileModeID == nil { fileModeID = (aiModes.first ?? controller.switchableModes.first)?.id }
            if actionID == nil { actionID = state.actions.actions.first?.id }
        }
    }

    /// Wraps a card with an id (for scrolling) and an accent glow that flashes when text is sent to it.
    private func flow<V: View>(_ id: String, @ViewBuilder _ card: () -> V) -> some View {
        card()
            .id(id)
            .overlay(
                RoundedRectangle(cornerRadius: Metrics.sectionRadius, style: .continuous)
                    .stroke(Color.accentColor, lineWidth: 2.5)
                    .opacity(flashCard == id ? 1 : 0)
                    .shadow(color: Color.accentColor.opacity(flashCard == id ? 0.5 : 0), radius: 8)
                    .allowsHitTesting(false)
            )
            .animation(.easeInOut(duration: 0.4), value: flashCard)
    }

    /// Drop `text` into the next tool's input, scroll to it, flash it, and pulse the pipeline
    /// connectors along the way so the hand-off visibly flows down the page.
    private func sendBelow(_ text: String, from source: String, to target: SendTarget) {
        switch target {
        case .transform: transformInput = text
        case .action: actionInput = text
        }
        let order = ["dictate", "transcribe", "transform", "action"]
        if let s = order.firstIndex(of: source), let t = order.firstIndex(of: target.cardID), s < t {
            pulsePath = Set(order[(s + 1)...t])
        } else {
            pulsePath = [target.cardID]
        }
        flashCard = target.cardID
        scrollTarget = target.cardID
        Task {
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            if flashCard == target.cardID { flashCard = nil }
            pulsePath = []
            scrollTarget = nil
        }
    }

    /// A quiet pipeline link between two boxes: a grayed line and chevron that, when the path is
    /// active, tint accent and run a small dot down the line - the hand-off made visible. The
    /// animation is one-shot and user-initiated (glass-safe in the main window).
    private struct PipelineConnector: View {
        let active: Bool
        @State private var dotDown = false

        var body: some View {
            // A clean line, nothing else: the boxes and the flow speak for themselves.
            ZStack(alignment: .top) {
                Capsule()
                    .fill(active ? Color.accentColor.opacity(0.45) : Color.secondary.opacity(0.18))
                    .frame(width: 2, height: 26)
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 6, height: 6)
                    .offset(x: 0, y: dotDown ? 20 : 0)
                    .opacity(active ? 1 : 0)
            }
            .frame(maxWidth: .infinity)
            .animation(.easeInOut(duration: 0.25), value: active)
            .onChange(of: active) {
                guard active else { dotDown = false; return }
                dotDown = false
                withAnimation(.easeInOut(duration: 0.6)) { dotDown = true }
            }
            .accessibilityHidden(true)
        }
    }

    private var intro: some View {
        HStack(spacing: Space.m + 2) {
            VStack(alignment: .leading, spacing: 2) {
                Text("This is a showcase of everything YapToText can do, chained into one easy-to-follow pipeline. Dictate into the scratchpad (or transcribe any audio or video file), send the result down to be rewritten by any mode - your dictionaries and voice commands apply just like a real dictation - then finish it with a one-shot AI action like translate or summarize. Every card has Copy and Insert, and \u{201C}Send below\u{201D} passes text to the next step. It's the whole app, laid out on one workbench.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.bottom, 2)
    }

    // MARK: Dictate

    private var dictateCard: some View {
        CardSection("Dictate", subtitle: "Speak straight into a scratchpad, then copy it or send it to your last app.") {
            HStack(spacing: Space.m) {
                dictateModeMenu
                Spacer(minLength: Space.s)
                dictateButton
            }

            // Only this card's OWN scratchpad session drives the inline waveform/preview - a global
            // dictation happening in the background must never light this up.
            if controller.isScratchpadSession {
                if controller.isRecording || isProcessing {
                    // The wave stays mounted through the stop and condenses into the
                    // spinning ring - same gate choreography as the panel.
                    WaveformView(data: controller.visualData,
                                 isActive: controller.isRecording && !controller.isPaused,
                                 style: state.settings.waveStyle,
                                 freeze: isProcessing, sucking: isProcessing)
                        .frame(maxWidth: .infinity)
                        .transition(.opacity)
                }
                if controller.isRecording, !controller.liveText.isEmpty {
                    Text(controller.liveText)
                        .font(.callout).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading).lineLimit(2)
                } else if isProcessing {
                    Text(controller.statusText).font(.callout).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }

            TextEditor(text: $dictateText)
                .font(.body).editorBox(minHeight: 96)
                .overlay(alignment: .topLeading) {
                    if dictateText.isEmpty && !(controller.isScratchpadSession && controller.isRecording) {
                        Text("Your dictation will appear here.")
                            .font(.body).foregroundStyle(.tertiary)
                            .padding(.horizontal, 11).padding(.vertical, 12).allowsHitTesting(false)
                    }
                }

            resultActions(text: dictateText, tag: "dictate", sendTo: .transform, onClear: { dictateText = "" })
        }
    }

    private var dictateModeMenu: some View {
        Menu {
            ForEach(controller.switchableModes) { mode in
                Button { controller.selectMode(mode) } label: {
                    Label(mode.name, systemImage: mode.id == controller.activeMode.id ? "checkmark" : mode.iconSystemName)
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: controller.activeMode.iconSystemName)
                Text(controller.activeMode.name).lineLimit(1)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9))
            }
            .font(.callout).foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help("Mode used for dictation")
    }

    @ViewBuilder
    private var dictateButton: some View {
        if controller.isScratchpadSession && controller.isRecording {
            Button(role: .destructive) { controller.stop() } label: {
                Label("Stop", systemImage: "stop.fill").frame(minWidth: 96)
            }
            .buttonStyle(SolidButton(tint: .yapRecord))
        } else {
            Button {
                controller.startScratchpad { result in
                    let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    dictateText += (dictateText.isEmpty ? "" : "\n\n") + trimmed
                }
            } label: {
                Label("Dictate", systemImage: "mic.fill").frame(minWidth: 96)
            }
            .buttonStyle(.solid)
            // Disabled while ANY dictation is active elsewhere (global or this card's own
            // processing), so it only starts when the page is genuinely idle.
            .disabled(controller.isBusy || controller.isRecording)
        }
    }

    private var isProcessing: Bool {
        switch controller.phase {
        case .transcribing, .transforming, .inserting: return true
        default: return false
        }
    }

    // MARK: Transform text

    private var transformCard: some View {
        CardSection("Transform text", subtitle: "Paste rough text and reformat it through any mode, like turning notes into an email.") {
            TextEditor(text: $transformInput)
                .font(.body).editorBox(minHeight: 80)
                .overlay(alignment: .topLeading) {
                    if transformInput.isEmpty {
                        Text("Paste or type text to reformat.")
                            .font(.body).foregroundStyle(.tertiary)
                            .padding(.horizontal, 11).padding(.vertical, 12).allowsHitTesting(false)
                    }
                }
            HStack(spacing: Space.m) {
                aiModePicker(selection: $transformModeID)
                Spacer(minLength: Space.s)
                Button {
                    runTransform()
                } label: {
                    if transformBusy { ProgressView().controlSize(.small).frame(minWidth: 96) }
                    else { Label("Transform", systemImage: "wand.and.stars").frame(minWidth: 96) }
                }
                .buttonStyle(.solid)
                .disabled(transformBusy || transformInput.trimmingCharacters(in: .whitespaces).isEmpty || aiModes.isEmpty)
            }
            if aiModes.isEmpty {
                Caption("No AI modes are engaged. Turn one on in Modes to use this.")
            }
            if !transformOutput.isEmpty { outputBox(transformOutput) }
            resultActions(text: transformOutput, tag: "transform", sendTo: .action, onClear: { transformOutput = "" })
        }
    }

    // MARK: Transcribe a file

    private var transcribeCard: some View {
        CardSection("Transcribe a file", subtitle: "Drop or choose any audio or video file, including Voice Memos, and get the text.") {
            dropZone
            HStack(spacing: Space.m) {
                aiModePicker(selection: $fileModeID, includeRaw: true)
                Spacer(minLength: Space.s)
                Button { chooseFile() } label: {
                    Label("Choose File\u{2026}", systemImage: "folder").frame(minWidth: 96)
                }
                .buttonStyle(.solidSecondary).disabled(fileBusy)
            }
            if let fileError {
                Label(fileError, systemImage: "exclamationmark.triangle").font(.caption).iconTint(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !fileOutput.isEmpty { outputBox(fileOutput) }
            resultActions(text: fileOutput, tag: "file", sendTo: .transform, onClear: { fileOutput = ""; fileName = nil })
        }
    }

    private var dropZone: some View {
        RoundedRectangle(cornerRadius: Metrics.innerRadius, style: .continuous)
            .fill(Color.secondary.opacity(dropTargeted ? 0.16 : 0.06))
            .overlay(RoundedRectangle(cornerRadius: Metrics.innerRadius, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.2, dash: [5, 4]))
                .foregroundStyle(dropTargeted ? Color.accentColor : Color.secondary.opacity(0.4)))
            .frame(height: 74)
            .overlay {
                VStack(spacing: 4) {
                    if fileBusy {
                        ProgressView().controlSize(.small)
                        Text("Transcribing \(fileName ?? "file")\u{2026}").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Image(systemName: "arrow.down.doc").font(.title3).foregroundStyle(.secondary)
                        Text(fileName.map { "Loaded \($0)" } ?? "Drop an audio or video file here").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
                guard let provider = providers.first else { return false }
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let url { Task { @MainActor in transcribe(url) } }
                }
                return true
            }
    }

    // MARK: AI action on text

    private var actionCard: some View {
        CardSection("AI action on text", subtitle: "Run one of your saved AI actions on any text.") {
            if state.actions.actions.isEmpty {
                Caption("No AI actions yet. Create some in the AI Actions tab.")
            } else {
                TextEditor(text: $actionInput)
                    .font(.body).editorBox(minHeight: 70)
                    .overlay(alignment: .topLeading) {
                        if actionInput.isEmpty {
                            Text("Paste text to run an action on.")
                                .font(.body).foregroundStyle(.tertiary)
                                .padding(.horizontal, 11).padding(.vertical, 12).allowsHitTesting(false)
                        }
                    }
                HStack(spacing: Space.m) {
                    Picker("Action", selection: $actionID) {
                        ForEach(state.actions.actions) { Text($0.name).tag(Optional($0.id)) }
                    }
                    .labelsHidden().pickerStyle(.menu).fixedSize()
                    Spacer(minLength: Space.s)
                    Button { runAction() } label: {
                        if actionBusy { ProgressView().controlSize(.small).frame(minWidth: 96) }
                        else { Label("Run", systemImage: "sparkles").frame(minWidth: 96) }
                    }
                    .buttonStyle(.solid)
                    .disabled(actionBusy || actionInput.trimmingCharacters(in: .whitespaces).isEmpty || actionID == nil)
                }
                if !actionOutput.isEmpty { outputBox(actionOutput) }
                resultActions(text: actionOutput, tag: "action", onClear: { actionOutput = "" })
            }
        }
    }

    // MARK: Shared pieces

    private func aiModePicker(selection: Binding<UUID?>, includeRaw: Bool = false) -> some View {
        let modes = includeRaw ? controller.switchableModes : aiModes
        return Picker("Mode", selection: selection) {
            ForEach(modes) { Text($0.name).tag(Optional($0.id)) }
        }
        .labelsHidden().pickerStyle(.menu).fixedSize()
    }

    private func outputBox(_ text: String) -> some View {
        ScrollView {
            Text(text).font(.body).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: 44, maxHeight: 180)
        .padding(8).innerWell(radius: Metrics.innerRadius)
    }

    @ViewBuilder
    private func resultActions(text: String, tag: String, sendTo: SendTarget? = nil,
                              onClear: @escaping () -> Void) -> some View {
        // ALWAYS visible: the buttons are part of each card's anatomy, grayed out until
        // there's text to act on - so the pipeline's affordances never pop in and out.
        let usable = !text.isEmpty
        return Group {
            HStack(spacing: Space.s) {
                Button { copy(text, tag: tag) } label: {
                    Label(copiedTag == tag ? "Copied" : "Copy",
                          systemImage: copiedTag == tag ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.solidSecondary)
                .disabled(!usable)
                Button { AppDelegate.shared?.insertIntoLastApp(text) } label: {
                    Label("Insert", systemImage: "text.cursor")
                }
                .buttonStyle(.solidSecondary)
                .disabled(!usable)
                .help("Type this into the app you were last using")
                Spacer(minLength: 0)
                Button(role: .destructive, action: onClear) { Label("Clear", systemImage: "trash") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary)
                    .disabled(!usable)
            }
            .font(.callout)
            .opacity(usable ? 1 : 0.5)
            // Send below stands ALONE, centered on the pipeline's axis: it is the hand-off.
            if let sendTo {
                HStack {
                    Spacer()
                    Button { sendBelow(text, from: tag, to: sendTo) } label: {
                        Label("Send below", systemImage: "arrow.down")
                    }
                    .buttonStyle(.solid)
                    .disabled(!usable)
                    .help("Send this text down to the next tool")
                    Spacer()
                }
                .font(.callout)
                .opacity(usable ? 1 : 0.5)
                .padding(.top, 2)
            }
        }
    }

    // MARK: Actions

    private func mode(for id: UUID?, fallback: Mode) -> Mode {
        controller.switchableModes.first { $0.id == id } ?? fallback
    }

    private func runTransform() {
        let text = transformInput
        let selected = mode(for: transformModeID, fallback: aiModes.first ?? BuiltInModes.clean)
        transformBusy = true
        transformOutput = ""
        Task {
            let result = (try? await controller.preview(text, mode: selected)) ?? ""
            transformOutput = result
            transformBusy = false
        }
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.title = "Transcribe a File"
        panel.message = "Choose any audio or video file."
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModalInFront() == .OK, let url = panel.url { transcribe(url) }
    }

    private func transcribe(_ url: URL) {
        guard !fileBusy else { return }
        let selected = mode(for: fileModeID, fallback: aiModes.first ?? controller.activeMode)
        fileName = url.lastPathComponent
        fileError = nil
        fileOutput = ""
        fileBusy = true
        Task {
            do {
                fileOutput = try await controller.transcribe(fileURL: url, mode: selected)
            } catch {
                fileError = (error as? LocalizedError)?.errorDescription ?? "Couldn't transcribe that file."
            }
            fileBusy = false
        }
    }

    private func runAction() {
        guard let action = state.actions.actions.first(where: { $0.id == actionID }) else { return }
        let text = actionInput
        actionBusy = true
        actionOutput = ""
        Task {
            actionOutput = (try? await controller.applyAIAction(instructions: action.instructions, to: text)) ?? ""
            actionBusy = false
        }
    }

    private func copy(_ text: String, tag: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copiedTag = tag
        Task {
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            if copiedTag == tag { copiedTag = nil }
        }
    }
}
