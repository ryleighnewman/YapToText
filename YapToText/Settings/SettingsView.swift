import SwiftUI

/// The Settings page, shown inside the main window (not a separate popup). Mirrors InputConfig:
/// a segmented Picker (not a TabView) over a switch of section views. Modes live in the sidebar,
/// History in a toolbar sheet, and Support in its own window, so this page is just preferences.
struct SettingsView: View {
    @Binding var tab: SettingsTab

    init(tab: Binding<SettingsTab> = .constant(.general)) { self._tab = tab }

    enum SettingsTab: String, CaseIterable, Identifiable {
        case general = "General"
        case advanced = "Advanced"
        case about = "About"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Modern capsule chips instead of the legacy segmented Picker.
            CapsuleSegments(options: SettingsTab.allCases.map { ($0, $0.rawValue) },
                            selection: $tab, font: .callout)
                .accessibilityLabel("Settings section")
                .padding(.top, 14)
                .padding(.bottom, 10)

            Group {
                switch tab {
                case .general: GeneralSettingsView()
                case .advanced: AdvancedSettingsView()
                case .about: AboutView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Settings")
    }
}
