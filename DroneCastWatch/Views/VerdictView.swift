//
//  VerdictView.swift
//  DroneCast — Views
//
//  The answer, first. Big verdict, score gauge, plain-English briefing,
//  binding-factor sentence, data age, and the permanent airspace reminder.
//

import SwiftUI

struct VerdictView: View {
    @Environment(FlightStore.self) private var store
    @State private var showingAircraftPicker = false

    var body: some View {
        ScrollView {
            VStack(spacing: 6) {
                switch store.phase {
                case .loading where store.snapshot == nil:
                    ProgressView("Checking conditions…")
                        .padding(.top, 30)
                case .failed(let message):
                    ContentUnavailableView {
                        Label("No data", systemImage: "wifi.slash")
                    } description: {
                        Text(message).font(.caption2)
                    } actions: {
                        refreshButton
                    }
                default:
                    content
                }
            }
            .padding(.horizontal, 4)
        }
        .sheet(isPresented: $showingAircraftPicker) {
            AircraftPickerSheet()
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if store.isExpired {
            ContentUnavailableView {
                Label("Data expired", systemImage: "clock.badge.exclamationmark")
            } description: {
                Text("Weather is over 2 hours old.").font(.caption2)
            } actions: {
                refreshButton
            }
        } else if let verdict = store.verdict {
            if let alert = store.snapshot?.severeAlert {
                Label(alert, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .padding(.top, 4)
            }

            VStack(spacing: 6) {
                Gauge(value: Double(verdict.score), in: 0...100) {
                    Image(systemName: "airplane")
                } currentValueLabel: {
                    Text("\(verdict.score)")
                        .font(.title3.monospacedDigit())
                }
                .gaugeStyle(.accessoryCircular)
                .tint(verdict.verdict.tint)
                .scaleEffect(1.35)
                .padding(.top, 14)
                .padding(.bottom, 8)

                Text(verdict.verdict.rawValue)
                    .font(.title3.bold())
                    .foregroundStyle(verdict.verdict.tint)
            }
            // Read as one thing: colour and gauge carry the meaning visually,
            // and neither survives into VoiceOver on its own.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(verdict.verdict.spokenLabel) for \(store.selectedProfile.name)")
            .accessibilityValue("Score \(verdict.score) of 100")

            if let briefing = store.briefing {
                BriefingCardView(briefing: briefing)
                    .padding(.top, 2)
            }

            aircraftChip

            Text(verdict.bindingFactor)
                .font(.caption2)
                .multilineTextAlignment(.center)
                .padding(.top, 2)

            if store.isStale {
                Text("STALE")
                    .font(.system(size: 10, weight: .bold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.gray.opacity(0.35), in: Capsule())
                    .accessibilityLabel("Data is over 30 minutes old")
            }

            ageLine
            refreshErrorLine

            Text("Check airspace: B4UFLY / Aloft")
                .font(.system(size: 11))
                .foregroundStyle(.orange)
                .padding(.top, 4)

            refreshButton
                .padding(.top, 6)
        } else {
            Spacer(minLength: 30)
            Text("DroneCast")
                .font(.headline)
            Text("Weather go/no-go for your fleet.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            aircraftChip
                .padding(.top, 4)
            refreshButton
                .padding(.top, 8)
        }
    }

    // MARK: Pieces

    private var ageLine: some View {
        Group {
            if let timestamp = store.snapshot?.timestamp {
                HStack(spacing: 3) {
                    Text("Updated")
                    Text(timestamp, style: .relative)
                    Text("ago")
                }
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            }
        }
    }

    /// The refresh that produced what's on screen may have been hours ago —
    /// if the latest attempt failed, say so rather than letting the age line
    /// imply everything is fine.
    @ViewBuilder
    private var refreshErrorLine: some View {
        if let error = store.lastRefreshError, store.phase != .loading {
            Label(error, systemImage: "arrow.clockwise.circle")
                .font(.system(size: 10))
                .foregroundStyle(.orange)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 4)
        }
    }

    // MARK: Aircraft switcher

    private var aircraftChip: some View {
        Button {
            showingAircraftPicker = true
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "airplane.circle")
                    .font(.system(size: 11))
                Text(store.selectedProfile.name)
                    .font(.caption2)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.gray.opacity(0.25), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Aircraft, \(store.selectedProfile.name)")
        .accessibilityHint("Choose a different aircraft")
    }

    private var refreshButton: some View {
        Button {
            Task { await store.refresh() }
        } label: {
            if store.phase == .loading {
                ProgressView()
            } else {
                Label("Refresh", systemImage: "arrow.clockwise")
                    .font(.caption)
            }
        }
        .buttonStyle(.bordered)
        .disabled(store.phase == .loading)
    }
}

// MARK: - Aircraft picker sheet

private struct AircraftPickerSheet: View {
    @Environment(FlightStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section("Aircraft") {
                ForEach(DroneProfile.fleet) { profile in
                    Button {
                        store.selectedProfile = profile
                        dismiss()
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(profile.name)
                                    .font(.caption)
                                Text("Gusts < \(FlightScorer.mph(gustLimit(for: profile))) mph")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if profile == store.selectedProfile {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.green)
                            }
                        }
                    }
                }
            }
        }
    }

    /// Effective limit shown per aircraft — the verdict rescoring uses the
    /// exact same clamp, so what you pick is what gets scored.
    private func gustLimit(for profile: DroneProfile) -> Double {
        FlightScorer(thresholds: store.thresholds).effectiveGustLimit(for: profile)
    }
}
