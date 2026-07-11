import SwiftUI
import AppKit

struct AboutView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        SettingsPage {
            hero
            story
            sourceAndSupport
            siblingApp
        }
        .navigationTitle("About")
    }

    // MARK: Hero

    private var hero: some View {
        VStack(spacing: 12) {
            AboutHero()
            VStack(spacing: 4) {
                Text("YapToText").font(.largeTitle)
                Text("Version \(version) (\(build))")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Text("A free, open-source accessibility tool that runs entirely on your Mac.")
                .font(.subheadline).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    // MARK: Why did I build this?

    private var story: some View {
        CardSection("Why did I build this?") {
            Text("I built YapToText as an accessibility tool, simply because I needed one. My hands don't work that well, which makes typing extremely difficult, so I'm dependent on dictation apps.")
                .fixedSize(horizontal: false, vertical: true)
            Text("The existing apps out there were either expensive, missing important features, or not really built for the people using them.")
                .fixedSize(horizontal: false, vertical: true)
            Text("So I made the dictation app of my dreams: free, fully on device, and endlessly customizable. I hope it's helpful for you too. If you run into any problems, or have suggestions, please let me know.")
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Ryleigh Newman").font(.callout.weight(.semibold))
                Link("ryleighnewman.com", destination: SupportLinks.personalSite)
                    .font(.caption)
            }
            .padding(.top, 4)
        }
    }

    // MARK: Open source & support (one row, two title-less glass boxes)

    private var sourceAndSupport: some View {
        // One fixed height for BOTH boxes, everything centered on the same vertical axis, and the
        // Donate button pinned to the right edge of its box - so neither box ever looks taller or
        // misaligned because of the button.
        let boxHeight: CGFloat = 76
        return HStack(spacing: Metrics.gap) {
            // Open source (left)
            Link(destination: SupportLinks.repo) {
                HStack(spacing: Space.m) {
                    Image(systemName: "chevron.left.forwardslash.chevron.right")
                        .iconTint(Color.accentColor)
                        .frame(width: 22)
                    Text("View the source code on GitHub")
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.up.forward").imageScale(.small).foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, Metrics.cardPad)
            .frame(maxWidth: .infinity)
            .frame(height: boxHeight)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: Metrics.sectionRadius, style: .continuous))

            // Support (right)
            HStack(spacing: Space.m) {
                Image(systemName: "heart.fill")
                    .iconTint(.pink)
                    .frame(width: 22)
                Text("Free forever. A tip is never expected, but would truly mean the world.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: Space.m)
                Button("Donate") {
                    NSApp.activate(ignoringOtherApps: true)
                    SupportWindowController.shared.show(state: state)
                }
                .buttonStyle(.solid)
                .controlSize(.small)
            }
            .padding(.horizontal, Metrics.cardPad)
            .frame(maxWidth: .infinity)
            .frame(height: boxHeight)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: Metrics.sectionRadius, style: .continuous))
        }
    }

    // MARK: Also by me

    private var siblingApp: some View {
        HStack(spacing: Space.m + 2) {
            Image("InputConfigIcon")
                .resizable().scaledToFit()
                .frame(width: 44, height: 44)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("InputConfig").font(.callout.weight(.semibold))
                Text("YapToText is built on the same foundation as InputConfig, my accessibility tool for input mapping.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Space.s)
            Link(destination: SupportLinks.inputConfigAppStore) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.up.forward.app")
                    Text("App Store")
                }
                .font(.callout)
            }
        }
        .padding(Metrics.cardPad)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: Metrics.sectionRadius, style: .continuous))
    }

    // MARK: Version helpers

    private var version: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0"
    }

    private var build: String {
        (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "1"
    }

    // MARK: Link row

    private func linkRow(_ icon: String, _ text: String, _ url: URL) -> some View {
        Link(destination: url) {
            HStack(spacing: Space.m) {
                Image(systemName: icon).frame(width: 22)
                    .iconTint(Color.accentColor)
                Text(text)
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.forward").imageScale(.small).foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The About hero: the capybara mark alive (its signature typing-dots + blink) over a soft accent
/// glow - no enclosing disc, just the mark itself.
private struct AboutHero: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { timeline in
            let t = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
            let glow = 0.5 + 0.5 * sin(t * 0.8)
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.14 + 0.10 * glow))
                    .frame(width: 116, height: 116)
                    .blur(radius: 28)
                AnimatedCapy(size: 84, tint: .accentColor)
            }
            .frame(width: 104, height: 104)
        }
    }
}
