import AppKit
import StoreKit
import SwiftUI

/// The one ask for a rating, App Store rules first:
///
/// - The stars are Apple's. Rate hands off to StoreKit's own review request, the sheet where
///   a tap on a star IS the rating, so nothing here imitates that control or asks for a
///   particular score. The system decides whether the sheet actually appears (three times a
///   year at most), which is why the pre-ask is a plain question and not the rating itself.
/// - No incentive, no gate. Not Now is a full-size button, the ask never blocks a dictation,
///   and nothing in the app changes with the answer.
/// - Only after real use: over a thousand words dictated across at least a week and twenty
///   dictations, never on the day the app was installed, never while a dictation is running.
/// - Once, unless it was Not Now: then not again for four months, and never more than three
///   times in the life of the install.
/// - App Store builds only. The GitHub build has no store to rate on.
@MainActor
enum RatingPrompt {
    static let appStoreID = "6786382289"
    static let writeReviewURL = URL(string: "macappstore://apps.apple.com/app/id6786382289?action=write-review")!

    private static let doneKey = "rating.done"            // rated, or the ask ran out
    private static let shownKey = "rating.shownCount"
    private static let lastKey = "rating.lastShownAt"
    private static let firstUseKey = "rating.firstUseAt"  // stamped on the first dictation seen here

    static let wordsNeeded = 1_000
    static let dictationsNeeded = 20
    static let daysNeeded = 7.0
    static let daysBetweenAsks = 120.0
    static let maxAsks = 3

    static var isAppStoreBuild: Bool {
        Bundle.main.appStoreReceiptURL?.lastPathComponent == "receipt"
    }

    private static var window: NSPanel?

    /// Called once per finished dictation. Cheap: three defaults reads before any counting.
    static func considerAfterDictation(history: HistoryStore, controller: DictationController, force: Bool = false) {
        let ud = UserDefaults.standard
        if ud.object(forKey: firstUseKey) == nil { ud.set(Date(), forKey: firstUseKey) }
        guard force || eligible(history: history, ud: ud) else { return }
        // A beat after the words land, so the ask never competes with the insert.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            guard force || (!controller.isRecording && !controller.isBusy) else { return }
            present()
        }
    }

    private static func eligible(history: HistoryStore, ud: UserDefaults) -> Bool {
        guard isAppStoreBuild, !ud.bool(forKey: doneKey), window == nil else { return false }
        guard ud.integer(forKey: shownKey) < maxAsks else { ud.set(true, forKey: doneKey); return false }
        if let last = ud.object(forKey: lastKey) as? Date,
           Date().timeIntervalSince(last) < daysBetweenAsks * 86_400 { return false }
        guard let first = ud.object(forKey: firstUseKey) as? Date,
              Date().timeIntervalSince(first) >= daysNeeded * 86_400 else { return false }
        guard history.records.count >= dictationsNeeded else { return false }
        return history.totalWords >= wordsNeeded
    }

    static func present() {
        guard window == nil else { return }
        let ud = UserDefaults.standard
        ud.set(ud.integer(forKey: shownKey) + 1, forKey: shownKey)
        ud.set(Date(), forKey: lastKey)
        yapdiag("rating: asking (shown \(ud.integer(forKey: shownKey)) of \(maxAsks))")

        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 220),
                            styleMask: [.titled, .fullSizeContentView, .closable],
                            backing: .buffered, defer: true)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.contentView = NSHostingView(rootView: RatingPromptView(
            onRated: { markDone() },
            onClose: { close() }))
        if let screen = NSScreen.main {
            let v = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: v.midX - 200, y: v.midY + 40))
        }
        window = panel
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    private static func markDone() {
        UserDefaults.standard.set(true, forKey: doneKey)
        yapdiag("rating: rate tapped, review request handed to StoreKit")
    }

    static func close() {
        window?.orderOut(nil)
        window = nil
    }
}

private struct RatingPromptView: View {
    var onRated: () -> Void
    var onClose: () -> Void
    @Environment(\.requestReview) private var requestReview
    @State private var thanked = false
    @State private var burst = false

    var body: some View {
        ZStack {
            if thanked { thanks.transition(.opacity.combined(with: .scale(scale: 0.96))) }
            else { ask.transition(.opacity) }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: thanked)
        .padding(22)
        .frame(width: 400)
        .focusEffectDisabled()   // no focus ring on whichever button the window lands on
    }

    private var ask: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                AnimatedCapy(size: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Enjoying YapToText?").font(.title3.weight(.bold))
                    Text("You've dictated over \(RatingPrompt.wordsNeeded.formatted()) words with it.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            Text("Would you be willing to give it a star rating? (It only takes a tap. It helps us so much.)")
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Not Now") { onClose() }
                    .buttonStyle(.solidSecondary)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Rate YapToText") { rate() }
                    .buttonStyle(.solid)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var thanks: some View {
        VStack(spacing: 10) {
            ZStack {
                ForEach(0..<8, id: \.self) { i in
                    Image(systemName: "star.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.yellow)
                        .offset(x: burst ? cos(Double(i) / 8 * 2 * .pi) * 54 : 0,
                                y: burst ? sin(Double(i) / 8 * 2 * .pi) * 54 : 0)
                        .opacity(burst ? 0 : 1)
                        .animation(.easeOut(duration: 0.9).delay(0.05 * Double(i % 3)), value: burst)
                }
                AnimatedCapy(size: 64)
                    .scaleEffect(burst ? 1 : 0.6)
                    .animation(.spring(response: 0.45, dampingFraction: 0.55), value: burst)
            }
            .frame(height: 84)
            Text("Thank you!").font(.title3.weight(.bold))
            Text("That means a lot to a one-person app.").font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .onAppear {
            burst = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { onClose() }
        }
    }

    private func rate() {
        onRated()
        // Apple's own sheet, stars included: a tap on one is the rating. It appears when
        // the system allows it; this view only ever asked the question.
        requestReview()
        thanked = true
    }
}
