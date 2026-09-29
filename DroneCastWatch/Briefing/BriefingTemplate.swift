//
//  BriefingTemplate.swift
//  DroneCast — Briefing layer (compiled into app, widget, and test targets)
//
//  The deterministic briefing: used whenever the model is off, unavailable,
//  slow, erroring, or rejected by the guard. Built only from BriefingFacts
//  strings, so it can't say anything the engine didn't — the unit tests
//  also run every template through the hallucination guard.
//

import Foundation

enum BriefingTemplate {

    static func draft(for facts: BriefingFacts) -> BriefingDraft {
        BriefingDraft(headline: headline(for: facts),
                      detail: detail(for: facts),
                      window: window(for: facts))
    }

    static func briefing(for facts: BriefingFacts,
                         snapshotTimestamp: Date,
                         reason: BriefingFallbackReason?) -> Briefing {
        let draft = draft(for: facts)
        return Briefing(headline: draft.headline,
                        detail: draft.detail,
                        window: draft.window,
                        source: .template,
                        fallbackReason: reason,
                        verdict: facts.verdict,
                        profileID: facts.aircraftID,
                        snapshotTimestamp: snapshotTimestamp)
    }

    // MARK: Pieces

    /// "GO · within your limits", "NO-GO · wind over aircraft limit" — the
    /// longest possible reason keeps this under 40 characters.
    static func headline(for facts: BriefingFacts) -> String {
        "\(facts.verdict.rawValue) · \(facts.headlineReason)"
    }

    static func detail(for facts: BriefingFacts) -> String {
        let name = facts.aircraftName
        let factor = trimmed(facts.primaryFactor)
        switch facts.verdict {
        case .go:
            // "all factors within your limits" on a normal GO day; the
            // engine names the factor instead when one sits on its limit.
            return "\(name): \(lowercasingFirst(factor)), score \(facts.score). "
                + "Gusts \(facts.wind.gustMph) mph against a \(facts.wind.gustLimitMph) mph limit."
        case .caution:
            return "\(name): marginal, score \(facts.score). \(factor)."
        case .noGo:
            return "\(name): stay grounded, score \(facts.score). \(factor)."
        }
    }

    static func window(for facts: BriefingFacts) -> String {
        guard let window = facts.bestWindow else {
            return "No clear window in the next \(facts.windowHorizonHours) hours"
        }
        // Hourly rows are scored without the alert feed (see WindowStripView).
        if facts.severeAlert != nil {
            return "Forecast window \(window), alert not included"
        }
        return "Best window \(window)"
    }

    private static func lowercasingFirst(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.lowercased() + text.dropFirst()
    }

    private static func trimmed(_ sentence: String) -> String {
        var text = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = text.last, ".!?".contains(last) { text.removeLast() }
        return text
    }
}
