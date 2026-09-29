//
//  WindowStripView.swift
//  DroneCast — Views
//
//  "When should I fly?" — hour-by-hour verdict bars for the next 12 hours
//  plus the longest continuous GO window, if one exists.
//

import SwiftUI

struct WindowStripView: View {
    @Environment(FlightStore.self) private var store

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text("Next 12 hours")
                    .font(.headline)

                if store.hourlyVerdicts.isEmpty || store.isExpired {
                    Text("No forecast loaded — refresh from the verdict page.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    // Hourly rows are scored without the alert feed, so an
                    // active warning can leave green hours on screen while
                    // "now" is a hard NO-GO. Say it out loud here.
                    if let alert = store.snapshot?.severeAlert {
                        Label("\(alert) — hours below don't account for it",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.red)
                    }

                    windowCallout

                    VStack(spacing: 5) {
                        ForEach(store.hourlyVerdicts) { hour in
                            HourRow(hour: hour)
                        }
                    }

                    Text("Hourly point forecast for your current location.")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 4)
                }
            }
            .padding(.horizontal, 6)
        }
    }

    @ViewBuilder
    private var windowCallout: some View {
        if let window = store.bestWindow {
            Label {
                Text("Best: \(window.start, format: .dateTime.hour()) – \(window.end, format: .dateTime.hour())")
            } icon: {
                Image(systemName: "checkmark.circle.fill")
            }
            .font(.caption)
            .foregroundStyle(.green)
        } else {
            Label("No GO window in the next 12 h", systemImage: "xmark.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct HourRow: View {
    let hour: HourVerdict

    var body: some View {
        HStack(spacing: 6) {
            Text(hour.date, format: .dateTime.hour())
                .font(.system(size: 11).monospacedDigit())
                .frame(width: 42, alignment: .leading)

            Capsule()
                .fill(hour.verdict.tint.opacity(0.85))
                .frame(height: 10)

            Text("G\(Int(hour.gustMph.rounded()))")
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .trailing)
        }
        // The bar carries the verdict in colour alone — spell it out for
        // VoiceOver, and for anyone who can't separate the green from the red.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(hour.date.formatted(date: .omitted, time: .shortened)), "
            + "\(hour.verdict.spokenLabel), gusts \(Int(hour.gustMph.rounded())) miles per hour, "
            + "rain \(Int(hour.precipChancePercent)) percent")
    }
}
