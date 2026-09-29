//
//  Briefing.swift
//  DroneCast — Briefing layer (compiled into app, widget, and test targets)
//
//  The briefing value the UI, complication and Siri all read, plus the
//  per-aircraft cache in the App Group. Widgets and the App Intent read
//  this cache only — they never call a language model.
//

import Foundation

/// Raw text from a generator, before the hallucination guard has seen it.
struct BriefingDraft: Equatable, Sendable {
    var headline: String
    var detail: String
    var window: String
}

struct Briefing: Codable, Equatable, Sendable {

    enum Source: String, Codable, Sendable {
        /// Language model output that passed the hallucination guard.
        case ai
        /// Deterministic template.
        case template
    }

    /// ≤ 40 characters — sized for complications.
    let headline: String
    /// One or two sentences.
    let detail: String
    let window: String
    let source: Source
    /// Why the template was used; nil for AI briefings.
    let fallbackReason: BriefingFallbackReason?
    /// Engine verdict the text describes — drives tint, never the text.
    let verdict: Verdict
    let profileID: String
    /// Timestamp of the weather snapshot the facts came from, for the same
    /// STALE / expired policy the verdict complication uses.
    var snapshotTimestamp: Date

    /// Spoken / plain-text form for Siri.
    var spokenText: String {
        [headline, detail, window]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { line in
                guard let last = line.last, ".!?".contains(last) else { return line + "." }
                return line
            }
            .joined(separator: " ")
    }
}

enum BriefingFallbackReason: Codable, Equatable, Sendable {
    case disabledByUser
    case modelUnavailable(BriefingModelAvailability.Reason)
    case timedOut
    case generationFailed(String)
    case rejectedByGuard([GuardViolation])
}

/// What a generator reports before it's asked for anything.
enum BriefingModelAvailability: Equatable, Sendable {
    case available
    case unavailable(Reason)

    enum Reason: String, Codable, Equatable, Sendable {
        /// The model path is compiled out (BriefingConfig.useCloudModel is
        /// false) — the default for personal-team builds.
        case notConfigured
        /// Private Cloud Compute: "The device does not support Apple
        /// Intelligence."
        case deviceNotEligible
        /// Private Cloud Compute: "The system is not yet ready to serve PCC
        /// requests."
        case systemNotReady
        /// The per-user Private Cloud Compute quota is spent until it resets.
        case quotaReached
        /// A case added by a future SDK.
        case unknown

        var label: String {
            switch self {
            case .notConfigured:     return "Not enabled in this build"
            case .deviceNotEligible: return "This watch isn't eligible"
            case .systemNotReady:    return "Apple Intelligence isn't ready yet"
            case .quotaReached:      return "Daily AI limit reached"
            case .unknown:           return "AI unavailable"
            }
        }
    }
}

// MARK: - Cache

struct BriefingCacheEntry: Codable, Equatable, Sendable {
    let facts: BriefingFacts
    var briefing: Briefing
    /// True once the model has been asked about exactly these facts and
    /// gave a definitive answer (AI text, or text the guard rejected).
    /// Stops the same facts from spending quota twice.
    let modelSettled: Bool
}

/// Per-aircraft briefing cache in the App Group, beside SharedStore.
enum BriefingStore {
    private static let key = "dronecast.briefing.v1"

    /// Complication kind that shows the cached headline.
    static let widgetKind = "DroneCastBriefing"

    static var sharedDefaults: UserDefaults {
        UserDefaults(suiteName: AppGroup.identifier) ?? .standard
    }

    static func loadAll(from defaults: UserDefaults = BriefingStore.sharedDefaults)
        -> [String: BriefingCacheEntry] {
        guard let data = defaults.data(forKey: key),
              let entries = try? JSONDecoder().decode([String: BriefingCacheEntry].self, from: data)
        else { return [:] }
        return entries
    }

    static func entry(forProfile profileID: String,
                      in defaults: UserDefaults = BriefingStore.sharedDefaults) -> BriefingCacheEntry? {
        loadAll(from: defaults)[profileID]
    }

    static func save(_ entry: BriefingCacheEntry,
                     to defaults: UserDefaults = BriefingStore.sharedDefaults) {
        var entries = loadAll(from: defaults)
        entries[entry.facts.aircraftID] = entry
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: key)
    }
}
