import SwiftUI
import AppKit

@main
struct YapToTextApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appDelegate.state)
                .frame(minWidth: 820, minHeight: 660)
        }
        .defaultSize(width: 1080, height: 790)
        .commands { AppCommands(state: appDelegate.state) }

        // The menu bar item is a MANUAL NSStatusItem owned by AppDelegate, NOT a MenuBarExtra:
        // a MenuBarExtra label is a SwiftUI graph living inside the system's glass menu bar, and
        // its re-renders (recording blink at ~1.6Hz, processing spinner at ~14fps) ran macOS
        // 26.5's crash-prone DesignLibrary glass renderer on every frame of every dictation.
        // Setting an NSImage on an AppKit status button creates zero SwiftUI transactions.
    }
}

/// Renders the menu bar mark as a fixed-size NSImage. The capybara body is drawn in the menu bar's
/// own color; only the speech bubble reflects the live dictation stage:
///  - idle: the normal (adaptive) speech bubble
///  - recording: the bubble turns red and blinks (a recording light)
///  - processing (transcribing / AI cleanup): the bubble vanishes and a small loader spins by his head
///  - inserting: a green bubble; error: orange
/// Idle is a TEMPLATE image so it adapts to a light/dark menu bar; active stages are colored. All
/// motion is driven by low-rate timers on the controller (menuPulse / menuSpin) so the icon costs
/// almost nothing - a display-linked animation would re-set the status image every frame and peg CPU.
enum MenuBarIcon {
    // 18pt tall is the standard status-item glyph height - taller overflows the item and clips.
    // The square art has big transparent margins (content is ~94% wide x ~73% tall), so instead of
    // aspect-fitting the whole canvas (which made the visible mark tiny), `fitted` maps the art's
    // CONTENT box to fill this frame. The box is wider than tall to match the content's aspect,
    // which is still a normal menu-bar footprint.
    // INTEGRAL canvas only: a fractional image size (27.1x20.9) made AppKit place the whole
    // bitmap between pixels, resampling every edge - that read as a permanently blurry capy.
    private static let box = NSSize(width: 27, height: 23)
    // Where the visible content sits inside the square art canvas (fractions, top-down):
    // x 0.033-0.969, y 0.135-0.861 - measured from the 512 art.
    private static let contentW = 0.9355, contentH = 0.7266
    private static let contentCX = 0.5010, contentCY = 0.4980
    // Speech-bubble geometry measured from the 512x512 art (fractions), so the processing spinner
    // lands EXACTLY on the bubble.
    private static let bubbleFX = 0.8165   // centroid x, fraction from the left
    private static let bubbleFY = 0.2541   // centroid y, fraction from the top
    private static let bubbleFR = 0.1328   // radius, fraction of the width

    /// Diagnostics kill switch (debug builds, toggled via the yap.debug.freezeMenuIcon
    /// notification): when true the label always returns ONE cached static image, so the status
    /// item never re-renders. Used to bisect whether the menu-bar label's re-renders (pulse at
    /// ~1.6Hz while recording, spinner at ~14fps while processing, inside the system's glass menu
    /// bar) are what trips the macOS 26.5 DesignLibrary crash.
    nonisolated(unsafe) static var frozenForDiagnostics = false
    nonisolated(unsafe) private static var frozenImage: NSImage?

    // Eye geometry (fractions of the square art, top-down) - same measurements AnimatedCapy uses,
    // so the menu-bar blink matches the in-app capy's.
    private static let eyeFX = 0.414, eyeFY = 0.398, eyeFR = 0.032
    // Speech-bubble dots (same fractions AnimatedCapy bounces in the app).
    private static let dotFX: [Double] = [0.750, 0.818, 0.887]
    private static let dotFY = 0.252, dotFR = 0.019

    static func image(phase: DictationController.Phase, pulse: Double, spin: Double, lid: Double = 0,
                      clock: Double = 0, style: MenuBarIconStyle = .capybara, colored: Bool = true,
                      levels: [Float] = [], waveformTint: NSColor? = nil) -> NSImage {
        if frozenForDiagnostics {
            if let frozenImage { return frozenImage }
            let still = render(phase: .idle, pulse: 0, spin: 0, lid: 0, clock: 0)
            frozenImage = still
            return still
        }
        switch style {
        case .capybara:
            return render(phase: phase, pulse: pulse, spin: spin, lid: lid, clock: clock, colored: colored)
        case .microphone:
            return renderMicrophone(phase: phase, pulse: pulse, spin: spin, colored: colored)
        case .waveform:
            return renderWaveform(phase: phase, levels: levels, tint: colored ? waveformTint : nil)
        case .bubble:
            return renderSymbol(filled: "bubble.left.fill", outline: "bubble.left",
                                phase: phase, pulse: pulse, spin: spin, colored: colored)
        case .dot:
            return renderDot(phase: phase, pulse: pulse, spin: spin, colored: colored)
        }
    }

    /// Generic SF-Symbol style (speech bubble, and any future symbol icon): outline when idle,
    /// filled while recording, tinted by state when colored, spinner while processing.
    private static func renderSymbol(filled: String, outline: String,
                                     phase: DictationController.Phase, pulse: Double, spin: Double,
                                     colored: Bool) -> NSImage {
        let size = NSSize(width: 20, height: 18)
        let processing: Bool
        switch phase { case .transcribing, .transforming: processing = true; default: processing = false }
        let tint: NSColor? = colored ? bubbleTint(phase, pulse: pulse) : nil
        let symbolName = phase == .recording ? filled : outline
        let image = NSImage(size: size, flipped: false) { rect in
            let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
            if let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
                .withSymbolConfiguration(config) {
                let tinted = NSImage(size: symbol.size, flipped: false) { r in
                    symbol.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1)
                    (tint ?? .labelColor).set()
                    r.fill(using: .sourceAtop)
                    return true
                }
                let mr = NSRect(x: (rect.width - symbol.size.width) / 2,
                                y: (rect.height - symbol.size.height) / 2,
                                width: symbol.size.width, height: symbol.size.height)
                tinted.draw(in: mr, from: .zero, operation: .sourceOver, fraction: 1)
            }
            if processing {
                drawSpinner(in: NSRect(x: rect.width - 13, y: rect.height - 13, width: 16, height: 16), spin: spin)
            }
            return true
        }
        image.isTemplate = (tint == nil && !processing)
        image.accessibilityDescription = "YapToText"
        return image
    }

    /// The quietest possible presence: one small dot. Breathes with the recording pulse,
    /// tinted by state when colored, spinner while processing.
    private static func renderDot(phase: DictationController.Phase, pulse: Double, spin: Double,
                                  colored: Bool) -> NSImage {
        let size = NSSize(width: 16, height: 18)
        let processing: Bool
        switch phase { case .transcribing, .transforming: processing = true; default: processing = false }
        let tint: NSColor? = colored ? bubbleTint(phase, pulse: pulse) : nil
        let image = NSImage(size: size, flipped: false) { rect in
            let base: CGFloat = phase == .recording ? 7 + 2 * CGFloat(pulse) : 7
            let dot = NSRect(x: rect.midX - base / 2, y: rect.midY - base / 2, width: base, height: base)
            (tint ?? .labelColor).setFill()
            NSBezierPath(ovalIn: dot).fill()
            if processing {
                drawSpinner(in: NSRect(x: rect.width - 13, y: rect.height - 13, width: 16, height: 16), spin: spin)
            }
            return true
        }
        image.isTemplate = (tint == nil && !processing)
        image.accessibilityDescription = "YapToText"
        return image
    }

    /// Microphone style: the standard SF Symbols mic, tinted by dictation state (red while
    /// recording, green on insert, orange on error) and paired with the processing spinner.
    /// With colored status off, it stays a monochrome template in every state.
    private static func renderMicrophone(phase: DictationController.Phase, pulse: Double, spin: Double, colored: Bool) -> NSImage {
        let size = NSSize(width: 20, height: 18)
        let processing: Bool
        switch phase { case .transcribing, .transforming: processing = true; default: processing = false }
        let tint: NSColor? = colored ? bubbleTint(phase, pulse: pulse) : nil
        let symbolName = phase == .recording ? "mic.fill" : "mic"
        let image = NSImage(size: size, flipped: false) { rect in
            let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
            if let mic = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
                .withSymbolConfiguration(config) {
                let tinted = NSImage(size: mic.size, flipped: false) { r in
                    mic.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1)
                    (tint ?? .labelColor).set()
                    r.fill(using: .sourceAtop)
                    return true
                }
                let mr = NSRect(x: (rect.width - mic.size.width) / 2,
                                y: (rect.height - mic.size.height) / 2,
                                width: mic.size.width, height: mic.size.height)
                tinted.draw(in: mr, from: .zero, operation: .sourceOver, fraction: 1)
            }
            if processing {
                // the same clock-spoke spinner, shrunk to sit over the mic's top-right corner
                drawSpinner(in: NSRect(x: rect.width - 13, y: rect.height - 13, width: 16, height: 16), spin: spin)
            }
            return true
        }
        // Template whenever nothing needs color: adapts to menu bar appearance.
        image.isTemplate = (tint == nil && !processing)
        image.accessibilityDescription = "YapToText"
        return image
    }

    /// Mini waveform style: a small bar visualizer drawn from the live mic levels. Monochrome
    /// template by default; with a `tint` (the user's visualizer color, gated by the colored
    /// toggle) the bars render in that color instead. Idle renders a quiet flat baseline.
    private static func renderWaveform(phase: DictationController.Phase, levels: [Float], tint: NSColor? = nil) -> NSImage {
        let size = NSSize(width: 26, height: 18)
        let bars = 9
        let image = NSImage(size: size, flipped: false) { rect in
            (tint ?? .labelColor).set()
            let gap: CGFloat = 1.2
            let barW = (rect.width - gap * CGFloat(bars - 1)) / CGFloat(bars)
            let midY = rect.midY
            // newest levels on the right. IDLE gets a designed resting wave - a soft
            // symmetric swell (like a paused visualizer) instead of the flat dotted line
            // that read as "broken". Any real signal replaces it instantly.
            let idleShape: [Float] = [0.12, 0.30, 0.18, 0.55, 0.34, 0.55, 0.18, 0.30, 0.12]
            let recent: [Float] = {
                // The designed resting wave is the icon's HOME: anything but an active
                // recording shows it. Gating on leftover level data instead kept stale
                // post-session dribble on screen as a near-flat line ("completely flat",
                // "should return to its original design").
                guard case .recording = phase else { return idleShape }
                let tail = levels.suffix(bars)
                let padded = Array(repeating: Float(0), count: max(0, bars - tail.count)) + tail
                let live = padded.contains { $0 > 0.03 }
                return live ? padded : idleShape
            }()
            for i in 0..<bars {
                // Perceptual lift: mic levels sit mostly in 0.1-0.4, which drew timid
                // stubs. The power curve expands exactly that range so normal speech
                // visibly dances while the ceiling still caps at the icon height.
                let raw = min(max(recent[i], 0), 1)
                let level = CGFloat(min(1, pow(raw, 0.6) * 1.15))
                let h = max(1.6, level * (rect.height - 2))
                let x = CGFloat(i) * (barW + gap)
                let bar = NSRect(x: x, y: midY - h / 2, width: barW, height: h)
                NSBezierPath(roundedRect: bar, xRadius: barW / 2, yRadius: barW / 2).fill()
            }
            return true
        }
        image.isTemplate = (tint == nil)   // monochrome unless the user picked a visualizer color
        image.accessibilityDescription = "YapToText"
        return image
    }

    private static func render(phase: DictationController.Phase, pulse: Double, spin: Double, lid: Double, clock: Double, colored: Bool = true) -> NSImage {
        let processing: Bool
        switch phase { case .transcribing, .transforming: processing = true; default: processing = false }
        // colored=false (the "no color changes" setting): every state renders as the adaptive
        // monochrome template - the bubble never tints, matching the idle look.
        let tint = colored ? bubbleTint(phase, pulse: pulse) : nil   // nil = adaptive template
        let image = NSImage(size: box, flipped: false) { rect in
            let dst = fitted(rect)   // where the square art is drawn
            drawLayer("CapyBody", in: dst, color: .labelColor)
            // Blink: the eye is a transparent hole in the art; the eyelid is a body-colored
            // ellipse that squashes shut over it (lid 0 = open, 1 = shut).
            if lid > 0.01 {
                let rx = eyeFR * dst.width, ry = rx * lid
                let ex = dst.minX + eyeFX * dst.width
                let ey = dst.minY + (1 - eyeFY) * dst.height
                NSColor.labelColor.setFill()
                NSBezierPath(ovalIn: NSRect(x: ex - rx, y: ey - ry, width: 2 * rx, height: 2 * ry)).fill()
            }
            if processing {
                drawSpinner(in: dst, spin: spin)   // bubble becomes a spinner, right where it sat
            } else {
                let bubbleColor = tint ?? .labelColor
                drawLayer("CapyBubble", in: dst, color: bubbleColor)
                // While recording, the bubble's dots bounce like the in-app typing indicator:
                // cover the static dot holes with the bubble color, then punch new holes at the
                // bounced positions (destinationOut cuts real transparency).
                if phase == .recording {
                    let r = dotFR * dst.width
                    bubbleColor.setFill()
                    for fx in dotFX {
                        let cx = dst.minX + fx * dst.width
                        let cy = dst.minY + (1 - dotFY) * dst.height
                        NSBezierPath(ovalIn: NSRect(x: cx - r * 1.3, y: cy - r * 1.3, width: r * 2.6, height: r * 2.6)).fill()
                    }
                    NSGraphicsContext.current?.compositingOperation = .destinationOut
                    NSColor.black.setFill()
                    for (i, fx) in dotFX.enumerated() {
                        let bounce = max(0, sin(clock * 3.2 - Double(i) * 0.55)) * r * 1.7
                        let cx = dst.minX + fx * dst.width
                        let cy = dst.minY + (1 - dotFY) * dst.height + bounce
                        NSBezierPath(ovalIn: NSRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2)).fill()
                    }
                    NSGraphicsContext.current?.compositingOperation = .sourceOver
                }
            }
            return true
        }
        image.isTemplate = (phase == .idle) || (!colored && !processing)
        image.accessibilityDescription = "YapToText"
        return image
    }

    /// The square art canvas positioned so its CONTENT box fills `rect` - one shared frame so the
    /// layers and the spinner all use the same coordinate mapping. The canvas extends past `rect`
    /// on all sides; only transparent margin gets cropped.
    private static func fitted(_ rect: NSRect) -> NSRect {
        // Art size is pinned to a 21pt reference, NOT the canvas height: the canvas is taller
        // (23pt) purely as headroom so the raised mark can't crop against its own image edge.
        let side = min(rect.width / contentW, 21.0 / contentH)
        // Content center in bottom-up canvas coordinates is (contentCX, 1 - contentCY).
        // Snap to the retina pixel grid (0.5pt) - fractional offsets resample every edge and
        // made the whole mark blurry.
        func snap(_ v: CGFloat) -> CGFloat { (v * 2).rounded() / 2 }
        // Optical balance: the art is bottom-heavy (the capy body), so it sits centered with
        // a 1pt UPWARD bias - centered still read low against the bottom-heavy art.
        return NSRect(x: snap(rect.midX - side * contentCX),
                      y: snap(rect.midY - side * (1 - contentCY) + 1.0),
                      width: snap(side), height: snap(side))
    }

    /// Draw a glyph layer into `dst`, tinted `color`. The tint is baked in an ISOLATED image so its
    /// fill can't recolor other layers already on the canvas (that made the whole capy go red).
    private static func drawLayer(_ name: String, in dst: NSRect, color: NSColor) {
        guard let glyph = NSImage(named: name) else { return }
        let tinted = NSImage(size: glyph.size, flipped: false) { r in
            glyph.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1)
            color.set()
            r.fill(using: .sourceAtop)
            return true
        }
        tinted.isTemplate = false
        tinted.draw(in: dst, from: .zero, operation: .sourceOver, fraction: 1)
    }

    /// An activity spinner centered exactly on the speech bubble: eight clock-position spokes,
    /// each fading behind the one leading the rotation (not a cohesive arc). Drawn in the
    /// label color of the menu bar it sits in, so it is white over a dark bar and black
    /// over a light one - it used to be hard-coded white and vanished on light wallpapers.
    private static func drawSpinner(in dst: NSRect, spin: Double) {
        let cx = dst.minX + bubbleFX * dst.width
        let cy = dst.minY + (1 - bubbleFY) * dst.height   // art measured top-down; canvas is bottom-up
        let rOuter = bubbleFR * dst.width
        let rInner = rOuter * 0.42
        let count = 8
        var head = spin.truncatingRemainder(dividingBy: 1.0)
        if head < 0 { head += 1 }
        for i in 0..<count {
            let frac = Double(i) / Double(count)
            var age = (head - frac).truncatingRemainder(dividingBy: 1.0)
            if age < 0 { age += 1 }
            let opacity = 0.12 + 0.88 * (1.0 - age)
            // Start at 12 o'clock and go CLOCKWISE. The canvas is y-UP, so an angle that
            // merely increases sweeps counter-clockwise - the spinner ran backwards, and
            // began at 6 o'clock rather than 12 (frac 0 mapped to (0,-1)). Measuring the
            // angle DOWN from +y fixes both: frac 0 -> 12 o'clock, frac 0.25 -> 3 o'clock.
            let angle = .pi / 2 - frac * 2 * .pi
            let ci = cos(angle), si = sin(angle)
            let path = NSBezierPath()
            path.move(to: NSPoint(x: cx + ci * rInner, y: cy + si * rInner))
            path.line(to: NSPoint(x: cx + ci * rOuter, y: cy + si * rOuter))
            path.lineWidth = max(0.9, rOuter * 0.34)
            path.lineCapStyle = .round
            NSColor.labelColor.withAlphaComponent(opacity).setStroke()
            path.stroke()
        }
    }

    private static func bubbleTint(_ phase: DictationController.Phase, pulse: Double) -> NSColor? {
        switch phase {
        case .idle: return nil
        case .recording:
            // Blink bright red <-> dark red (a recording light), fully opaque so it reads clearly.
            // Continuous breathing gradient between bright and deep red (pulse 0..1), not a flash.
            return NSColor.systemRed.blended(withFraction: 0.55 * (1 - pulse), of: .black) ?? .systemRed
        case .inserting: return .systemGreen
        case .error: return .systemOrange
        case .transcribing, .transforming: return nil   // unused: the spinner is drawn instead
        }
    }
}
