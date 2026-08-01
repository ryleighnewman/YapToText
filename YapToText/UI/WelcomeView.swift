import SwiftUI
import AppKit

/// First-run welcome: an animated, interactive setup shown once (gated by
/// `settings.hasCompletedOnboarding`, replayable from About). Real Liquid Glass throughout. The
/// centerpiece is a LIVE demo - a working replica of the dictation panel that plays the whole
/// pipeline so a new user sees it run before ever pressing the key themselves.
struct WelcomeView: View {
    @Environment(AppState.self) private var state
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var activeState
    @Binding var isPresented: Bool

    enum Step: Int, CaseIterable, Identifiable {
        case welcome, permissions, controls, demo, modes, quickEdit, appearance, privacy, ready
        var id: Int { rawValue }
    }

    @State private var step: Step = .welcome
    @State private var forward = true

    // Choices made during setup.
    @State private var pushToTalk = false
    @State private var useCustomDictation = false
    @State private var customDictation: KeyCombo?
    @State private var escCancel = true

    var body: some View {
        ZStack {
            AuroraBackground(reduceMotion: reduceMotion)

            // The page content, vertically centered, clear of the bottom chrome.
            VStack {
                Spacer(minLength: 0)
                content
                    .frame(maxWidth: 580)
                    // A plain crossfade, NOT a slide: sliding content of differing heights animates
                    // an AppKit view-tree relayout (_layoutSubtreeWithOldSize) while glass renders,
                    // which is a confirmed trigger for the macOS 26.5 DesignLibrary glass crash.
                    // Opacity-only changes no geometry, so the relayout animation never runs.
                    .transition(.opacity)
                    .id(step)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 44)
            .padding(.top, 30)
            .padding(.bottom, 118)

        }
        // Back and Skip sit in the true bottom corners, each an EQUAL inset (32) from both edges.
        // The primary action is centered above the page dots at the bottom center.
        .overlay(alignment: .bottomLeading) {
            if step != .welcome {
                Button { goBack() } label: {
                    Label("Back", systemImage: "chevron.left").labelStyle(.titleAndIcon)
                }
                .buttonStyle(.plain).font(.callout).foregroundStyle(.secondary)
                .padding(32)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if step != .ready {
                Button("Skip setup") { finish() }
                    .buttonStyle(.plain).font(.callout).foregroundStyle(.secondary)
                    .padding(32)
            }
        }
        .overlay(alignment: .bottom) {
            VStack(spacing: 12) { primaryButton; pageDots }.padding(.bottom, 30)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppWindowBackground())
        .onAppear { state.permissions.refresh() }
    }

    // MARK: Bottom chrome

    /// The primary action, in real (tinted, interactive) Liquid Glass.
    private var primaryButton: some View {
        Button { advance() } label: {
            Text(continueTitle)
                .font(.body.weight(.semibold))
                .foregroundStyle(.white)
                .frame(minWidth: 168)
                .padding(.vertical, 11).padding(.horizontal, 22)
                .contentShape(Capsule())   // the WHOLE capsule is clickable, not just the text
        }
        .buttonStyle(.plain)
        .yapGlassAccent(in: Capsule())
        .keyboardShortcut(.defaultAction)
    }

    private var pageDots: some View {
        HStack(spacing: 6) {
            ForEach(Step.allCases) { s in
                Capsule()
                    .fill(s == step ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.secondary.opacity(0.3)))
                    .frame(width: s == step ? 22 : 7, height: 7)
                    .animation(.spring(duration: 0.35), value: step)
            }
        }
    }

    private var continueTitle: String {
        switch step {
        case .welcome: return "Get Started"
        case .ready: return "Start Dictating"
        default: return "Continue"
        }
    }

    // MARK: Steps

    @ViewBuilder private var content: some View {
        switch step {
        case .welcome: welcomeStep
        case .permissions: permissionsStep
        case .demo: demoStep
        case .modes: modesStep
        case .quickEdit: quickEditStep
        case .appearance: appearanceStep
        case .controls: controlsStep
        case .privacy: privacyStep
        case .ready: readyStep
        }
    }

    // Page 1 - just the alive mark (no disc), the name, and the pitch.
    private var welcomeStep: some View {
        VStack(spacing: 22) {
            AnimatedCapy(size: 132, tint: .accentColor)
                .shadow(color: .accentColor.opacity(0.25), radius: 22, y: 4)
            VStack(spacing: 12) {
                Text("Welcome to YapToText").font(.largeTitle.weight(.bold))
                Text("A free, open-source accessibility tool. Talk anywhere on your Mac and your words appear right where your cursor is, fully on device.")
                    .font(.title3).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 500)
            }
        }
    }

    // Page 2 - permissions.
    private var permissionsStep: some View {
        stepScaffold(icon: nil, title: "A couple of permissions",
                     subtitle: "Microphone so it can hear you; Accessibility so your words can be pasted into other apps and the Right Command key works everywhere.") {
            VStack(spacing: 12) {
                permissionCard(icon: "mic.fill", title: "Microphone", required: false,
                               granted: state.permissions.microphoneGranted,
                               detail: "Recommended, so the app can hear your voice.",
                               grant: { Task { await state.permissions.requestMicrophone() } })
                permissionCard(icon: "accessibility", title: "Accessibility", required: false,
                               granted: state.permissions.accessibilityGranted,
                               detail: "Required to paste your dictations into other apps, and for the global shortcuts. Without it, text is copied to the clipboard.",
                               grant: { state.permissions.promptAccessibility() })
                // Re-read the live grant state and re-arm the key readers, so flipping a switch in
                // System Settings updates here (and starts working) without relaunching the app.
                Button {
                    state.permissions.refresh()
                    AppDelegate.shared?.reloadRightCommandTrigger()
                } label: {
                    Label("Recheck permissions", systemImage: "arrow.clockwise").font(.caption)
                }
                .buttonStyle(.plain).foregroundStyle(Color.accentColor)
                .padding(.top, 2)
            }
            .frame(maxWidth: 460)
        }
    }

    // Page 3 - the live demo, in one cohesive glass card.
    private var demoStep: some View {
        VStack(spacing: 16) {
            VStack(spacing: 8) {
                Text("Watch it work").font(.title.weight(.bold))
                Text("Speak, tap a number to pick a post-processor, and the AI formats your words. Try 1, 2, or 3.")
                    .font(.body).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 460)
            }
            PipelineDemoView().frame(maxWidth: 440)
        }
    }

    // Page after "Watch it work": the SAME sentence run through two different modes at once, side by
    // side, so the value of modes/workflows is obvious - one voice, different formats.
    private var modesStep: some View {
        VStack(spacing: 16) {
            VStack(spacing: 8) {
                Text("One voice, any format").font(.title.weight(.bold))
                Text("A mode is a recipe for your words. Say something once and each mode formats it its own way: an email, a quick note, a message. Make your own for any workflow.")
                    .font(.body).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 470)
            }
            ModesDemoView().frame(maxWidth: 460)
            autoModeRow.frame(maxWidth: 460)
        }
    }

    /// Auto mode opt-in, right where modes are introduced: let the app pick the recipe itself.
    /// When it's on and no name is set yet, ask for the name HERE - Auto mode signs emails, and
    /// without a name the model has nothing truthful to sign with.
    private var autoModeRow: some View {
        VStack(spacing: 10) {
            autoModeToggleLine
            if state.settings.autoContextMode,
               state.settings.userName.trimmingCharacters(in: .whitespaces).isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Sign emails as:").font(.caption).foregroundStyle(.secondary)
                    NameCaptureField()   // draft-commit field: typing can't dismiss its own row
                }
            }
        }
        .padding(13)
        .yapGlass(in: RoundedRectangle(cornerRadius: Metrics.panelRadius, style: .continuous))
    }

    private var autoModeToggleLine: some View {
        HStack(spacing: 12) {
            Image(systemName: "wand.and.sparkles")
                .font(.system(size: 15, weight: .semibold))
                .iconTint(Color.accentColor)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text("Auto mode").font(.callout.weight(.medium))
                Text("Let the app read each dictation and pick the right format by itself.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Toggle("", isOn: Binding(get: { state.settings.autoContextMode },
                                     set: { state.settings.autoContextMode = $0 }))
                .labelsHidden().toggleStyle(.switch).controlSize(.small)
        }
    }

    // Page 3 - controls. The two options sit at the top, joined into one unit with a live demo of
    // the SELECTED option letterboxed directly underneath, so picking one instantly shows how it
    // behaves. The editable rows (Esc, custom shortcut) follow below.
    private var controlsStep: some View {
        VStack(spacing: 14) {
            VStack(spacing: 6) {
                Text("Your controls").font(.title.weight(.bold))
                Text("Pick how the Right \u{2318} key works. The demo below plays back your choice.")
                    .font(.body).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 460)
            }
            // One unit: the two options joined at the top, the live demo letterboxed beneath them.
            VStack(spacing: 12) {
                HStack(spacing: 10) {
                    triggerCard(icon: "hand.tap.fill", title: "Tap to toggle",
                                detail: "Tap Right \u{2318} to start, tap again to stop.",
                                selected: !pushToTalk && !useCustomDictation) {
                        pushToTalk = false; useCustomDictation = false
                    }
                    triggerCard(icon: "hand.raised.fill", title: "Hold to talk",
                                detail: "Hold Right \u{2318} while you speak, release to stop.",
                                selected: pushToTalk && !useCustomDictation) {
                        pushToTalk = true; useCustomDictation = false
                    }
                }
                ControlsPopupDemo(pushToTalk: pushToTalk)
                    .frame(maxWidth: .infinity)
                    .frame(height: 128)
                    .background(Color.secondary.opacity(0.05),
                                in: RoundedRectangle(cornerRadius: Metrics.panelRadius, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Metrics.panelRadius, style: .continuous)
                        .stroke(Color.secondary.opacity(0.1), lineWidth: 0.5))
            }
            .padding(12)
            .background(Color.secondary.opacity(0.05),
                        in: RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
                .stroke(Color.secondary.opacity(0.1), lineWidth: 0.5))
            .frame(maxWidth: 480)

            VStack(spacing: 10) {
                escRow
                customShortcut(on: $useCustomDictation, combo: $customDictation,
                               label: "Use a custom shortcut instead of Right \u{2318}")
            }
            .frame(maxWidth: 480)
        }
    }

    /// The Esc control, with a real "esc" keycap (the SF "escape" glyph reads as a random symbol).
    private var escRow: some View {
        HStack(spacing: 12) {
            keycap("esc")
            VStack(alignment: .leading, spacing: 1) {
                Text("Esc cancels dictation").font(.callout.weight(.medium))
                Text("Stops and discards it. Nothing is inserted or saved.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Toggle("", isOn: $escCancel).labelsHidden().toggleStyle(.switch).controlSize(.small)
        }
        .padding(13)
        .yapGlass(in: RoundedRectangle(cornerRadius: Metrics.panelRadius, style: .continuous))
    }

    private func keycap(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .foregroundStyle(.secondary)
            .frame(minWidth: 34, minHeight: 26)
            .background(Color.secondary.opacity(0.14), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Color.secondary.opacity(0.3), lineWidth: 0.5))
    }

    // Privacy / architecture: everything runs and stays on this Mac. Quiet surfaces (not stacked
    // glass) so the slide reads clean and stays light on the glass renderer.
    private var quickEditStep: some View {
        stepScaffold(icon: nil, title: "The Quick Edit key",
                     subtitle: "Fix text after it lands - by talking, not typing.") {
            QuickEditTutorial()
                .frame(maxWidth: 520)
        }
    }

    private var appearanceStep: some View {
        stepScaffold(icon: "paintpalette.fill", title: "Make it yours",
                     subtitle: "Pick your colors - everything applies instantly.") {
            AppearanceQuickPicker()
                .frame(maxWidth: 520)
        }
    }

    private var privacyStep: some View {
        VStack(spacing: 16) {
            VStack(spacing: 8) {
                Image(systemName: "lock.laptopcomputer")
                    .font(.system(size: 40, weight: .semibold))
                    .iconTint(Color.accentColor)
                    .frame(width: 74, height: 74)
                Text("Everything stays on your Mac").font(.title.weight(.bold)).multilineTextAlignment(.center)
                Text("YapToText is private by design: no account, no cloud, no tracking. It's yours, running entirely on your computer.")
                    .font(.body).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 470)
            }
            VStack(spacing: 10) {
                privacyRow("cpu", "On-device AI",
                           "The speech model and AI cleanup run locally with Apple Intelligence and on-device models. Your voice is turned into text right here.")
                privacyRow("internaldrive", "Your data stays put",
                           "Transcripts, history, and audio live only on this Mac, in the app's own storage, and you can delete any of it anytime.")
                privacyRow("wifi.slash", "Works offline",
                           "Dictation needs no network. Nothing is uploaded, and there are no servers to trust.")
            }
            .frame(maxWidth: 480)
            HStack(spacing: 4) {
                Text("Our official privacy policy can be read")
                    .font(.caption).foregroundStyle(.secondary)
                Link("here", destination: SupportLinks.privacy)
                    .font(.caption.weight(.medium))
            }
        }
    }

    private func privacyRow(_ icon: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            IconBadge(symbol: icon, tint: .accentColor, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(13)
        .background(Color.secondary.opacity(0.05),
                    in: RoundedRectangle(cornerRadius: Metrics.panelRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Metrics.panelRadius, style: .continuous)
            .stroke(Color.secondary.opacity(0.1), lineWidth: 0.5))
    }

    // Final page: you're set, the one gesture to remember, and a clearly-labelled name prompt.
    private var readyStep: some View {
        VStack(spacing: 22) {
            VStack(spacing: 12) {
                Text("You're all set").font(.largeTitle.weight(.bold))
                Text("Tap Right \u{2318} anywhere on your Mac and start talking. Everything's changeable later in Settings.")
                    .font(.title3).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 460)
                Text("And don't let all the panels overwhelm you. The app is ready exactly as it is. Dictate from day one; dive into modes, dictionaries, and commands whenever curiosity strikes.")
                    .font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 440)
            }
            VStack(spacing: 8) {
                Text("What should we call you?").font(.callout.weight(.semibold))
                Text("Type your name below so AI modes can sign your emails for you instead of writing \u{201C}[Your Name]\u{201D}. It's optional, so feel free to skip it.")
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 420)
                nameField.frame(maxWidth: 430)
            }
        }
    }

    // MARK: Building blocks

    private func stepScaffold<C: View>(icon: String?, title: String, subtitle: String,
                                       @ViewBuilder body: () -> C) -> some View {
        VStack(spacing: 16) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 34, weight: .semibold))
                    .iconTint(Color.accentColor)
                    .frame(width: 74, height: 74)
                    .yapGlass(in: Circle())
            }
            VStack(spacing: 8) {
                Text(title).font(.title.weight(.bold)).multilineTextAlignment(.center)
                Text(subtitle).font(.body).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 460)
            }
            body().padding(.top, 4)
        }
    }

    private func permissionCard(icon: String, title: String, required: Bool, granted: Bool,
                                detail: String, grant: @escaping () -> Void) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon).font(.title2).iconTint(Color.accentColor)
                .frame(width: 40, height: 40).yapGlass(in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title).fontWeight(.semibold)
                    Text(required ? "Required" : "Recommended")
                        .font(.caption2).foregroundStyle(.secondary)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.12), in: Capsule())
                }
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if granted {
                HStack(spacing: 5) {
                    Circle().fill(.green).frame(width: 8, height: 8)
                    Text("Granted").font(.callout).foregroundStyle(.secondary)
                }
            } else {
                Button("Enable") { grant() }.buttonStyle(.solidSecondary).controlSize(.small)
            }
        }
        .padding(14)
        .yapGlass(in: RoundedRectangle(cornerRadius: Metrics.panelRadius, style: .continuous))
    }

    /// A selectable glass option card (radio-style) for the start-dictation behavior. Stretches to
    /// the tallest sibling (maxHeight: .infinity) so the two options are always equal height even
    /// when their detail text wraps to different line counts.
    private func triggerCard(icon: String, title: String, detail: String,
                             selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Image(systemName: icon).font(.title3)
                        .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                    Spacer()
                    Image(systemName: selected ? "circle.inset.filled" : "circle")
                        .foregroundStyle(selected ? Color.accentColor : Color.secondary.opacity(0.4))
                }
                Text(title).font(.callout.weight(.semibold)).foregroundStyle(.primary)
                Text(detail).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(13)
            .yapGlass(in: RoundedRectangle(cornerRadius: Metrics.panelRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Metrics.panelRadius, style: .continuous)
                .stroke(selected ? Color.accentColor.opacity(0.7) : Color.clear, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
        .animation(.spring(duration: 0.3), value: selected)
    }

    /// Optional name captured up front so AI modes (like Email) can sign off with it instead of a
    /// "[Your Name]" placeholder.
    private var nameField: some View {
        HStack(spacing: 12) {
            // A visibly recessed text box so it clearly reads as "type here", not a label.
            TextField("Type your name here", text: Binding(
                get: { state.settings.userName },
                set: { state.settings.userName = $0 }))
                .textFieldStyle(.plain)
                .font(.body)
                .padding(.horizontal, 10).padding(.vertical, 8)
                .innerWell(radius: Metrics.innerRadius)
        }
        .padding(13)
        .yapGlass(in: RoundedRectangle(cornerRadius: Metrics.panelRadius, style: .continuous))
    }

    private func customShortcut(on: Binding<Bool>, combo: Binding<KeyCombo?>, label: String) -> some View {
        VStack(spacing: 10) {
            Toggle(label, isOn: on).toggleStyle(.switch).controlSize(.small)
            if on.wrappedValue {
                VStack(spacing: 6) {
                    HStack {
                        Text("Press your keys now:").font(.callout).foregroundStyle(.secondary)
                        Spacer()
                        HotkeyRecorderField(combo: combo, allowsEmpty: true, autoStart: true)
                            .frame(width: 110, height: 24)
                    }
                    Text(captionFor(combo.wrappedValue))
                        .font(.caption).foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 2)
        .animation(.easeInOut(duration: 0.2), value: on.wrappedValue)
    }

    /// Live caption for the shortcut recorder: what state it is in, and an honest warning when
    /// a modifier-less key is chosen (it will trigger dictation every time it is pressed, anywhere).
    private func captionFor(_ combo: KeyCombo?) -> String {
        guard let combo else {
            return "The box is listening. Press any key or combo, like \u{2325}\u{2318}D or F13. If nothing registers, click the box once and try again."
        }
        if combo.modifiers == 0 {
            return "Saved. Heads up: a bare key starts dictation every time you press it, in every app. A combo with \u{2318} or \u{2325} avoids surprises."
        }
        return "Saved. Click the box to change it."
    }

    // MARK: Flow

    private func advance() {
        guard let next = Step(rawValue: step.rawValue + 1) else { finish(); return }
        forward = true
        withAnimation(.easeInOut(duration: 0.3)) { step = next }
        if next == .permissions { state.permissions.refresh() }
    }

    private func goBack() {
        guard let prev = Step(rawValue: step.rawValue - 1) else { return }
        forward = false
        withAnimation(.easeInOut(duration: 0.3)) { step = prev }
    }

    private func finish() {
        let s = state.settings
        if useCustomDictation, let combo = customDictation {
            s.hotkey = combo
            s.rightCommandTrigger = .off
        } else {
            s.rightCommandTrigger = pushToTalk ? .pushToTalk : .toggle
        }
        s.cancelOnDoubleEscape = escCancel
        s.rightCommandSpaceSwitcher = false
        s.switcherHotkey = nil
        s.hasCompletedOnboarding = true
        // Fresh installs just saw everything, including Quick Edit - never show them the
        // What's New sheet for this version.
        s.lastSeenWhatsNewVersion = Changelog.currentVersion

        AppDelegate.shared?.reloadHotkey()
        AppDelegate.shared?.reloadRightCommandTrigger()
        AppDelegate.shared?.reloadSwitcherHotkey()
        withAnimation(.easeInOut(duration: 0.45)) { isPresented = false }
    }
}

// MARK: - Controls page animation (press the key -> the panel pops up)

/// The core gesture, end to end, using the REAL panel components. It plays back the SELECTED
/// trigger style: in Tap-to-toggle it taps once to start and once to stop; in Hold-to-talk the key
/// presses and STAYS held for the whole listening phase, then releases to stop. Loops. Key on top,
/// arrow down, panel underneath.
private struct ControlsPopupDemo: View {
    @Environment(AppState.self) private var state
    let pushToTalk: Bool
    private enum Phase { case idle, listening, processing }
    @State private var phase: Phase = .idle
    @State private var keyPressed = false
    @State private var demoData = AudioVisualData(bands: 26)

    var body: some View {
        VStack(spacing: 9) {
            keycap
            Image(systemName: "arrow.down").font(.caption2).foregroundStyle(.tertiary).opacity(0.55)
            panel
        }
        .frame(maxWidth: 300)
        // Restart the playback whenever the chosen style changes, so the animation always matches.
        .task(id: pushToTalk) { await runLoop() }
        .accessibilityHidden(true)
    }

    private var keycap: some View {
        Text("Right \u{2318}")
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(Color.secondary.opacity(keyPressed ? 0.28 : 0.12),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.secondary.opacity(0.3), lineWidth: 0.5))
            .scaleEffect(keyPressed ? 0.93 : 1)
            .shadow(color: keyPressed ? Color.accentColor.opacity(0.4) : .clear, radius: 6)
            .animation(.easeOut(duration: 0.12), value: keyPressed)
    }

    /// The real panel look: our glass surface with the live WaveformView, or the processing state.
    private var panel: some View {
        HStack(spacing: 10) {
            // The demo wave condenses into the spinner exactly like the real panel -
            // no structural swap, the wave IS the processing indicator.
            WaveformView(data: demoData, isActive: phase == .listening, scale: 0.78,
                         style: state.settings.waveStyle,
                         freeze: phase == .processing, sucking: phase == .processing,
                         usesSharedClock: false)
                .frame(maxWidth: .infinity)
            Text(phase == .processing ? "Transcribing\u{2026}" : "Listening\u{2026}")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(height: 30)
        .padding(.horizontal, 14).padding(.vertical, 9)
        .frame(width: 264)
        .yapGlass(in: RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous))
        .opacity(phase == .idle ? 0 : 1)
        .scaleEffect(phase == .idle ? 0.94 : 1, anchor: .top)
        .animation(.spring(response: 0.34, dampingFraction: 0.82), value: phase)
    }

    @MainActor
    private func runLoop() async {
        func nap(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000)) }
        while !Task.isCancelled {
            phase = .idle
            keyPressed = false
            await nap(0.7)
            if pushToTalk {
                keyPressed = true                                       // press and HOLD
                await nap(0.28)
                phase = .listening
                let wave = Task { await animateWave() }
                await nap(2.2)                                          // stays held while listening
                wave.cancel()
                keyPressed = false                                      // release -> stop
            } else {
                keyPressed = true; await nap(0.16); keyPressed = false  // tap 1 -> start
                phase = .listening
                let wave = Task { await animateWave() }
                await nap(2.2)
                wave.cancel()
                keyPressed = true; await nap(0.16); keyPressed = false  // tap 2 -> stop
            }
            phase = .processing
            await nap(1.5)
            phase = .idle
            await nap(0.4)
        }
    }

    @MainActor
    private func animateWave() async {
        var f = 0.0
        while !Task.isCancelled {
            f += 0.12
            demoData.spectrum = (0..<26).map { b in
                let u = Double(b) / 25.0
                let hump = exp(-pow((u - 0.5) * 2.4, 2))
                return Float(max(0, hump * (0.5 + 0.5 * sin(f * 2 + u * 6))))
            }
            demoData.level = Float(0.5 + 0.35 * abs(sin(f * 1.6)))
            try? await Task.sleep(nanoseconds: 90_000_000)
        }
    }
}

// MARK: - The live pipeline demo

/// A working replica of the dictation panel that plays the whole pipeline on a loop, in ONE
/// cohesive glass card: simulated speech animates the real WaveformView and types the raw
/// transcript, a number key visibly picks the post-processor, then the formatted result types out.
private struct PipelineDemoView: View {
    @Environment(AppState.self) private var state
    enum Phase { case listening, picking, processing, result }

    private struct Processor { let name: String; let output: String }

    private static let spoken = "hey um can you send over the q3 numbers before friday thanks"
    private static let processors: [Processor] = [
        Processor(name: "Raw", output: "hey um can you send over the q3 numbers before friday thanks"),
        Processor(name: "Email", output: "Hi,\n\nCould you send over the Q3 numbers before Friday?\n\nThanks!"),
        Processor(name: "Note", output: "- Ask for Q3 numbers\n- Deadline: Friday"),
    ]

    @State private var phase: Phase = .listening
    @State private var selected = 1
    @State private var typedTarget = ""
    @State private var outputTarget = ""
    @State private var cycle = 0
    @State private var demoData = AudioVisualData(bands: 26)
    @State private var pressedKey: Int?

    var body: some View {
        VStack(spacing: 0) {
            // Top: the mini recording panel.
            VStack(alignment: .leading, spacing: 8) {
                WaveformView(data: demoData, isActive: phase == .listening, scale: 0.9,
                             style: state.settings.waveStyle,
                             freeze: phase == .picking || phase == .processing,
                             sucking: phase == .picking || phase == .processing,
                             usesSharedClock: false)
                    .frame(maxWidth: .infinity)
                Group {
                    if typedTarget.isEmpty {
                        Text("Listening\u{2026}").foregroundStyle(.secondary)
                    } else {
                        TypewriterText(target: typedTarget, fontSize: 13).id("in-\(cycle)")
                    }
                }
                .font(.system(size: 13))
                .frame(height: 34, alignment: .topLeading)
                .frame(maxWidth: .infinity, alignment: .leading)
                chips
            }
            .padding(14)

            Divider().opacity(0.35)

            // Middle: what's happening.
            HStack(spacing: 6) {
                switch phase {
                case .listening: Label("You talk and the raw words stream in", systemImage: "mic.fill")
                case .picking: Label("Press \(selected + 1) to choose \(Self.processors[selected].name)", systemImage: "hand.tap.fill")
                case .processing: Label("The on-device AI reformats your words\u{2026}", systemImage: "sparkles")
                case .result: Label("Inserted where your cursor was, as \(Self.processors[selected].name)", systemImage: "text.cursor")
                }
                Spacer(minLength: 0)
            }
            .font(.caption).foregroundStyle(.secondary)
            .padding(.horizontal, 14).padding(.vertical, 9)
            .animation(.easeInOut(duration: 0.25), value: phase)

            Divider().opacity(0.35)

            // Bottom: the formatted result.
            Group {
                if outputTarget.isEmpty {
                    Text("Your formatted text lands here.").font(.system(size: 13)).foregroundStyle(.tertiary)
                } else {
                    TypewriterText(target: outputTarget, fontSize: 13).id("out-\(cycle)")
                }
            }
            .frame(maxWidth: .infinity, minHeight: 78, alignment: .topLeading)
            .padding(14)
        }
        .yapGlass(in: RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
            .stroke(phase == .result ? Color.accentColor.opacity(0.4) : Color.secondary.opacity(0.12), lineWidth: 0.75))
        .animation(.easeInOut(duration: 0.3), value: phase)
        .task(id: selected) { await runLoop() }
        .focusable()
        .onKeyPress(characters: CharacterSet(charactersIn: "123")) { press in
            if let d = Int(String(press.characters.first ?? " ")), d >= 1, d <= 3 { selected = d - 1 }
            return .handled
        }
    }

    private var chips: some View {
        HStack(spacing: 5) {
            ForEach(Array(Self.processors.enumerated()), id: \.offset) { index, proc in
                let isCurrent = index == selected
                let isPressed = pressedKey == index
                Button { selected = index } label: {
                    HStack(spacing: 3) {
                        Text("\(index + 1)")
                            .font(.system(size: 9, weight: .bold).monospacedDigit())
                            .foregroundStyle(isCurrent ? Color.white : Color.secondary)
                            .frame(width: 13, height: 13)
                            .background(isCurrent ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.secondary.opacity(0.15)), in: Circle())
                        Text(proc.name).font(.system(size: 10, weight: isCurrent ? .semibold : .regular))
                            .foregroundStyle(isCurrent ? .primary : .secondary)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(isCurrent ? Color.accentColor.opacity(0.16) : Color.secondary.opacity(0.06), in: Capsule())
                    .overlay(Capsule().stroke(isCurrent ? Color.accentColor.opacity(0.5) : Color.secondary.opacity(0.12), lineWidth: 0.5))
                    .scaleEffect(isPressed ? 0.86 : 1)
                    .animation(.spring(duration: 0.25), value: isPressed)
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
    }

    // MARK: Demo script

    @MainActor
    private func runLoop() async {
        while !Task.isCancelled {
            cycle += 1
            typedTarget = ""
            outputTarget = ""
            pressedKey = nil
            phase = .listening

            let words = Self.spoken.split(separator: " ")
            var spokenSoFar = ""
            for (i, word) in words.enumerated() {
                guard !Task.isCancelled else { return }
                spokenSoFar += (spokenSoFar.isEmpty ? "" : " ") + word
                typedTarget = spokenSoFar
                await animateSpeech(frames: 4, wordSeed: i)
            }
            await settleWave(frames: 6)
            guard !Task.isCancelled else { return }

            phase = .picking
            try? await Task.sleep(nanoseconds: 500_000_000)
            pressedKey = selected
            try? await Task.sleep(nanoseconds: 350_000_000)
            pressedKey = nil
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard !Task.isCancelled else { return }

            phase = .processing
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            guard !Task.isCancelled else { return }

            phase = .result
            outputTarget = Self.processors[selected].output
            try? await Task.sleep(nanoseconds: 4_600_000_000)
        }
    }

    @MainActor
    private func animateSpeech(frames: Int, wordSeed: Int) async {
        for f in 0..<frames {
            guard !Task.isCancelled else { return }
            let t = Double(wordSeed) * 0.9 + Double(f) * 0.2
            demoData.spectrum = (0..<26).map { b in
                let u = Double(b) / 25.0
                let hump1 = exp(-pow((u - (0.25 + 0.15 * sin(t))) * 4.5, 2))
                let hump2 = 0.6 * exp(-pow((u - (0.65 + 0.12 * cos(t * 1.3))) * 5.0, 2))
                let energy = 0.5 + 0.35 * sin(t * 2.1 + Double(wordSeed))
                return Float(max(0, (hump1 + hump2) * energy))
            }
            demoData.level = Float(0.55 + 0.35 * abs(sin(t * 2.4 + Double(wordSeed) * 0.7)))
            try? await Task.sleep(nanoseconds: 90_000_000)
        }
    }

    @MainActor
    private func settleWave(frames: Int) async {
        for _ in 0..<frames {
            guard !Task.isCancelled else { return }
            demoData.spectrum = demoData.spectrum.map { $0 * 0.6 }
            demoData.level *= 0.6
            try? await Task.sleep(nanoseconds: 60_000_000)
        }
        demoData.spectrum = Array(repeating: 0, count: 26)
        demoData.level = 0
    }
}

// MARK: - Modes comparison demo

/// One spoken sentence formatted by TWO different modes at once, side by side, so the value of
/// modes is obvious: same input, different output. Uses quiet recessed surfaces (not stacked glass)
/// and the framerate-capped TypewriterText, so the looping animation stays light on the glass
/// renderer.
private struct ModesDemoView: View {
    private struct ModeResult: Identifiable {
        let id = UUID(); let icon: String; let name: String; let output: String
    }
    private static let spoken = "hey can you send me the q3 numbers before friday thanks"
    private static let results: [ModeResult] = [
        ModeResult(icon: "envelope.fill", name: "Email",
                   output: "Hi,\n\nCould you send the Q3 numbers by Friday?\n\nThanks!"),
        ModeResult(icon: "text.badge.checkmark", name: "Note",
                   output: "\u{2022} Q3 numbers\n\u{2022} Due Friday"),
    ]

    @State private var rawTyped = ""
    @State private var showOutputs = false
    @State private var cycle = 0
    @State private var demoData = AudioVisualData(bands: 26)
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(spacing: 10) {
            // The spoken sentence - with the real wave above it, listening while the words
            // stream in and condensing into the ring the moment they land (the same
            // choreography as the live panel, homogeneous across every demo).
            VStack(alignment: .leading, spacing: 3) {
                WaveformView(data: demoData, isActive: rawTyped.isEmpty, scale: 0.7,
                             style: state.settings.waveStyle,
                             freeze: !rawTyped.isEmpty, sucking: !rawTyped.isEmpty,
                             usesSharedClock: false)
                    .frame(maxWidth: .infinity)
                    .frame(height: 26)
                Group {
                    if rawTyped.isEmpty {
                        Text("Listening\u{2026}").foregroundStyle(.secondary)
                    } else {
                        TypewriterText(target: rawTyped, fontSize: 13).id("raw-\(cycle)")
                    }
                }
                .font(.system(size: 13))
                .frame(maxWidth: .infinity, minHeight: 34, alignment: .topLeading)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .innerWell(radius: Metrics.panelRadius)

            Image(systemName: "arrow.down").font(.caption).foregroundStyle(.tertiary)
                .opacity(showOutputs ? 1 : 0.3)

            // Same input, two modes, two outputs.
            HStack(alignment: .top, spacing: 10) {
                ForEach(Self.results) { modeColumn($0) }
            }
        }
        .task { await loop() }
        .accessibilityHidden(true)
    }

    private func modeColumn(_ r: ModeResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: r.icon).iconTint(.accentColor).font(.system(size: 12))
                Text(r.name).font(.caption.weight(.semibold))
            }
            Group {
                if showOutputs {
                    TypewriterText(target: r.output, fontSize: 12).id("\(r.name)-\(cycle)")
                } else {
                    Text(" ").font(.system(size: 12))
                }
            }
            .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .innerWell(radius: Metrics.panelRadius)
    }

    @MainActor
    private func loop() async {
        func nap(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000)) }
        while !Task.isCancelled {
            cycle += 1
            rawTyped = ""
            showOutputs = false
            // Animate the demo wave while "listening" (1.6s of synthetic speech).
            let waveTask = Task { @MainActor in
                var f = 0.0
                while !Task.isCancelled {
                    f += 0.12
                    demoData.spectrum = (0..<26).map { b in
                        let u = Double(b) / 25.0
                        let hump = exp(-pow((u - 0.5) * 2.4, 2))
                        return Float(max(0, hump * (0.5 + 0.5 * sin(f * 2 + u * 6))))
                    }
                    demoData.level = 0.5
                    try? await Task.sleep(nanoseconds: 33_000_000)
                }
            }
            await nap(1.6)
            waveTask.cancel()
            guard !Task.isCancelled else { return }
            rawTyped = Self.spoken                                        // types the raw words
            await nap(2.2)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.3)) { showOutputs = true } // both outputs type at once
            await nap(4.8)                                                // hold so it's readable
        }
    }
}

// MARK: - Decorative background

/// A living mesh-gradient aurora behind the welcome content; drifts slowly, holds still under
/// Reduce Motion.
private struct AuroraBackground: View {
    @Environment(\.controlActiveState) private var activeState
    var reduceMotion: Bool

    private let colors: [Color] = [
        .accentColor.opacity(0.55), .cyan.opacity(0.40), .mint.opacity(0.45),
        .cyan.opacity(0.40), .accentColor.opacity(0.45), .cyan.opacity(0.40),
        .mint.opacity(0.40), .accentColor.opacity(0.45), .cyan.opacity(0.50),
    ]

    var body: some View {
        // ~20fps, not every display frame: the aurora drifts slowly so this is visually identical,
        // and it roughly 6x's fewer render transactions behind all the onboarding glass - easing the
        // load on macOS 26.5's crash-prone DesignLibrary glass renderer.
        TimelineView(.animation(minimumInterval: 1.0 / 12.0, paused: reduceMotion || activeState == .inactive)) { timeline in
            let t = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
            if #available(macOS 15.0, *), !CompatPreview.legacy {
                MeshGradient(width: 3, height: 3, points: points(t), colors: colors)
                    .opacity(0.55)
                    .blur(radius: 60)
                    .ignoresSafeArea()
            } else {
                // macOS 14: no MeshGradient - a soft static wash keeps the mood without the drift.
                LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
                    .opacity(0.45)
                    .blur(radius: 60)
                    .ignoresSafeArea()
            }
        }
    }

    private func points(_ t: Double) -> [SIMD2<Float>] {
        func wob(_ x: Float, _ y: Float, ax: Double, ay: Double, speed: Double, phase: Double) -> SIMD2<Float> {
            SIMD2(x + Float(sin(t * speed + phase) * ax), y + Float(cos(t * speed * 1.3 + phase) * ay))
        }
        return [
            SIMD2(0, 0), SIMD2(0.5, 0), SIMD2(1, 0),
            wob(0, 0.5, ax: 0, ay: 0.10, speed: 0.35, phase: 0),
            wob(0.5, 0.5, ax: 0.12, ay: 0.10, speed: 0.30, phase: 1.5),
            wob(1, 0.5, ax: 0, ay: 0.10, speed: 0.40, phase: 3.0),
            SIMD2(0, 1), SIMD2(0.5, 1), SIMD2(1, 1),
        ]
    }
}
