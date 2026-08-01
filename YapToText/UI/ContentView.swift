import SwiftUI
import AppKit

/// Behind-window vibrancy giving the app the same frosted, translucent look as InputConfig and
/// CubeAura: an NSVisualEffectView with the `.hudWindow` material blending behind the window,
/// and the host window made non-opaque so the blur samples the desktop rather than a solid fill.
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        DispatchQueue.main.async { [weak nsView] in
            guard let window = nsView?.window else { return }
            window.isOpaque = false
            window.backgroundColor = .clear
            window.titlebarAppearsTransparent = true
        }
    }
}

extension Notification.Name {
    static let yapShowHome = Notification.Name("yapShowHome")
    static let yapShowModes = Notification.Name("yapShowModes")
    static let yapShowDictionaries = Notification.Name("yapShowDictionaries")
    static let yapShowWelcome = Notification.Name("yapShowWelcome")
    static let yapShowMode = Notification.Name("yapShowMode")   // object: the mode's UUID
    static let yapShowHistory = Notification.Name("yapShowHistory")
    static let yapShowSettings = Notification.Name("yapShowSettings")
    /// Fired after navigating to Settings from an "Edit binding" link: the Shortcuts card
    /// glows green for a moment - "hey, it's over here."
    static let yapHighlightShortcuts = Notification.Name("yapHighlightShortcuts")
    static let yapNewMode = Notification.Name("yapNewMode")
    static let yapTranscribeFile = Notification.Name("yapTranscribeFile")
    /// Jump to any sidebar destination (object: AppDestination.rawValue). Used by Home's quick tips.
    static let yapShowDestination = Notification.Name("yapShowDestination")
}

/// The top-level places in the app. The sidebar lists these pathways; the middle pane shows
/// the selected one. Modes, dictionaries, history, and settings are all destinations here
/// rather than scattered across a toolbar and a sidebar of presets.
enum AppDestination: String, Hashable, CaseIterable, Identifiable {
    // Models sits ABOVE Modes: chronologically you pick the brain first, then shape how it writes.
    case home, dictation, quickEdit, modes, actions, dictionaries, commands, history, models, utility, stats, settings
    var id: String { rawValue }
    var label: String {
        switch self {
        case .home: return "Home"
        case .dictation: return "Dictation"
        case .quickEdit: return "Quick Edit"
        case .utility: return "Utility"
        case .models: return "AI Models"
        case .modes: return "Modes"
        case .actions: return "AI Actions"
        case .dictionaries: return "Dictionaries"
        case .commands: return "Commands"
        case .history: return "History"
        case .stats: return "Statistics"
        case .settings: return "Settings"
        }
    }
    var icon: String {
        switch self {
        case .home: return "house"
        case .dictation: return "mic"
        case .quickEdit: return "pencil.line"
        case .utility: return "square.grid.2x2"
        case .models: return "cpu"
        case .modes: return "slider.horizontal.3"
        case .actions: return "wand.and.rays"
        case .dictionaries: return "character.book.closed"
        case .commands: return "text.badge.plus"
        case .history: return "clock.arrow.circlepath"
        case .stats: return "chart.bar.xaxis"
        case .settings: return "gearshape"
        }
    }
}

struct ContentView: View {
    @Environment(AppState.self) private var state
    @State private var destination: AppDestination = .home
    @State private var modePath: [UUID] = []
    @State private var settingsTab: SettingsView.SettingsTab = .general
    @State private var sidebarQuery = ""
    @State private var showWelcome = false
    @State private var showWhatsNew = false

    var body: some View {
        ZStack {
            NavigationSplitView {
                sidebar
            } detail: {
                detail
                    // Fade content out under the navigation title as it scrolls up, so a section
                    // name like "Commands" never collides with the page content. The fade must span
                    // the whole title-bar band (not just the very top), so it's a tall, soft ramp.
                    .mask(
                        VStack(spacing: 0) {
                            LinearGradient(stops: [.init(color: .clear, location: 0),
                                                   .init(color: .black.opacity(0.35), location: 0.45),
                                                   .init(color: .black, location: 1)],
                                           startPoint: .top, endPoint: .bottom)
                                .frame(height: 76)
                            Rectangle().fill(.black)
                        }
                        .ignoresSafeArea()
                    )
            }
            .focusEffectDisabled()
            .background(AppWindowBackground())
            .toolbarBackground(.hidden, for: .windowToolbar)
            // During onboarding the welcome overlay owns the whole window, so hide the sidebar
            // toggle and "Home" title that would otherwise peek through the titlebar.
            .toolbar(showWelcome ? .hidden : .automatic, for: .windowToolbar)

            if showWelcome {
                WelcomeView(isPresented: $showWelcome)
                    .transition(.opacity)
                    .zIndex(1)
            }
        }
        // Hierarchical rendering across the whole app: every colored SF Symbol draws its tint at
        // varying opacities (an element of transparency in the secondary layers) instead of one
        // flat solid fill - no gradients.
        .symbolRenderingMode(.hierarchical)
        .yapAccent(state.settings)
        .onAppear {
            if !state.settings.hasCompletedOnboarding {
                showWelcome = true
            } else if state.settings.lastSeenWhatsNewVersion != Changelog.currentVersion {
                // Existing user, new version: one What's New sheet, once. New installs never
                // see it (onboarding stamps the version when it completes).
                showWhatsNew = true
            }
        }
        .sheet(isPresented: $showWhatsNew) { WhatsNewView().environment(state) }
        .onReceive(publisher(.yapShowWelcome)) { _ in withAnimation { showWelcome = true } }
        .onReceive(publisher(.yapShowHome)) { _ in destination = .home }
        .onReceive(publisher(.yapShowModes)) { _ in destination = .modes }
        .onReceive(publisher(.yapShowDictionaries)) { _ in destination = .dictionaries }
        .onReceive(publisher(.yapShowMode)) { note in
            guard let id = note.object as? UUID else { return }
            destination = .modes
            modePath = [id]
        }
        .onReceive(publisher(.yapShowHistory)) { _ in destination = .history }
        .onReceive(publisher(.yapShowSettings)) { note in
            if let tab = note.object as? SettingsView.SettingsTab { settingsTab = tab }
            destination = .settings
        }
        .onReceive(publisher(.yapShowDestination)) { note in
            if let raw = note.object as? String, let dest = AppDestination(rawValue: raw) { destination = dest }
        }
        .onReceive(publisher(.yapNewMode)) { _ in newMode() }
    }

    private func publisher(_ name: Notification.Name) -> NotificationCenter.Publisher {
        NotificationCenter.default.publisher(for: name)
    }

    // MARK: Sidebar (pathways)

    private var sidebar: some View {
        VStack(spacing: 0) {
            StatusStrip(controller: state.controller)
            sidebarSearchField
            List(selection: sidebarSelection) {
                if sidebarQuery.trimmingCharacters(in: .whitespaces).isEmpty {
                    Section {
                        ForEach(AppDestination.allCases) { dest in
                            Label(dest.label, systemImage: dest.icon)
                                .padding(.vertical, 4)
                                .tag(dest)
                        }
                    } header: {
                        Color.clear.frame(height: 4)   // breathing room so Home isn't jammed at the top
                    }
                } else {
                    Section("Results") {
                        let hits = searchResults
                        if hits.isEmpty {
                            Text("No matches.")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            ForEach(hits) { hit in
                                Button { open(hit) } label: {
                                    VStack(alignment: .leading, spacing: 1) {
                                        Label(hit.title, systemImage: hit.icon)
                                        Text(hit.subtitle).font(.caption2).foregroundStyle(.secondary)
                                            .padding(.leading, 25)
                                    }
                                    .padding(.vertical, 3)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, 36)
            sidebarFooter
        }
        .navigationTitle("YapToText")
        .frame(minWidth: 248)
        // A crisp hairline down the sidebar's trailing edge, so the vertical menu reads as its own
        // defined panel (matching InputConfig).
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(width: 1)
                .ignoresSafeArea()
        }
    }

    private var sidebarSelection: Binding<AppDestination?> {
        Binding(get: { destination }, set: { if let d = $0 { destination = d } })
    }

    // MARK: Sidebar search (find any page or setting by name)

    /// One place a setting or page can be found from. `tab` routes inside Settings; `support`
    /// opens the tip-jar window.
    private struct SearchHit: Identifiable {
        let id = UUID()
        let title: String
        let subtitle: String
        let icon: String
        let keywords: String
        var destination: AppDestination?
        var tab: SettingsView.SettingsTab?
        var opensSupport = false
    }

    private var sidebarSearchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.caption)
            TextField("Search settings & pages", text: $sidebarQuery)
                .textFieldStyle(.plain).font(.callout)
            if !sidebarQuery.isEmpty {
                Button { sidebarQuery = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .innerWell(radius: Metrics.innerRadius)
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .accessibilityLabel("Search settings and pages")
    }

    /// The searchable index: every page plus the individual settings people actually hunt for.
    private static let searchIndex: [SearchHit] = [
        // Pages
        SearchHit(title: "Statistics", subtitle: "Charts, streaks, and insights", icon: "chart.bar.xaxis",
                  keywords: "stats statistics insights charts streak words per minute", destination: .stats),
        SearchHit(title: "Home", subtitle: "Welcome, quick controls, setup", icon: "house",
                  keywords: "home start welcome quick controls", destination: .home),
        SearchHit(title: "Utility", subtitle: "Dictate, transform, transcribe in-app", icon: "square.grid.2x2",
                  keywords: "utility scratchpad transform transcribe file workbench", destination: .utility),
        SearchHit(title: "AI Models", subtitle: "Speech & cleanup models, downloads", icon: "cpu",
                  keywords: "models whisper apple intelligence download energy battery accuracy language engine", destination: .models),
        SearchHit(title: "Modes", subtitle: "How your words get formatted", icon: "slider.horizontal.3",
                  keywords: "modes email note message code raw prompt instructions", destination: .modes),
        SearchHit(title: "AI Actions", subtitle: "Rewrite selected text anywhere", icon: "wand.and.rays",
                  keywords: "actions rewrite improve grammar summarize translate selection", destination: .actions),
        SearchHit(title: "Dictionaries", subtitle: "Fix names and spellings", icon: "character.book.closed",
                  keywords: "dictionaries vocabulary replacements words spelling names jargon", destination: .dictionaries),
        SearchHit(title: "Commands", subtitle: "Spoken symbols and emoji", icon: "text.badge.plus",
                  keywords: "commands spoken emoji symbols punctuation", destination: .commands),
        SearchHit(title: "History", subtitle: "Every past dictation", icon: "clock.arrow.circlepath",
                  keywords: "history past dictations search export audio", destination: .history),
        SearchHit(title: "Settings", subtitle: "General preferences", icon: "gearshape",
                  keywords: "settings preferences general", destination: .settings, tab: .general),
        SearchHit(title: "Advanced", subtitle: "Output, history, backups", icon: "gearshape.2",
                  keywords: "advanced output history retention backup preset per app", destination: .settings, tab: .advanced),
        SearchHit(title: "Input source", subtitle: "Settings > General", icon: "mic.badge.plus",
                  keywords: "input source microphone device headset select mic", destination: .settings, tab: .general),
        SearchHit(title: "Your name", subtitle: "Settings > Advanced", icon: "person",
                  keywords: "name sign signature email personalize", destination: .settings, tab: .advanced),
        SearchHit(title: "About", subtitle: "Version, story, links", icon: "info.circle",
                  keywords: "about version open source github credits", destination: .settings, tab: .about),
        // Individual settings (all live in Settings > General unless noted)
        SearchHit(title: "Keyboard shortcut", subtitle: "Settings > General", icon: "keyboard",
                  keywords: "shortcut hotkey start stop key combo record", destination: .settings, tab: .general),
        SearchHit(title: "Right Command key", subtitle: "Settings > General", icon: "command",
                  keywords: "right command tap toggle hold push to talk trigger", destination: .settings, tab: .general),
        SearchHit(title: "Esc cancels dictation", subtitle: "Settings > General", icon: "escape",
                  keywords: "escape cancel discard", destination: .settings, tab: .general),
        SearchHit(title: "Recording panel", subtitle: "Settings > General", icon: "rectangle.on.rectangle",
                  keywords: "panel popup position size big small compact hud", destination: .settings, tab: .general),
        SearchHit(title: "Sounds", subtitle: "Settings > General", icon: "speaker.wave.2",
                  keywords: "sounds start stop chime feedback", destination: .settings, tab: .general),
        SearchHit(title: "Microphone input", subtitle: "Settings > General", icon: "mic",
                  keywords: "microphone gain boost input level meter amplify", destination: .settings, tab: .general),
        SearchHit(title: "Auto-stop", subtitle: "Settings > General", icon: "timer",
                  keywords: "auto stop silence timeout maximum length recording", destination: .settings, tab: .general),
        SearchHit(title: "Insertion method", subtitle: "Settings > Advanced", icon: "text.cursor",
                  keywords: "insert paste type clipboard cursor deliver output", destination: .settings, tab: .advanced),
        SearchHit(title: "History retention", subtitle: "Settings > Advanced", icon: "clock.badge.xmark",
                  keywords: "retention delete days save audio privacy history", destination: .settings, tab: .advanced),
        SearchHit(title: "Launch at login", subtitle: "Settings > General", icon: "power",
                  keywords: "launch login startup boot", destination: .settings, tab: .general),
        SearchHit(title: "Menu bar icon", subtitle: "Home > Quick controls", icon: "menubar.rectangle",
                  keywords: "menu bar icon capybara hide show", destination: .home),
        SearchHit(title: "Dock icon", subtitle: "Home > Quick controls", icon: "dock.rectangle",
                  keywords: "dock icon hide show", destination: .home),
        SearchHit(title: "Permissions", subtitle: "Home > Get set up", icon: "lock.shield",
                  keywords: "permissions microphone accessibility grant privacy", destination: .home),
        SearchHit(title: "Export / import preset", subtitle: "Settings > Advanced", icon: "square.and.arrow.up",
                  keywords: "export import preset backup share setup", destination: .settings, tab: .advanced),
        SearchHit(title: "Per-app modes", subtitle: "Settings > Advanced", icon: "app.badge",
                  keywords: "per app modes override automatic application", destination: .settings, tab: .advanced),
        SearchHit(title: "Support & tips", subtitle: "Tip jar window", icon: "heart",
                  keywords: "support tip jar donate heart restore purchases subscription", opensSupport: true),
    ]

    private var searchResults: [SearchHit] {
        let q = sidebarQuery.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return [] }
        let terms = q.split(separator: " ").map(String.init)
        return Self.searchIndex.filter { hit in
            let haystack = "\(hit.title) \(hit.subtitle) \(hit.keywords)".lowercased()
            return terms.allSatisfy { haystack.contains($0) }
        }
    }

    private func open(_ hit: SearchHit) {
        sidebarQuery = ""
        if hit.opensSupport {
            SupportWindowController.shared.show(state: state)
            return
        }
        if let tab = hit.tab { settingsTab = tab }
        if let dest = hit.destination { destination = dest }
    }

    private var sidebarFooter: some View {
        HStack(spacing: 10) {
            Spacer()
            Button { HelpWindowController.shared.show(state: state) } label: {
                HStack(spacing: 3) {
                    Image(systemName: "questionmark.circle").font(.system(size: 11))
                    Text("Help").font(.caption)
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Help")
            Link(destination: SupportLinks.repo) {
                Text("GitHub")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button { SupportWindowController.shared.show(state: state) } label: {
                HStack(spacing: 3) {
                    Image(systemName: "heart").font(.system(size: 11))
                    Text("Support").font(.caption)
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Support YapToText")
            Spacer()
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
    }

    // MARK: Detail (middle)

    @ViewBuilder
    private var detail: some View {
        switch destination {
        case .home:
            HomeView(onStartDictation: { state.controller.toggle() },
                     onNewMode: { newMode() })
        case .dictation:
            DictationPage()
        case .quickEdit:
            QuickEditPage()
        case .utility:
            UtilityView()
        case .models:
            ModelsSettingsView()
        case .modes:
            ModesView(path: $modePath)
        case .actions:
            ActionsView()
        case .dictionaries:
            VocabularySettingsView()
        case .commands:
            CommandsView()
        case .history:
            HistorySettingsView()
        case .stats:
            StatsView(standalone: true)
        case .settings:
            SettingsView(tab: $settingsTab)
        }
    }

    // MARK: Actions

    private func newMode() {
        let mode = Mode(name: "New Mode", iconSystemName: "wand.and.stars",
                        summary: "", usesAI: true, instructions: "", isBuiltIn: false)
        state.modeStore.addCustomMode(mode)
        destination = .modes
        modePath = [mode.id]
    }

}

/// Sidebar header showing live dictation state, a pause control, and a one-click record
/// toggle. This is the always-visible way to start and stop dictation from inside the app.
struct StatusStrip: View {
    let controller: DictationController
    @Environment(AppState.self) private var state

    /// The strip's icon MIRRORS the user's menu bar icon style in EVERY state - idle,
    /// recording (filled + record-red), and paused - so the app's corner and the menu bar
    /// always tell the same story with the same face.
    private var stripSymbol: String {
        let style = state.settings.menuBarIconStyle
        if controller.isPaused { return "pause.fill" }
        if controller.isRecording {
            switch style {
            case .capybara, .microphone: return "mic.fill"
            case .waveform: return "waveform"
            case .bubble: return "bubble.left.fill"
            case .dot: return "circle.fill"
            }
        }
        switch style {
        case .capybara, .microphone: return "mic"
        case .waveform: return "waveform"
        case .bubble: return "bubble.left"
        case .dot: return "circle.fill"
        }
    }

    var body: some View {
        let processing = controller.isBusy && !controller.isRecording
        HStack(spacing: 10) {
            // The icon is a status light: style-matched when idle, record-red while listening,
            // and a spinner while processing (the same story the menu bar icon tells). Stable
            // ZStack structure per the glass rules - pieces cross-fade, never swap.
            ZStack {
                if state.settings.menuBarIconStyle == .capybara, !controller.isPaused {
                    // Capybara in every state, like the menu bar: record-red while listening.
                    Image("CapyGlyph")
                        .renderingMode(.template).resizable().scaledToFit()
                        .padding(5)
                        .iconTint(controller.isRecording ? .yapRecord : .primary)
                        .frame(width: 28, height: 28)
                        .innerWell(radius: Metrics.badgeRadius)
                        .opacity(processing ? 0 : 1)
                        .accessibilityHidden(true)
                } else {
                    IconBadge(symbol: stripSymbol,
                              tint: controller.isRecording && !controller.isPaused ? .yapRecord : .primary,
                              size: 28)
                        .opacity(processing ? 0 : 1)
                }
                ProgressView().controlSize(.small)
                    .opacity(processing ? 1 : 0)
            }
            // Fixed-width text block: "Ready" -> "Listening…" -> "Transcribing…" must swap WITHOUT
            // changing this view's size (phase flips must never relayout the glass window).
            VStack(alignment: .leading, spacing: 1) {
                Text(controller.isPaused ? "Paused" : controller.statusText).font(.caption.weight(.medium)).lineLimit(1)
                Text(controller.activeMode.name).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
            // Circular transport controls - the same language as the panel and menu-bar popover.
            // Cancel LEADS the row (the discard escape hatch stays away from stop/insert).
            Button { controller.cancel() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Color.secondary.opacity(0.14)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .opacity(controller.isRecording ? 1 : 0)
            .allowsHitTesting(controller.isRecording)
            .help("Cancel and discard")
            .accessibilityLabel("Cancel dictation")
            .accessibilityHidden(!controller.isRecording)
            Button { controller.togglePause() } label: {
                Image(systemName: controller.isPaused ? "play.fill" : "pause.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Color.secondary.opacity(0.14)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .opacity(controller.isRecording ? 1 : 0)
            .allowsHitTesting(controller.isRecording)
            .help(controller.isPaused ? "Resume" : "Pause")
            .accessibilityLabel(controller.isPaused ? "Resume dictation" : "Pause dictation")
            .accessibilityHidden(!controller.isRecording)
            Button { controller.toggle() } label: {
                Image(systemName: "stop.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.red)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Color.secondary.opacity(0.14)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .opacity(controller.isRecording ? 1 : 0)
            .allowsHitTesting(controller.isRecording)
            .help("Stop dictation")
            .accessibilityLabel("Stop dictation")
            .accessibilityHidden(!controller.isRecording)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .overlay(Divider(), alignment: .bottom)
        .accessibilityElement(children: .contain)
        .accessibilityValue(controller.isPaused ? "Paused" : controller.statusText)
    }
}
