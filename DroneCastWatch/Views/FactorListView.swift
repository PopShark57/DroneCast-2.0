//
//  FactorListView.swift
//  DroneCast — Views
//
//  The "why" behind the verdict — each factor's value vs. limit — plus the
//  Apple Weather attribution mark + legal link required by WeatherKit.
//

import SwiftUI

struct FactorListView: View {
    @Environment(FlightStore.self) private var store

    var body: some View {
        List {
            if let verdict = store.verdict, !store.isExpired {
                Section("Factors · \(store.selectedProfile.shortName)") {
                    ForEach(verdict.factors) { factor in
                        FactorRow(factor: factor)
                    }
                }

                if !verdict.flags.isEmpty {
                    Section("Cautions") {
                        ForEach(verdict.flags, id: \.self) { flag in
                            Label(flag.label, systemImage: "exclamationmark.triangle")
                                .font(.caption2)
                                .foregroundStyle(.yellow)
                        }
                    }
                }
            } else {
                Text("No current data — refresh from the verdict page.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Section {
                attribution
            }
            .listRowBackground(Color.clear)
        }
    }

    // MARK: Attribution (WeatherKit requirement — keep visible)

    @ViewBuilder
    private var attribution: some View {
        VStack(alignment: .leading, spacing: 4) {
            if store.snapshot?.providerName == "Open-Meteo" || !WeatherConfig.preferWeatherKit {
                Link("Weather data by Open-Meteo.com",
                     destination: URL(string: "https://open-meteo.com/")!)
                    .font(.system(size: 10))
                Text("Free tier · non-commercial use")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            } else {
                if let markURL = store.attributionMarkURL {
                    AsyncImage(url: markURL) { image in
                        image.resizable().scaledToFit()
                    } placeholder: {
                        Text(" Weather").font(.caption2)
                    }
                    .frame(height: 12)
                } else {
                    Text(" Weather").font(.caption2)
                }
                if let legalURL = store.attributionLegalURL {
                    Link("Other data sources", destination: legalURL)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            Text("Point forecast — winds at 100–400 ft AGL typically exceed surface readings.")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
        }
    }
}

private struct FactorRow: View {
    let factor: FactorScore

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(factor.name)
                    .font(.caption)
                Text("\(factor.valueText) · limit \(factor.limitText)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(factor.name), \(factor.valueText), \(factor.status.label), "
            + "limit \(factor.limitText)")
    }

    private var color: Color {
        switch factor.status {
        case .pass: return .green
        case .warn: return .yellow
        case .fail: return .red
        }
    }
}
