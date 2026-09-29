//
//  SettingsView.swift
//  DroneCast — Views
//
//  Aircraft selection (with the effective gust clamp shown live),
//  threshold editing, the AI Briefing toggle, and the pilot-in-command
//  disclaimer.
//
//  Note: SwiftUI Stepper doesn't exist on watchOS, hence ThresholdAdjuster.
//

import SwiftUI

struct SettingsView: View {
    @Environment(FlightStore.self) private var store

    /// Personal-team builds expire after 7 days — knowing which build is on
    /// the watch is the difference between "bug" and "reinstall".
    private static var versionText: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "\(version) (\(build))"
    }

    var body: some View {
        @Bindable var store = store

        List {
            Section("Aircraft") {
                ForEach(DroneProfile.fleet) { profile in
                    Button {
                        store.selectedProfile = profile
                    } label: {
                        HStack {
                            Text(profile.name).font(.caption)
                            Spacer()
                            if profile == store.selectedProfile {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.green)
                            }
                        }
                    }
                }
                LabeledContent {
                    Text("\(FlightScorer.mph(store.effectiveGustLimit)) mph")
                        .font(.caption2.monospacedDigit())
                } label: {
                    Text(store.aircraftLimitBinds ? "Gust limit (aircraft)" : "Gust limit (yours)")
                        .font(.caption2)
                }
            }

            Section("Thresholds") {
                ThresholdAdjuster(title: "Max gusts", unit: " mph",
                                  range: 5...30, step: 1,
                                  value: $store.thresholds.maxGustMph)
                ThresholdAdjuster(title: "Max rain chance", unit: "%",
                                  range: 0...60, step: 5,
                                  value: $store.thresholds.maxPrecipChancePercent)
                ThresholdAdjuster(title: "Max humidity", unit: "%",
                                  range: 40...95, step: 5,
                                  value: $store.thresholds.maxHumidityPercent)
                Button("Reset to defaults") {
                    store.thresholds = .standard
                }
                .font(.caption)
            }

            Section {
                Toggle(isOn: $store.aiBriefingEnabled) {
                    Text("AI Briefing").font(.caption)
                }
                Text(store.briefingStatusText)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            } header: {
                Text("Briefing")
            } footer: {
                Text("The go/no-go verdict always comes from DroneCast's scoring engine. "
                     + "AI only rewords it; any text that changes a number or the verdict "
                     + "is discarded for the template.")
                    .font(.system(size: 9))
            }

            Section("About") {
                Text(Disclaimer.text)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Link("FAA drone rules", destination: URL(string: "https://www.faa.gov/uas")!)
                    .font(.caption2)
                LabeledContent {
                    Text(Self.versionText).font(.caption2.monospacedDigit())
                } label: {
                    Text("Version").font(.caption2)
                }
            }
        }
    }
}

// MARK: - Threshold adjuster (watch-native +/- row)

private struct ThresholdAdjuster: View {
    let title: String
    let unit: String
    let range: ClosedRange<Double>
    let step: Double
    @Binding var value: Double

    var body: some View {
        VStack(spacing: 3) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            HStack {
                Button {
                    value = max(range.lowerBound, value - step)
                } label: {
                    Image(systemName: "minus")
                }
                .buttonStyle(.bordered)
                .disabled(value <= range.lowerBound)
                .accessibilityLabel("Decrease \(title)")

                Spacer()

                Text("\(Int(value))\(unit)")
                    .font(.body.monospacedDigit())

                Spacer()

                Button {
                    value = min(range.upperBound, value + step)
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.bordered)
                .disabled(value >= range.upperBound)
                .accessibilityLabel("Increase \(title)")
            }
        }
        .padding(.vertical, 2)
        // Two tiny buttons is a poor VoiceOver target; expose the row as one
        // adjustable control so it responds to swipe up / swipe down.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue("\(Int(value))\(unit)")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: value = min(range.upperBound, value + step)
            case .decrement: value = max(range.lowerBound, value - step)
            @unknown default: break
            }
        }
    }
}

// MARK: - Disclaimer

enum Disclaimer {
    static let text = """
    DroneCast is a weather decision aid, not an authorization to fly. You \
    are the pilot in command and solely responsible for every flight \
    decision, airspace authorization (B4UFLY / Aloft), and FAA compliance: \
    TRUST or Part 107, registration and Remote ID for aircraft 250 g and \
    over, 400 ft AGL ceiling, and visual line of sight at all times.
    """
}
