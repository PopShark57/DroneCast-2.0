//
//  BriefingAnswer.swift
//  DroneCast — Briefing layer (compiled into app, widget, and test targets)
//
//  What Siri says for "Can I fly?". Pure function of the persisted state
//  and the briefing cache, so it's unit-testable and never needs the live
//  store, the network, or a language model.
//

import Foundation

enum BriefingAnswer {

    static let noData = "DroneCast has no current weather. Open the app to refresh."

    static func text(state: PersistedState?,
                     cache: [String: BriefingCacheEntry],
                     now: Date = .now,
                     calendar: Calendar = .current,
                     locale: Locale = .current) -> String {
        guard let state,
              let facts = BriefingFacts(state: state, calendar: calendar, locale: locale),
              let timestamp = state.snapshot?.timestamp
        else { return noData }

        let age = DataFreshness.age(of: timestamp, now: now)
        guard !DataFreshness.isExpired(age) else {
            return "DroneCast's weather is over 2 hours old. Open the app to refresh."
        }

        let briefing: Briefing
        if state.aiBriefingEnabled ?? true,
           let entry = cache[facts.aircraftID], entry.facts == facts {
            briefing = entry.briefing
        } else {
            briefing = BriefingTemplate.briefing(for: facts, snapshotTimestamp: timestamp, reason: nil)
        }

        var answer = briefing.spokenText
        if DataFreshness.isStale(age), let age {
            answer += " This is from \(Int(age / 60)) minutes ago."
        }
        return answer
    }
}
