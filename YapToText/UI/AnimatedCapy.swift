import SwiftUI
import AppKit

/// Hosts an animating subtree in its OWN NSHostingView so its per-frame invalidations
/// can never dirty the parent window's layout (the parent is a Liquid Glass window -
/// re-laying it per tick is exactly the cost this exists to avoid).
struct IsolatedAnimationHost<Content: View>: NSViewRepresentable {
    @ViewBuilder var content: () -> Content
    func makeNSView(context: Context) -> NSHostingView<Content> {
        let v = NSHostingView(rootView: content())
        v.sizingOptions = []   // parent pins the frame; no intrinsic-size feedback loop
        return v
    }
    func updateNSView(_ v: NSHostingView<Content>, context: Context) {
        v.rootView = content()
    }
}

/// The Home hero capybara, alive. Rendered in a single GPU `Canvas` (cheap per frame, so it stays
/// smooth) driven by one `TimelineView(.animation)`, and only while the Home view is on screen:
///  - the three speech-bubble dots bounce in sequence (a typing indicator), punched as real holes
///  - the eye blinks every few seconds
///  - EASTER EGG: every ~19s he sneezes - leans back, snaps forward with an "achoo", eyes scrunch
///    shut, and a little spray puffs from his snout.
struct AnimatedCapy: View {
    var size: CGFloat = 76
    var tint: Color = .primary
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var activeState

    // Positions measured from the 512x512 art (top-left origin, as fractions).
    private let dotFX: [CGFloat] = [0.750, 0.818, 0.887]
    private let dotFY: CGFloat = 0.252
    private let dotR: CGFloat = 0.019
    private let eyeFX: CGFloat = 0.414
    private let eyeFY: CGFloat = 0.398
    private let eyeR: CGFloat = 0.032
    private let snoutFX: CGFloat = 0.66
    private let snoutFY: CGFloat = 0.52

    var body: some View {
        // ISOLATED in its own nested NSHostingView: a TimelineView tick invalidates its
        // hosting view's layout, and when that hosting view is the whole glass window,
        // every tick re-ran the window's Liquid Glass layout (~20% CPU measured while
        // the Home screen was frontmost). Nested, a tick re-lays only this tiny canvas.
        // Also: 12fps (plenty for blinks and the dot bounce) and fully paused when the
        // window isn't key - decoration never costs anything in the background.
        IsolatedAnimationHost {
            TimelineView(.animation(minimumInterval: 1.0 / 12.0, paused: reduceMotion || activeState == .inactive)) { timeline in
                let t = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
                Canvas { ctx, sz in draw(ctx, sz, t: t) } symbols: {
                    Image("CapyNoDots").resizable().scaledToFit()
                        .foregroundStyle(tint).tag(0)
                }
                .frame(width: size, height: size)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private func draw(_ ctx: GraphicsContext, _ sz: CGSize, t: Double) {
        let W = sz.width, H = sz.height
        let s = sneeze(t)   // (progress -1..1, rot, scale, eyesShut, achoo)

        var ctx = ctx
        // Whole-body sneeze transform: pivot near the neck (bottom-center) so he nods.
        if s.active {
            ctx.translateBy(x: W * 0.5, y: H * 0.92)
            ctx.rotate(by: .radians(s.rot))
            ctx.scaleBy(x: s.scale, y: s.scale)
            ctx.translateBy(x: -W * 0.5, y: -H * 0.92)
        }

        // The capy (tinted template).
        if let sym = ctx.resolveSymbol(id: 0) {
            ctx.draw(sym, in: CGRect(origin: .zero, size: sz))

            // EAR WIGGLE: every so often the ears twitch. The art is one image, so each ear is
            // re-drawn rotated a few degrees inside a clip region whose lower edge sits in solid
            // fur - the seam is invisible there, only the silhouette moves. Erase the region
            // first so the original ear doesn't ghost behind the rotated one.
            let wig = earWiggle(t)
            if abs(wig) > 0.001 {
                // (region in art fractions, pivot at the ear's base)
                let ears: [(CGRect, CGPoint, Double)] = [
                    (CGRect(x: 0.17, y: 0.25, width: 0.17, height: 0.19), CGPoint(x: 0.265, y: 0.43), 1.0),
                    (CGRect(x: 0.36, y: 0.23, width: 0.11, height: 0.12), CGPoint(x: 0.415, y: 0.34), 0.7),
                ]
                for (fr, fp, amp) in ears {
                    var c = ctx
                    let region = CGRect(x: fr.minX * W, y: fr.minY * H, width: fr.width * W, height: fr.height * H)
                    c.clip(to: Path(region))
                    c.blendMode = .destinationOut
                    c.fill(Path(region), with: .color(.black))
                    c.blendMode = .normal
                    let px = fp.x * W, py = fp.y * H
                    c.translateBy(x: px, y: py)
                    c.rotate(by: .radians(wig * amp))
                    c.translateBy(x: -px, y: -py)
                    c.draw(sym, in: CGRect(origin: .zero, size: sz))
                }
            }
        }

        // Bubble dots, bouncing, erased as real holes.
        ctx.blendMode = .destinationOut
        for i in 0..<3 {
            let r = dotR * W
            let cx = dotFX[i] * W
            let cy = dotFY * H - dotBounce(t, i)
            ctx.fill(Path(ellipseIn: CGRect(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r)),
                     with: .color(.black))
        }
        ctx.blendMode = .normal

        // Eyelid: covers the eye hole to blink (and stays shut during the sneeze).
        let lid = max(blink(t), s.eyesShut)
        if lid > 0.01 {
            let rx = eyeR * W, ry = eyeR * H * lid
            let ex = eyeFX * W, ey = eyeFY * H
            ctx.fill(Path(ellipseIn: CGRect(x: ex - rx, y: ey - ry, width: 2 * rx, height: 2 * ry)),
                     with: .color(tint))
        }

        // Sneeze spray: a few droplets puffing from the snout at the "achoo".
        if s.achoo > 0 {
            let f = s.achoo   // 0..1
            let ox = snoutFX * W, oy = snoutFY * H
            let dirs: [(CGFloat, CGFloat)] = [(1.0, 0.2), (0.9, 0.6), (1.05, -0.15), (0.7, 0.85), (1.1, 0.4)]
            for (i, d) in dirs.enumerated() {
                let dist = f * W * (0.28 + 0.05 * CGFloat(i % 3))
                let px = ox + d.0 * dist
                let py = oy + d.1 * dist
                let pr = (dotR * W) * (0.9 - 0.5 * f)
                ctx.opacity = Double(max(0, 1 - f))
                ctx.fill(Path(ellipseIn: CGRect(x: px - pr, y: py - pr, width: 2 * pr, height: 2 * pr)),
                         with: .color(tint))
            }
            ctx.opacity = 1
        }
    }

    /// Each dot rises and falls, staggered, like a typing indicator.
    private func dotBounce(_ t: Double, _ i: Int) -> CGFloat {
        CGFloat(max(0, sin(t * 3.2 - Double(i) * 0.55))) * (dotR * size * 1.7)
    }

    /// An occasional ear twitch (about every 13s, offset from the blink and sneeze): a quick
    /// damped flutter - two fast oscillations that die out, like shaking off a fly.
    private func earWiggle(_ t: Double) -> Double {
        let period = 13.0, dur = 0.55
        let p = t.truncatingRemainder(dividingBy: period)
        guard p < dur else { return 0 }
        let x = p / dur   // 0..1 through the twitch
        return 0.10 * sin(x * 4 * .pi) * (1 - x) * (1 - x)
    }

    /// A quick eyelid close/open (0 -> 1 -> 0) about every 4.2 seconds.
    private func blink(_ t: Double) -> CGFloat {
        let p = t.truncatingRemainder(dividingBy: 4.2)
        guard p < 0.18 else { return 0 }
        return CGFloat(sin(p / 0.18 * .pi))
    }

    private struct Sneeze { var active: Bool; var rot: Double; var scale: CGFloat; var eyesShut: CGFloat; var achoo: CGFloat }

    /// A rare sneeze (about every 5 minutes): anticipation lean-back, then a sharp forward achoo.
    private func sneeze(_ t: Double) -> Sneeze {
        let period = 300.0, dur = 0.9
        let p = t.truncatingRemainder(dividingBy: period)
        let start = period - dur
        guard p >= start else { return Sneeze(active: false, rot: 0, scale: 1, eyesShut: 0, achoo: 0) }
        let x = (p - start) / dur   // 0..1 through the sneeze
        // Anticipation to ~0.45 (lean back, shrink, eyes closing), then snap forward at ~0.55.
        let rot: Double
        let scale: CGFloat
        if x < 0.45 {
            let a = x / 0.45
            rot = -0.14 * easeOut(a)
            scale = 1 - 0.05 * CGFloat(easeOut(a))
        } else {
            let a = (x - 0.45) / 0.55
            rot = -0.14 + 0.30 * easeOut(a) * (1 - a)      // snap forward then settle back toward 0
            scale = 0.95 + 0.16 * CGFloat(easeOut(a) * (1 - a))
        }
        let eyesShut = CGFloat(max(0, min(1, sin(x * .pi))))          // shut through the middle
        let achoo = CGFloat(x >= 0.45 && x < 0.85 ? sin((x - 0.45) / 0.4 * .pi) : 0)
        return Sneeze(active: true, rot: rot, scale: scale, eyesShut: eyesShut, achoo: achoo)
    }

    private func easeOut(_ x: Double) -> Double { 1 - pow(1 - max(0, min(1, x)), 3) }
}
