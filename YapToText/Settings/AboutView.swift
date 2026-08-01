import SwiftUI
import AppKit

struct AboutView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        SettingsPage {
            hero
            changelogRow
            story
            sourceAndSupport
            communityRow
            diagnosticsRow
            siblingApp
        }
        .navigationTitle("About")
    }

    // MARK: Changelog

    @State private var showChangelog = false
    private var changelogRow: some View {
        Button { showChangelog = true } label: {
            HStack(spacing: Space.m) {
                Image(systemName: "sparkles").iconTint(Color.accentColor).frame(width: 22)
                Text("View Changelog")
                    .font(.callout)
                Spacer(minLength: 0)
                Text(Changelog.currentVersion)
                    .font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                Image(systemName: "chevron.right").imageScale(.small).foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(Metrics.cardPad)
        .yapGlass(in: RoundedRectangle(cornerRadius: Metrics.sectionRadius, style: .continuous))
        .popover(isPresented: $showChangelog, arrowEdge: .bottom) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("What's new").font(.headline)
                    ForEach(Changelog.entries) { entry in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(entry.version).font(.subheadline.weight(.semibold))
                            ForEach(entry.points, id: \.self) { point in
                                HStack(alignment: .firstTextBaseline, spacing: 6) {
                                    Text("\u{2022}").foregroundStyle(.secondary)
                                    Text(point).font(.callout)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                }
                .padding(16)
                .frame(width: 380, alignment: .leading)
            }
            .frame(maxHeight: 460)
        }
        .accessibilityLabel("View changelog, current version \(Changelog.currentVersion)")
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

    private var communityRow: some View {
        HStack(spacing: Space.m) {
            Image(systemName: "person.2.fill").iconTint(.orange).frame(width: 22)
            Text("To everyone who suggested features, tested rough builds, and told me exactly where it hurt: this app is shaped by you. Without this community, YapToText wouldn't exist. Thank you.")
                .font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(Metrics.cardPad)
        .yapGlass(in: RoundedRectangle(cornerRadius: Metrics.sectionRadius, style: .continuous))
    }

    @State private var diagnosticsCopied = false
    private var diagnosticsRow: some View {
        HStack(spacing: Space.m) {
            Image(systemName: "stethoscope").iconTint(Color.accentColor).frame(width: 22)
            Text("Something misbehaving? Copy a diagnostics report (Mac model, versions, model setup, latency stats - no transcript text) and paste it into a GitHub issue.")
                .font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Space.m)
            Button(diagnosticsCopied ? "Copied!" : "Copy Diagnostics") {
                Diagnostics.copyToClipboard(state: state)
                diagnosticsCopied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { diagnosticsCopied = false }
            }
            .buttonStyle(.solidSecondary).controlSize(.small)
        }
        .padding(Metrics.cardPad)
        .yapGlass(in: RoundedRectangle(cornerRadius: Metrics.sectionRadius, style: .continuous))
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
            .yapGlass(in: RoundedRectangle(cornerRadius: Metrics.sectionRadius, style: .continuous))

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
            .yapGlass(in: RoundedRectangle(cornerRadius: Metrics.sectionRadius, style: .continuous))
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
        .yapGlass(in: RoundedRectangle(cornerRadius: Metrics.sectionRadius, style: .continuous))
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
    @Environment(\.controlActiveState) private var activeState
    var body: some View {
        // 15fps is plenty for a ~7.85s glow pulse feeding a blur recomposite; the full display rate
        // was pure waste while the About pane is open.
        TimelineView(.animation(minimumInterval: 1.0 / 10.0, paused: reduceMotion || activeState == .inactive)) { timeline in
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
