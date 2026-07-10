import AppKit
import SwiftUI

/// A borderless, non-activating floating panel that shows live dictation state without
/// stealing focus from the app you're typing into. Position, size, and entrance animation
/// are driven by user settings.
@MainActor
final class RecordingPanel {
    private let panel: NSPanel
    /// TWO separate SwiftUI graphs stacked in one window (crash architecture, macOS 26.5):
    /// `chromeHosting` renders ONLY the Liquid Glass card chrome and never re-renders during
    /// dictation; `hosting` renders all the live content with zero glass in its hierarchy. The
    /// DesignLibrary glass renderer therefore never executes inside the high-frequency dictation
    /// transactions that were segfaulting it (spam-press and long-dictation crashes).
    private let chromeHosting: NSHostingView<PanelChrome>
    private let hosting: NSHostingView<RecordingPanelView>
    private let controller: DictationController
    private let settings: AppSettings
    /// Last card size pushed into the chrome graph; only a real change re-renders the chrome.
    private var chromeSize: CGSize = .zero

    /// One width for both panel forms; every element inside scales off it, so shrinking this makes
    /// the whole pop-up proportionally smaller.
    static let panelWidth: CGFloat = 336
    /// The window is a FIXED size (big enough for the expanded form). The big<->small change is then
    /// a pure SwiftUI animation of the glass card INSIDE it - the NSPanel frame never resizes, which
    /// on 26.5 would have to animate through NSAnimationContext and crash Liquid Glass. The card
    /// draws its own shadow (margin) so the fixed surround stays invisible.
    static let shadowMargin: CGFloat = 20
    static let cardMaxHeight: CGFloat = 140
    static var windowSize: NSSize { NSSize(width: panelWidth + 2 * shadowMargin, height: cardMaxHeight + 2 * shadowMargin) }

    init(controller: DictationController, settings: AppSettings) {
        self.controller = controller
        self.settings = settings
        chromeHosting = NSHostingView(rootView: PanelChrome(size: .zero,
                                                            alignment: settings.panelPosition == .bottomCenter ? .bottom : .top,
                                                            margin: Self.shadowMargin))
        hosting = NSHostingView(rootView: RecordingPanelView(controller: controller, settings: settings,
                                                             width: Self.panelWidth, margin: Self.shadowMargin))
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: Self.windowSize),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false   // the chrome graph draws the card's shadow
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]

        let container = NSView(frame: NSRect(origin: .zero, size: Self.windowSize))
        for view in [chromeHosting, hosting] as [NSView] {
            view.frame = container.bounds
            view.autoresizingMask = [.width, .height]
            container.addSubview(view)   // chrome first (below), content second (above)
        }
        panel.contentView = container

        // Keep the VISIBLE CARD on screen when the user drags the panel. The window is larger
        // than the card (invisible shadow margins), so without this the card could be pushed
        // past the screen edges or under the menu bar and become hard to grab back.
        NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification,
                                               object: panel, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.clampCardToScreen() }
        }

        // Content -> chrome size bridge: a plain callback (never SwiftUI state) so the graphs stay
        // independent. Fires on style toggles; ignored while the size is stable.
        hosting.rootView = RecordingPanelView(controller: controller, settings: settings,
                                              width: Self.panelWidth, margin: Self.shadowMargin,
                                              onCardSize: { [weak self] size in
            guard let self, size != self.chromeSize, size.width > 0, size.height > 0 else { return }
            self.chromeSize = size
            self.chromeHosting.rootView = PanelChrome(size: size,
                                                      alignment: self.settings.panelPosition == .bottomCenter ? .bottom : .top,
                                                      margin: Self.shadowMargin)
        })
    }

    // NOTE: panel show/hide sets alpha/origin DIRECTLY - no NSAnimationContext. On macOS 26.5,
    // animating the panel drives a SwiftUI render transaction that crashes inside Apple's Liquid
    // Glass framework (DesignLibrary) - confirmed by AddressSanitizer (100% system frames, no app
    // code, crash under NSAnimationContext.runAnimationGroup). A plain show/hide avoids that path.
    private var shownAt: Date = .distantPast
    /// Bumped by every show/hide so a deferred orderOut can tell whether it's stale (a new
    /// dictation re-showed the panel while the old hide was still waiting).
    private var visibilityGeneration = 0

    func show() {
        visibilityGeneration += 1
        shownAt = Date()
        // Re-align the chrome only if the position setting changed since the last show, so a
        // routine show never adds a glass render on top of the presentation transaction.
        let alignment: Alignment = settings.panelPosition == .bottomCenter ? .bottom : .top
        if chromeHosting.rootView.alignment != alignment {
            chromeHosting.rootView = PanelChrome(size: chromeSize, alignment: alignment, margin: Self.shadowMargin)
        }
        panel.setContentSize(Self.windowSize)
        panel.setFrameOrigin(positionOrigin())
        panel.alphaValue = 1
        panel.orderFrontRegardless()
    }

    func hide() {
        guard panel.isVisible else { return }
        // Never tear the window down INSIDE a SwiftUI render transaction, and never within the
        // panel's first moments on screen: a quick push-to-talk tap shows and hides the panel in
        // ~200ms, landing the orderOut while the INITIAL glass presentation/layout transaction is
        // still in flight - a confirmed DesignLibrary crash (segfault under NSWindow layoutIfNeeded
        // + NSAnimationContext). Enforce a short minimum on-screen time so that transaction always
        // settles first; a generation counter keeps a stale deferred hide from killing a NEW show.
        visibilityGeneration += 1
        let gen = visibilityGeneration
        let sinceShow = Date().timeIntervalSince(shownAt)
        let delay = max(0.05, 0.40 - sinceShow)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.visibilityGeneration == gen else { return }
            self.panel.orderOut(nil)
        }
    }

    /// The window is a FIXED size, so a big<->small toggle needs NO window change - the SwiftUI card
    /// springs between the two forms IN PLACE. Deliberately a no-op: it must not re-position, so the
    /// panel stays exactly where it is (including where you dragged it) instead of snapping back to
    /// the default spot when it changes size.
    func applySizeIfVisible() { }

    /// Clamp the window so the visible card (inset by the shadow margin) stays inside the
    /// screen's usable area - below the menu bar, above the Dock, never off the sides.
    private func clampCardToScreen() {
        guard panel.isVisible, let screen = panel.screen ?? NSScreen.main else { return }
        let vf = screen.visibleFrame
        var origin = panel.frame.origin
        let f = panel.frame
        let m = Self.shadowMargin
        let cardW = Self.panelWidth
        let cardH = chromeSize.height > 0 ? chromeSize.height : Self.cardMaxHeight
        let bottomAligned = settings.panelPosition == .bottomCenter

        // Horizontal: the card is centered in the window.
        let cardMinX = f.midX - cardW / 2
        if cardMinX < vf.minX { origin.x += vf.minX - cardMinX }
        if cardMinX + cardW > vf.maxX { origin.x -= (cardMinX + cardW) - vf.maxX }

        // Vertical: the card hugs the window's anchored edge, inset by the margin.
        let cardMinY = bottomAligned ? f.minY + m : f.maxY - m - cardH
        if cardMinY < vf.minY { origin.y += vf.minY - cardMinY }
        if cardMinY + cardH > vf.maxY { origin.y -= (cardMinY + cardH) - vf.maxY }

        if origin != panel.frame.origin { panel.setFrameOrigin(origin) }
    }

    /// Place the WINDOW so the CARD inside it (horizontally centered, top/bottom-aligned, inset by
    /// the shadow margin) lands at the intended screen spot.
    private func positionOrigin() -> NSPoint {
        guard let screen = NSScreen.main else { return .zero }
        let vf = screen.visibleFrame
        let w = Self.windowSize.width, h = Self.windowSize.height
        let m = Self.shadowMargin, cardW = Self.panelWidth
        switch settings.panelPosition {
        case .bottomCenter:
            // card centered horizontally, bottom-aligned; its bottom sits `m` above the window bottom.
            return NSPoint(x: vf.midX - w / 2, y: (vf.minY + 140) - m)
        case .topCenter:
            // card centered, top-aligned; its top sits `m` below the window top.
            return NSPoint(x: vf.midX - w / 2, y: (vf.maxY - 40) - h + m)
        case .nearMenuBar:
            let cardCenterX = vf.maxX - 20 - cardW / 2
            return NSPoint(x: cardCenterX - w / 2, y: (vf.maxY - 8) - h + m)
        }
    }
}
