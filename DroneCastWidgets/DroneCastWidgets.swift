//
//  DroneCastWidgets.swift
//  DroneCast — Widget extension
//
//  Complications read the LAST PERSISTED snapshot from the App Group —
//  they never fetch weather themselves. Future timeline entries come from
//  the already-scored hourly verdicts, so the complication stays roughly
//  right between app refreshes and goes gray "--" once data is > 2 h old.
//

import WidgetKit
import SwiftUI

@main
struct DroneCastWidgetBundle: WidgetBundle {
    var body: some Widget {
        VerdictWidget()
        BriefingWidget()
    }
}

// MARK: - Entry

struct VerdictEntry: TimelineEntry {
    let date: Date
    let verdict: Verdict?          // nil → stale/no data → gray "--"
    let score: Int
    let gustMph: Double
    let precipChancePercent: Double
    let profileShort: String
    let isStale: Bool
}

// MARK: - Provider

struct VerdictProvider: TimelineProvider {

    func placeholder(in context: Context) -> VerdictEntry {
        VerdictEntry(date: .now, verdict: .go, score: 82, gustMph: 9,
                     precipChancePercent: 10, profileShort: "NEO2", isStale: false)
    }

    func getSnapshot(in context: Context, completion: @escaping (VerdictEntry) -> Void) {
        completion(nowEntry() ?? placeholder(in: context))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<VerdictEntry>) -> Void) {
        let now = Date()
        let state = SharedStore.load()
        let profileShort = DroneProfile.profile(id: state?.profileID ?? "").shortName

        guard let state,
              let snapshot = state.snapshot,
              let verdict = state.verdict,
              !DataFreshness.isExpired(DataFreshness.age(of: snapshot.timestamp, now: now))
        else {
            // Nothing usable — say so, and check back sooner than the normal
            // cadence in case the app runs in the meantime.
            completion(Timeline(
                entries: [VerdictEntry(date: now, verdict: nil, score: 0,
                                       gustMph: 0, precipChancePercent: 0,
                                       profileShort: profileShort, isStale: true)],
                policy: .after(now.addingTimeInterval(15 * 60))))
            return
        }

        let staleAt = snapshot.timestamp.addingTimeInterval(DataFreshness.staleAfter)
        let expiresAt = snapshot.timestamp.addingTimeInterval(DataFreshness.expiresAfter)

        var entries: [VerdictEntry] = [VerdictEntry(
            date: now,
            verdict: verdict.verdict,
            score: verdict.score,
            gustMph: snapshot.gustMph,
            precipChancePercent: snapshot.precipChancePercent,
            profileShort: profileShort,
            isStale: now >= staleAt)]

        // Future entries come from the already-scored hourly verdicts, so the
        // complication keeps up with the forecast between app refreshes.
        for hour in state.hourlyVerdicts where hour.date > now && hour.date < expiresAt {
            entries.append(VerdictEntry(
                date: hour.date,
                verdict: hour.verdict,
                score: hour.score,
                gustMph: hour.gustMph,
                precipChancePercent: hour.precipChancePercent,
                profileShort: profileShort,
                isStale: hour.date >= staleAt))
        }

        // The gray-out has to be baked into the timeline: WidgetKit is under
        // no obligation to come back for a new one on time, and a confident
        // GO from three hours ago is exactly the wrong thing to show.
        if staleAt > now, !entries.contains(where: { $0.date == staleAt }) {
            entries.append(VerdictEntry(
                date: staleAt,
                verdict: verdict.verdict,
                score: verdict.score,
                gustMph: snapshot.gustMph,
                precipChancePercent: snapshot.precipChancePercent,
                profileShort: profileShort,
                isStale: true))
        }
        entries.append(VerdictEntry(
            date: expiresAt, verdict: nil, score: 0,
            gustMph: 0, precipChancePercent: 0,
            profileShort: profileShort, isStale: true))

        entries.sort { $0.date < $1.date }

        let nextReload = min(now.addingTimeInterval(DataFreshness.staleAfter), expiresAt)
        completion(Timeline(entries: entries, policy: .after(nextReload)))
    }

    /// Entry for "right now" from the persisted state; nil when the
    /// snapshot is missing or expired (> 2 h).
    private func nowEntry() -> VerdictEntry? {
        let now = Date()
        guard let state = SharedStore.load(),
              let snapshot = state.snapshot,
              let verdict = state.verdict else { return nil }

        let age = DataFreshness.age(of: snapshot.timestamp, now: now)
        guard !DataFreshness.isExpired(age) else { return nil }

        return VerdictEntry(
            date: now,
            verdict: verdict.verdict,
            score: verdict.score,
            gustMph: snapshot.gustMph,
            precipChancePercent: snapshot.precipChancePercent,
            profileShort: DroneProfile.profile(id: state.profileID).shortName,
            isStale: DataFreshness.isStale(age))
    }
}

// MARK: - Views

struct VerdictWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: VerdictEntry

    var body: some View {
        Group {
            switch family {
            case .accessoryRectangular:
                rectangular
            case .accessoryInline:
                inline
            case .accessoryCorner:
                corner
            default:
                circular
            }
        }
        .containerBackground(.clear, for: .widget)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenSummary)
    }

    private var tint: Color {
        guard let verdict = entry.verdict else { return .gray }
        return entry.isStale ? .gray : verdict.tint
    }

    /// The gauge reads as a bare number to VoiceOver otherwise.
    private var spokenSummary: String {
        guard let verdict = entry.verdict else {
            return "Flight conditions unavailable. Open DroneCast to refresh."
        }
        let staleness = entry.isStale ? ", data over 30 minutes old" : ""
        return "\(verdict.spokenLabel) for \(entry.profileShort), score \(entry.score) "
            + "of 100, gusts \(Int(entry.gustMph.rounded())) miles per hour\(staleness)"
    }

    private var circular: some View {
        Gauge(value: Double(entry.score), in: 0...100) {
            Text(entry.profileShort)
                .font(.system(size: 8))
        } currentValueLabel: {
            if entry.verdict == nil {
                Text("--")
            } else {
                Text("\(entry.score)")
            }
        }
        .gaugeStyle(.accessoryCircular)
        .tint(tint)
    }

    /// One line above the watch face — verdict plus the number that most
    /// often decides it.
    @ViewBuilder
    private var inline: some View {
        if let verdict = entry.verdict {
            Text("\(verdict.rawValue) · \(entry.profileShort) · G\(Int(entry.gustMph.rounded()))")
        } else {
            Text("DroneCast — refresh")
        }
    }

    /// Corner slots get the score curved around the bezel with the verdict
    /// in the corner itself.
    private var corner: some View {
        Text(entry.verdict?.rawValue ?? "--")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(tint)
            .widgetLabel {
                Gauge(value: Double(entry.score), in: 0...100) {
                    Text(entry.profileShort)
                }
                .tint(tint)
            }
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Text(entry.verdict?.rawValue ?? "STALE")
                    .font(.headline)
                    .foregroundStyle(tint)
                Text(entry.profileShort)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if entry.verdict == nil {
                Text("Open DroneCast to refresh")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Text("Gusts \(Int(entry.gustMph.rounded())) mph")
                    .font(.caption2)
                Text("Rain \(Int(entry.precipChancePercent))%")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Widget

struct VerdictWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "DroneCastVerdict", provider: VerdictProvider()) { entry in
            VerdictWidgetView(entry: entry)
        }
        .configurationDisplayName("Flight Conditions")
        .description("Go / no-go verdict for your selected drone.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular,
                            .accessoryInline, .accessoryCorner])
    }
}
