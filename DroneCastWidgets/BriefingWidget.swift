//
//  BriefingWidget.swift
//  DroneCast — Widget extension
//
//  "Flight Briefing" complication: the briefing headline on the watch face.
//  Reads the cached briefing from the App Group and NEVER calls a language
//  model — if the cache doesn't describe the current persisted verdict, it
//  falls back to the deterministic template built from that same state.
//  Same STALE / expired policy as the verdict complication.
//

import WidgetKit
import SwiftUI

struct BriefingEntry: TimelineEntry {
    let date: Date
    let briefing: Briefing?        // nil → no current data → "refresh"
    let isStale: Bool
}

struct BriefingProvider: TimelineProvider {

    func placeholder(in context: Context) -> BriefingEntry {
        BriefingEntry(
            date: .now,
            briefing: Briefing(
                headline: "GO · within your limits",
                detail: "DJI Neo 2: all factors within your limits, score 82.",
                window: "Best window 2 PM – 5 PM",
                source: .template, fallbackReason: nil, verdict: .go,
                profileID: DroneProfile.neo2.id, snapshotTimestamp: .now),
            isStale: false)
    }

    func getSnapshot(in context: Context, completion: @escaping (BriefingEntry) -> Void) {
        let now = Date()
        guard let briefing = Self.currentBriefing(),
              !DataFreshness.isExpired(DataFreshness.age(of: briefing.snapshotTimestamp, now: now))
        else {
            completion(placeholder(in: context))
            return
        }
        completion(BriefingEntry(
            date: now, briefing: briefing,
            isStale: DataFreshness.isStale(DataFreshness.age(of: briefing.snapshotTimestamp, now: now))))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<BriefingEntry>) -> Void) {
        let now = Date()
        guard let briefing = Self.currentBriefing(),
              !DataFreshness.isExpired(DataFreshness.age(of: briefing.snapshotTimestamp, now: now))
        else {
            completion(Timeline(
                entries: [BriefingEntry(date: now, briefing: nil, isStale: true)],
                policy: .after(now.addingTimeInterval(15 * 60))))
            return
        }

        let staleAt = briefing.snapshotTimestamp.addingTimeInterval(DataFreshness.staleAfter)
        let expiresAt = briefing.snapshotTimestamp.addingTimeInterval(DataFreshness.expiresAfter)

        var entries = [BriefingEntry(date: now, briefing: briefing, isStale: now >= staleAt)]
        if staleAt > now {
            entries.append(BriefingEntry(date: staleAt, briefing: briefing, isStale: true))
        }
        entries.append(BriefingEntry(date: expiresAt, briefing: nil, isStale: true))

        let nextReload = min(now.addingTimeInterval(DataFreshness.staleAfter), expiresAt)
        completion(Timeline(entries: entries, policy: .after(nextReload)))
    }

    /// Cached briefing when it describes the persisted verdict exactly,
    /// otherwise the template for that verdict. Never a model call.
    static func currentBriefing() -> Briefing? {
        guard let state = SharedStore.load(),
              let facts = BriefingFacts(state: state),
              let timestamp = state.snapshot?.timestamp else { return nil }

        if state.aiBriefingEnabled ?? true,
           let entry = BriefingStore.entry(forProfile: facts.aircraftID),
           entry.facts == facts {
            var briefing = entry.briefing
            briefing.snapshotTimestamp = timestamp
            return briefing
        }
        return BriefingTemplate.briefing(for: facts, snapshotTimestamp: timestamp, reason: nil)
    }
}

// MARK: - Views

struct BriefingWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: BriefingEntry

    var body: some View {
        Group {
            switch family {
            case .accessoryInline:
                inline
            default:
                rectangular
            }
        }
        .containerBackground(.clear, for: .widget)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenSummary)
    }

    private var tint: Color {
        guard let briefing = entry.briefing, !entry.isStale else { return .gray }
        return briefing.verdict.tint
    }

    private var spokenSummary: String {
        guard let briefing = entry.briefing else {
            return "Flight briefing unavailable. Open DroneCast to refresh."
        }
        let staleness = entry.isStale ? " Data over 30 minutes old." : ""
        return briefing.spokenText
            .replacingOccurrences(of: Verdict.noGo.rawValue, with: Verdict.noGo.spokenLabel)
            + staleness
    }

    @ViewBuilder
    private var inline: some View {
        if let briefing = entry.briefing {
            Text(briefing.headline)
        } else {
            Text("DroneCast — refresh")
        }
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 1) {
            if let briefing = entry.briefing {
                HStack(spacing: 3) {
                    Text(briefing.headline)
                        .font(.headline)
                        .foregroundStyle(tint)
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                    if briefing.source == .ai {
                        Image(systemName: "sparkles")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                }
                Text(entry.isStale ? "STALE · \(briefing.window)" : briefing.window)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Text("Briefing")
                    .font(.headline)
                    .foregroundStyle(.gray)
                Text("Open DroneCast to refresh")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Widget

struct BriefingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: BriefingStore.widgetKind, provider: BriefingProvider()) { entry in
            BriefingWidgetView(entry: entry)
        }
        .configurationDisplayName("Flight Briefing")
        .description("Plain-English briefing headline for your selected drone.")
        .supportedFamilies([.accessoryRectangular, .accessoryInline])
    }
}
