import SwiftUI

/// YapToText's shared visual language, aligned with the family look of CubeAura and
/// InputConfig: real Liquid Glass cards, uppercase tracked micro-labels, gradient icon tints
/// instead of solid colors, and one spacing scale for everything.
///
/// Policy on glass: cards, panels, and prominent buttons use Apple's real `.glassEffect(.regular)`
/// - that is the app's surface language. Insets inside a card stay flat (see `innerWell`) so glass
/// never stacks on glass and muddies. The one wrinkle is the macOS 26.5 DesignLibrary render crash:
/// the floating HUD/QuickPanel keep their glass but use tap-gesture pseudo-buttons and deferred
/// teardown to dodge it (marked at those call sites). Revisit those workarounds when Apple ships
/// the fix; the glass itself stays.
enum Space {
    static let xs: CGFloat = 4
    static let s: CGFloat = 6
    static let m: CGFloat = 10
    static let l: CGFloat = 14
}

enum Metrics {
    static let cardRadius: CGFloat = 18
    static let sectionRadius: CGFloat = 18
    /// Floating panels (HUD, menu-bar popovers) sit one notch tighter than in-page cards.
    static let panelRadius: CGFloat = 14
    static let innerRadius: CGFloat = 10
    static let badgeRadius: CGFloat = 9
    static let cardPad: CGFloat = 14
    static let gap: CGFloat = 14
    /// Cap for page content so cards stay readable instead of stretching across wide windows.
    static let pageWidth: CGFloat = 680
}

/// The brand gradient - used for icon tints, accents, and highlights so nothing sits as a
/// single solid color.
extension LinearGradient {
    static let yapAccent = LinearGradient(colors: [.accentColor, .cyan],
                                          startPoint: .topLeading, endPoint: .bottomTrailing)
    static let yapAccentWide = LinearGradient(colors: [.accentColor, .cyan, .mint],
                                              startPoint: .leading, endPoint: .trailing)
}

/// The app window's frosted backdrop: the behind-window blur plus a whisper of darkening so
/// content keeps contrast on bright wallpapers (the raw blur washed out on light desktops).
struct AppWindowBackground: View {
    var body: some View {
        VisualEffectBackground()
            .overlay(Color.black.opacity(0.07))
            .ignoresSafeArea()
    }
}

extension View {
    /// THE colored-icon treatment. A tinted SF Symbol is NEVER a flat 100% solid block of color:
    /// every colored icon carries a little transparency so it reads as a layered, glassy mark. This
    /// is an app-wide rule (and a shared one across Aura / InputConfig / YapToText); it pairs with
    /// the global `.symbolRenderingMode(.hierarchical)`. Transparency only - never a gradient. Use
    /// this in place of `.foregroundStyle(color)` on any colored icon.
    func iconTint(_ color: Color, opacity: Double = 0.85) -> some View {
        foregroundStyle(color.opacity(opacity))
    }
}

/// A tinted SF Symbol on a glass squircle - translucent layered ink, never a solid block of color.
struct IconBadge: View {
    let symbol: String
    var tint: Color = .accentColor
    var size: CGFloat = 32

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.46, weight: .semibold))
            .iconTint(tint)
            .frame(width: size, height: size)
            .innerWell(radius: Metrics.badgeRadius)
            .accessibilityHidden(true)
    }
}

/// The workhorse container: a floating Liquid Glass card with an uppercase tracked
/// micro-label header (the CubeAura card language).
struct CardSection<Content: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var content: () -> Content

    init(_ title: String, subtitle: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .accessibilityAddTraits(.isHeader)
                if let subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Metrics.cardPad)
        // Real Liquid Glass on every card (was the subtle hand-built surface) so the whole app
        // carries the same glass as the pop-up.
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: Metrics.sectionRadius, style: .continuous))
    }
}

/// Indented sub-options that hang off a parent control, with a soft gradient guide line.
struct SubOptions<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        HStack(alignment: .top, spacing: Space.m) {
            RoundedRectangle(cornerRadius: 1)
                .fill(LinearGradient(colors: [Color.accentColor.opacity(0.35), .clear],
                                     startPoint: .top, endPoint: .bottom))
                .frame(width: 2)
                .padding(.vertical, 2)
            VStack(alignment: .leading, spacing: Space.s + 2) { content() }
        }
        .padding(.leading, Space.m)
    }
}

/// The settings-page scaffold: glass cards on the window's own glass, capped to a readable
/// width and centered.
struct SettingsPage<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.gap) { content() }
                .padding(20)
                .frame(maxWidth: Metrics.pageWidth, alignment: .leading)
                .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.never)
    }
}

extension View {
    /// THE single flat inner-surface style, for anything that must NOT be its own glass slab: inset
    /// elements (icon badges, text wells, fields, tiles) and also the sub-card rows that sit inside a
    /// page of glass cards. A subtle recess, NOT glass: glass-inside-a-glass-card double-frosts and
    /// reads darker, making cards with wells look inconsistent with cards without. The card is the
    /// glass; everything nested into it is a quiet recess, so every box reads the same. Pass the card
    /// radius (Metrics.sectionRadius) for a full-size row, or an inner radius for a small well.
    func innerWell(radius: CGFloat = 8) -> some View {
        self
            .background(Color.secondary.opacity(0.06),
                        in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
                .stroke(Color.secondary.opacity(0.12), lineWidth: 0.5))
    }

    /// Rounded well for TextEditors so they sit inside cards, in the shared surface style.
    func editorBox(minHeight: CGFloat) -> some View {
        self
            .scrollContentBackground(.hidden)
            .padding(6)
            .frame(minHeight: minHeight)
            .innerWell(radius: Metrics.innerRadius)
    }
}

/// The standard explanatory caption placed under a control.
struct Caption: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Uppercase tracked status pill (the CubeAura badge) - color + word, no icons.
struct StatusPill: View {
    let text: String
    var tint: Color = .accentColor
    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(tint.opacity(0.18), in: Capsule())
            .foregroundStyle(tint)
    }
}

/// A glance stat: small tertiary label under a monospaced semibold value (CubeAura's
/// StatPill), used for the Home dictation stats.
struct StatPill: View {
    let value: String
    let label: String
    init(_ value: String, _ label: String) {
        self.value = value
        self.label = label
    }
    var body: some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.title3.weight(.semibold).monospacedDigit())
                .contentTransition(.numericText())   // roll the digits up when a stat changes
                .animation(.snappy(duration: 0.5), value: value)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

/// A titled row with a leading badge and trailing accessory.
struct BadgeRow<Trailing: View>: View {
    let symbol: String
    var tint: Color = .accentColor
    let title: String
    var subtitle: String?
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: Space.m + 2) {
            IconBadge(symbol: symbol, tint: tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.medium)
                if let subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: Space.s)
            trailing()
        }
        .accessibilityElement(children: .combine)
    }
}

/// Hover-lift feature tile on glass: gradient icon, soft glass fill that brightens, gentle
/// scale on hover (respecting Reduce Motion).
struct FeatureCardButton: View {
    let icon: String
    let title: String
    let detail: String
    var tint: Color = .accentColor
    let action: () -> Void

    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: Space.m) {
                Image(systemName: icon)
                    .font(.system(size: 18))
                    .foregroundStyle(hovering ? AnyShapeStyle(Color.accentColor)
                                              : AnyShapeStyle(Color.secondary.opacity(0.6)))
                    .frame(width: 24, height: 24)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 110, alignment: .topLeading)
            .innerWell(radius: Metrics.innerRadius + 2)
            .overlay(RoundedRectangle(cornerRadius: Metrics.innerRadius + 2, style: .continuous)
                .stroke(hovering ? Color.accentColor.opacity(0.5) : .clear, lineWidth: 1))
            .scaleEffect(hovering && !reduceMotion ? 1.02 : 1.0)
            .animation(.easeOut(duration: 0.12), value: hovering)
            .contentShape(RoundedRectangle(cornerRadius: Metrics.innerRadius + 2))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { hovering = $0 }
        .help(detail)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityHint(detail)
    }
}

/// Tip / callout row with a gradient-tinted leading icon.
struct TipRow: View {
    var icon: String = "lightbulb.fill"
    var tint: Color = .accentColor
    let title: String
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: Space.m) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .frame(width: 22, alignment: .center)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption.weight(.semibold))
                Text(message).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// The modern replacement for the legacy segmented Picker: a row of capsule chips in the same
/// language as the dictation panel's mode chips - the selected chip gets the accent-tinted capsule
/// and stroke, the rest stay quiet neutral capsules. Use for tab rows and filter bars.
struct CapsuleSegments<Value: Hashable>: View {
    var options: [(value: Value, label: String)]
    @Binding var selection: Value
    var font: Font = .caption

    var body: some View {
        HStack(spacing: 5) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                let isCurrent = option.value == selection
                Button { selection = option.value } label: {
                    Text(option.label)
                        .font(font.weight(isCurrent ? .semibold : .regular))
                        .foregroundStyle(isCurrent ? .primary : .secondary)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(isCurrent ? Color.accentColor.opacity(0.16) : Color.secondary.opacity(0.06),
                                    in: Capsule())
                        .overlay(Capsule().stroke(isCurrent ? Color.accentColor.opacity(0.5) : Color.secondary.opacity(0.12),
                                                  lineWidth: 0.5))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isCurrent ? [.isSelected] : [])
            }
        }
        .accessibilityElement(children: .contain)
    }
}

/// A single on/off filter chip in the same capsule language (e.g. "AI only").
struct CapsuleToggleChip: View {
    let label: String
    @Binding var isOn: Bool
    var font: Font = .caption

    var body: some View {
        Button { isOn.toggle() } label: {
            Text(label)
                .font(font.weight(isOn ? .semibold : .regular))
                .foregroundStyle(isOn ? .primary : .secondary)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(isOn ? Color.accentColor.opacity(0.16) : Color.secondary.opacity(0.06), in: Capsule())
                .overlay(Capsule().stroke(isOn ? Color.accentColor.opacity(0.5) : Color.secondary.opacity(0.12),
                                          lineWidth: 0.5))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
    }
}

/// One flat button look across the whole app: a SOLID fill, no gradient and no glass sheen.
/// Prominent = solid accent (blue) with white text; secondary = a subtle neutral fill.
struct SolidButton: ButtonStyle {
    var tint: Color = .accentColor
    var prominent: Bool = true
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.medium))
            // Secondary buttons with a non-default tint (e.g. .red for destructive) carry the
            // tint in the LABEL on the neutral capsule, matching Apple's destructive-text idiom.
            .foregroundStyle(prominent ? AnyShapeStyle(.white)
                             : (tint == .accentColor ? AnyShapeStyle(.primary) : AnyShapeStyle(tint)))
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(prominent ? AnyShapeStyle(tint) : AnyShapeStyle(Color.secondary.opacity(0.16)),
                        in: Capsule())
            .contentShape(Capsule())
            .opacity(isEnabled ? (configuration.isPressed ? 0.72 : 1.0) : 0.4)
    }
}

extension ButtonStyle where Self == SolidButton {
    static var solid: SolidButton { SolidButton(prominent: true) }
    static var solidSecondary: SolidButton { SolidButton(prominent: false) }
}

extension Color {
    /// A calm, muted red for the recording state - not the harsh bright system red.
    static let yapRecord = Color(red: 0.80, green: 0.31, blue: 0.33)
}
