import SwiftUI

/// The Energy page: this Mac's hardware story, the live power state, and the adaptive
/// model system - heavy model on mains, light model on battery, per-mode overrides in
/// each mode's own editor.
struct EnergySettingsView: View {
    @Environment(AppState.self) private var state
    private let hardware = HardwareProfile.current

    var body: some View {
        @Bindable var settings = state.settings
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.gap) {
                CardSection("This Mac", subtitle: hardware.summaryLine) {
                    HStack(spacing: 10) {
                        Image(systemName: PowerMonitor.shared.onACPower ? "powerplug.fill" : "battery.75percent")
                            .foregroundStyle(PowerMonitor.shared.onACPower ? Color.green : Color.orange)
                        Text(powerLine)
                        Spacer()
                    }
                    .padding(10)
                    .innerWell(radius: Metrics.innerRadius)
                    Caption(hardware.recommendationExplanation)
                }

                CardSection("Adaptive models",
                            subtitle: "Follow the power source: full quality plugged in, lighter on battery") {
                    Toggle("Switch speech models with the power source", isOn: $settings.energyAdaptive)
                        .toggleStyle(.switch)
                    if settings.energyAdaptive {
                        modelPicker("Plugged in", selection: $settings.speechModelPluggedID)
                        modelPicker("On battery", selection: $settings.speechModelBatteryID)
                        Button("Use the recommendation for this Mac") {
                            let rec = hardware.recommendedSpeechModels
                            settings.speechModelPluggedID = rec.plugged
                            settings.speechModelBatteryID = rec.battery
                        }
                        .controlSize(.small)
                        Caption("Each mode can also carry its own on-battery model in its editor - a mode's choice wins over these defaults.")
                    }
                }
            }
            .padding(20)
        }
        .navigationTitle("Energy")
    }

    private var powerLine: String {
        var line = PowerMonitor.shared.onACPower ? "Plugged in" : "On battery"
        if let percent = PowerMonitor.shared.batteryPercent { line += " \u{00B7} \(percent)%" }
        return line
    }

    private func modelPicker(_ label: String, selection: Binding<String?>) -> some View {
        Picker(label, selection: selection) {
            Text("Use the main selection").tag(String?.none)
            Text("Apple Speech (lightest)").tag(String?.some("apple"))
            ForEach(state.models.speechModels.filter { $0.runtime != .apple }) { model in
                Text(model.displayName).tag(String?.some(model.id))
            }
        }
    }
}
