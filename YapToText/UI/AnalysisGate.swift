import SwiftUI

/// Grays out a mode/AI control when post-transcription analysis is OFF, and - crucially -
/// still catches taps on the grayed control so it can explain WHY it's disabled instead of
/// doing nothing. A plain `.disabled()` swallows the tap silently; the transparent overlay
/// here sits on top of the disabled control and routes the click to the central explainer
/// prompt (AppState.requestAnalysisControl -> the alert in ContentView), which offers to turn
/// analysis back on or open the setting. When analysis is on, this is a transparent pass-through.
struct AnalysisGate: ViewModifier {
    let state: AppState

    func body(content: Content) -> some View {
        let on = state.settings.aiCleanupEnabled
        content
            .disabled(!on)
            .opacity(on ? 1 : 0.4)
            .overlay {
                if !on {
                    Rectangle()
                        .fill(.clear)
                        .contentShape(Rectangle())
                        .onTapGesture { state.requestAnalysisControl() }
                        .accessibilityLabel("Disabled - post-transcription analysis is off. Activate to turn it on.")
                        .accessibilityAddTraits(.isButton)
                }
            }
    }
}

extension View {
    /// Disable + gray this mode/AI control when post-transcription analysis is off, routing a
    /// tap to the explainer prompt. No-op (normal) when analysis is on.
    func analysisGated(_ state: AppState) -> some View {
        modifier(AnalysisGate(state: state))
    }
}
