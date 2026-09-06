import SwiftUI

/// The Energy page: this Mac's specifications, the live power state, and the adaptive
/// model system - heavy model on mains, light model on battery, per-mode overrides in
/// each mode's own editor.
struct EnergySettingsView: View {
    @Environment(AppState.self) private var state
    private let hardware = HardwareProfile.current

    var body: some View {
        @Bindable var settings = state.settings
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.gap) {
                CardSection("This Mac") {
                    HStack(alignment: .top, spacing: 10) {
                        specColumn
                        Spacer(minLength: 12)
                    }
                    .padding(10)
                    .innerWell(radius: Metrics.innerRadius)
                }

                CardSection("Memory") {
                    Picker("Keep models in memory", selection: $settings.modelCooldownSeconds) {
                        Text("Only while dictating").tag(0)
                        Text("10 seconds after use").tag(10)
                        Text("30 seconds after use").tag(30)
                        Text("2 minutes after use").tag(120)
                        Text("15 minutes after use").tag(900)
                        Text("Until quit").tag(-1)
                    }
                    Caption("Loaded speech and AI models answer instantly but hold memory. Unloading sooner saves energy and memory; the next dictation after an unload takes a few extra seconds while the model reloads. \u{201C}Only while dictating\u{201D} is the deepest saver.")
                }

                CardSection("Adaptive models",
                            subtitle: "Run different models depending on whether this Mac is plugged in") {
                    Toggle("Switch models with the power source", isOn: $settings.energyAdaptive)
                        .toggleStyle(.switch)
                    if settings.energyAdaptive {
                        adaptiveGroup(title: "Dictation model",
                                      subtitle: "Turns your voice into words",
                                      options: speechOptions,
                                      plugged: $settings.speechModelPluggedID,
                                      battery: $settings.speechModelBatteryID)

                        Divider().padding(.vertical, 2)

                        adaptiveGroup(title: "Cleanup model",
                                      subtitle: "Turns those words into finished text",
                                      options: cleanupOptions,
                                      plugged: $settings.languageModelPluggedID,
                                      battery: $settings.languageModelBatteryID)

                        Caption("Each mode can also carry its own models in its editor - a mode's choice wins over these defaults.")
                    }
                }
            }
            .padding(20)
        }
        .navigationTitle("Energy")
    }

    /// The machine's real specifications, laid out as label/value pairs.
    private var specColumn: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 5) {
            GridRow {
                Text("Chip").foregroundStyle(.secondary)
                Text(hardware.chipName)
            }
            GridRow {
                Text("Memory").foregroundStyle(.secondary)
                Text("\(hardware.memoryGB) GB")
            }
            GridRow {
                Text("Cores").foregroundStyle(.secondary)
                Text("\(hardware.cpuCores)")
            }
            GridRow {
                Text("Model").foregroundStyle(.secondary)
                Text(hardware.modelIdentifier)
            }
            GridRow {
                Text("Power").foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    Image(systemName: PowerMonitor.shared.onACPower ? "powerplug.fill" : "battery.75percent")
                        .foregroundStyle(PowerMonitor.shared.onACPower ? Color.green : Color.orange)
                    Text(powerLine)
                }
            }
        }
        .font(.callout)
    }

    private var powerLine: String {
        var line = PowerMonitor.shared.onACPower ? "Plugged in" : "On battery"
        if let percent = PowerMonitor.shared.batteryPercent { line += " \u{00B7} \(percent)%" }
        return line
    }

    /// EVERY entry the library holds for this kind - built-in Apple engines, downloadable
    /// models, and anything the user imported themselves (custom models live in the same
    /// catalog, so they appear here automatically).
    private var speechOptions: [ModelInfo] { state.models.speechModels }
    private var cleanupOptions: [ModelInfo] { state.models.languageModels }

    /// One power-aware pair (plugged / battery) for a single model role.
    private func adaptiveGroup(title: String, subtitle: String, options: [ModelInfo],
                               plugged: Binding<String?>, battery: Binding<String?>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.caption.weight(.semibold))
                Text(subtitle).font(.caption2).foregroundStyle(.secondary)
            }
            modelPicker("Plugged in", options: options, selection: plugged)
            modelPicker("On battery", options: options, selection: battery)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func modelPicker(_ label: String, options: [ModelInfo],
                             selection: Binding<String?>) -> some View {
        Picker(label, selection: selection) {
            Text("Use the main selection").tag(String?.none)
            ForEach(options) { model in
                Text(model.displayName + (state.models.isUserModel(model) ? " (yours)" : ""))
                    .tag(String?.some(model.id))
            }
        }
    }
}
