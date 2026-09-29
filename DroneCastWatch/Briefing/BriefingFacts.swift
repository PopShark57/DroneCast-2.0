//
//  BriefingFacts.swift
//  DroneCast — Briefing layer (compiled into app, widget, and test targets)
//
//  The ONLY input to a briefing, AI or template. Every value here comes
//  from the deterministic scoring engine and is pre-formatted exactly the
//  way the rest of the app shows it, so the language model never has a
//  number to compute, round, or convert — only strings to copy.
//
//  Pure Foundation: no FoundationModels, no SwiftUI.
//

import Foundation

struct BriefingFacts: Codable, Hashable, Sendable {

    struct Wind: Codable, Hashable, Sendable {
        let sustainedMph: String
        let gustMph: String
        /// The per-aircraft clamp the verdict was scored against.
        let gustLimitMph: String
        /// "aircraft rating" when the airframe clamps below the pilot's own
        /// threshold, "pilot threshold" otherwise.
        let gustLimitSetBy: String
    }

    struct Precipitation: Codable, Hashable, Sendable {
        let chancePercent: String
        let chanceLimitPercent: String
        let fallingNow: Bool
    }

    enum DataSource: String, Codable, Hashable, Sendable {
        case openMeteo = "Open-Meteo"
        case weatherKit = "WeatherKit"

        /// The app only has these two providers; WeatherKitProvider reports
        /// itself as "Apple Weather".
        init(providerName: String) {
            self = providerName == "Apple Weather" ? .weatherKit : .openMeteo
        }
    }

    let aircraftID: String
    let aircraftName: String
    let verdict: Verdict
    let score: Int
    /// The engine's own binding-factor sentence — the reason for the verdict.
    let primaryFactor: String
    /// Every other gate and caution flag that fired, as engine labels.
    let otherFactors: [String]
    /// Short engine-derived reason for complication headlines.
    let headlineReason: String
    let wind: Wind
    let precipitation: Precipitation
    let temperatureF: String
    let visibilityMiles: String
    let severeAlert: String?
    /// Longest run of GO hours in the forecast, e.g. "2 PM – 5 PM"; nil when
    /// there is none.
    let bestWindow: String?
    /// How far ahead `bestWindow` looked.
    let windowHorizonHours: String
    let dataSource: DataSource
}

// MARK: - Construction from engine output

extension BriefingFacts {

    /// Hours covered by the window strip (current hour + next 12).
    static let horizonHours = ForecastWindow.defaultLimit - 1

    init(verdict: FlightVerdict,
         snapshot: ConditionsSnapshot,
         profile: DroneProfile,
         thresholds: UserThresholds,
         bestWindow: DateInterval?,
         calendar: Calendar = .current,
         locale: Locale = .current) {

        let gustLimit = verdict.effectiveGustLimitMph

        var others: [String] = verdict.gates.map(\.label) + verdict.flags.map(\.label)
        others.removeAll { $0 == verdict.bindingFactor }
        var seen = Set<String>()
        others = others.filter { seen.insert($0).inserted }

        self.init(
            aircraftID: profile.id,
            aircraftName: profile.name,
            verdict: verdict.verdict,
            score: verdict.score,
            primaryFactor: verdict.bindingFactor,
            otherFactors: others,
            headlineReason: Self.reason(for: verdict),
            wind: Wind(
                sustainedMph: FlightScorer.mph(snapshot.windMph),
                gustMph: FlightScorer.mph(snapshot.gustMph),
                gustLimitMph: FlightScorer.mph(gustLimit),
                gustLimitSetBy: gustLimit < thresholds.maxGustMph
                    ? "aircraft rating" : "pilot threshold"),
            precipitation: Precipitation(
                chancePercent: "\(Int(snapshot.precipChancePercent))",
                chanceLimitPercent: "\(Int(thresholds.maxPrecipChancePercent))",
                fallingNow: snapshot.isPrecipitating),
            temperatureF: "\(Int(snapshot.tempF.rounded()))",
            visibilityMiles: FlightScorer.mph(snapshot.visibilityMiles),
            severeAlert: snapshot.severeAlert,
            bestWindow: bestWindow.map {
                Self.windowText($0, calendar: calendar, locale: locale)
            },
            windowHorizonHours: "\(Self.horizonHours)",
            dataSource: DataSource(providerName: snapshot.providerName))
    }

    /// Rebuilds facts from the persisted App Group state — the path used by
    /// the "Can I fly?" intent, which never touches the live store.
    init?(state: PersistedState,
          calendar: Calendar = .current,
          locale: Locale = .current) {
        guard let snapshot = state.snapshot, let verdict = state.verdict else { return nil }
        let window = WindowFinder.bestGoWindow(state.hourlyVerdicts.map { ($0.date, $0.verdict) })
        self.init(verdict: verdict,
                  snapshot: snapshot,
                  profile: DroneProfile.profile(id: state.profileID),
                  thresholds: state.thresholds,
                  bestWindow: window,
                  calendar: calendar,
                  locale: locale)
    }

    /// "2 PM – 5 PM" in 12-hour locales, "14 – 17" in 24-hour ones.
    static func windowText(_ interval: DateInterval,
                           calendar: Calendar = .current,
                           locale: Locale = .current) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = locale
        formatter.setLocalizedDateFormatFromTemplate("j")
        // Newer ICU puts a narrow no-break space before "PM"; plain spaces
        // keep the string identical across OS versions and easy to quote.
        func hour(_ date: Date) -> String {
            formatter.string(from: date).replacingOccurrences(of: "\u{202F}", with: " ")
        }
        return "\(hour(interval.start)) – \(hour(interval.end))"
    }

    /// Engine-derived, ≤ 26 characters, so "NO-GO · <reason>" always fits
    /// the 40-character complication budget.
    static func reason(for verdict: FlightVerdict) -> String {
        if let gate = verdict.gates.first { return gate.briefingReason }
        switch verdict.verdict {
        case .go:
            // GO can sit exactly on a limit — don't call that "within".
            if let atLimit = verdict.factors.first(where: { $0.status == .fail }) {
                return "\(atLimit.name.lowercased()) at limit"
            }
            return "within your limits"
        case .caution, .noGo:
            if let flag = verdict.flags.first, verdict.score >= 50 {
                return flag.briefingReason
            }
            return "score \(verdict.score)"
        }
    }
}

// MARK: - Number inventory (used by the hallucination guard)

extension BriefingFacts {

    /// Every string the model is allowed to quote numbers from.
    var quotableText: [String] {
        [aircraftName, "\(score)", primaryFactor, headlineReason,
         wind.sustainedMph, wind.gustMph, wind.gustLimitMph,
         precipitation.chancePercent, precipitation.chanceLimitPercent,
         temperatureF, visibilityMiles, windowHorizonHours]
        + otherFactors
        + [severeAlert, bestWindow].compactMap { $0 }
    }

    /// Every numeric token that appears anywhere in the facts.
    var allowedNumbers: Set<String> {
        Set(quotableText.flatMap(BriefingNumbers.extract))
    }

    /// Numbers a briefing must mention: the ones behind the binding factor,
    /// or the score when that factor has no number of its own (e.g. "all
    /// factors within your limits", "precipitation falling").
    var requiredNumbers: [String] {
        let fromFactor = BriefingNumbers.extract(primaryFactor)
        return fromFactor.isEmpty ? ["\(score)"] : fromFactor
    }

    /// Stable JSON handed to the model — structured data, never prose.
    func jsonString() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }
}

// MARK: - Numeric token extraction

enum BriefingNumbers {
    /// Signed integers and decimals: "20", "17.9", "-5". A hyphen only
    /// counts as a minus sign when it doesn't follow a letter or digit, so
    /// "2-5" is two numbers but "-5°F" keeps its sign.
    private static let pattern = #"(?<![\p{L}\p{N}])-?\d+(?:\.\d+)?|\d+(?:\.\d+)?"#

    static func extract(_ text: String) -> [String] {
        // Unicode minus → ASCII hyphen, so "−5" and "-5" compare equal.
        let normalized = text.replacingOccurrences(of: "\u{2212}", with: "-")
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(normalized.startIndex..., in: normalized)
        return regex.matches(in: normalized, options: [], range: range).compactMap {
            Range($0.range, in: normalized).map { String(normalized[$0]) }
        }
    }
}

// MARK: - Short reasons for headlines

extension HardGate {
    var briefingReason: String {
        switch self {
        case .activePrecipitation:    return "precipitation falling"
        case .windAboveAircraftLimit: return "wind over aircraft limit"
        case .temperatureOutOfRange:  return "temp out of range"
        case .severeWeatherAlert:     return "severe weather alert"
        case .lowVisibility:          return "low visibility"
        }
    }
}

extension CautionFlag {
    var briefingReason: String {
        switch self {
        case .goggleFog:         return "goggle fog risk"
        case .coldBattery:       return "cold battery"
        case .sustainedWindHigh: return "sustained wind high"
        case .fpvGustBand:       return "gusty for FPV"
        case .humidityOverLimit:   return "humidity over limit"
        case .rainChanceOverLimit: return "rain chance over limit"
        }
    }
}
