//
//  FlightScorer.swift
//  DroneCast — Domain layer
//
//  Pure, stateless, deterministic. Conditions + profile + thresholds in,
//  verdict out. The entire go/no-go policy lives in this one file so it can
//  be exhaustively unit-tested with no mocks.
//
//  Two-stage evaluation:
//    1. Hard gates — any one fires an immediate NO-GO (score 0).
//    2. Weighted score 0–100 across six factors.
//
//  Verdict bands: GO ≥ 75 with no caution flags · CAUTION 50–74 or any
//  flag · NO-GO < 50 or any gate.
//
//  The pilot's humidity and rain-chance thresholds are limits, not just
//  weights: going above either raises a caution flag, so a day over your
//  own limit can never score GO.
//

import Foundation

struct FlightScorer: Sendable {
    var thresholds: UserThresholds

    // MARK: Weights (sum = 100)

    private enum Weight {
        static let gusts = 35.0
        static let sustainedWind = 20.0
        static let precipChance = 20.0
        static let humidity = 10.0
        static let temperature = 10.0
        static let sky = 5.0
    }

    // MARK: Per-aircraft clamping

    /// The stricter of (user gust threshold, aircraft rating × margin).
    /// Example with the 20 mph default: Neo → 17.9 (aircraft binds),
    /// Neo 2 / Air 3S → 20.0 (user threshold binds).
    func effectiveGustLimit(for profile: DroneProfile) -> Double {
        min(thresholds.maxGustMph, profile.maxWindMph * profile.gustMarginFactor)
    }

    // MARK: Evaluation

    func evaluate(_ c: ConditionsSnapshot, profile: DroneProfile) -> FlightVerdict {
        let gustLimit = effectiveGustLimit(for: profile)

        // ---- Stage 1: hard gates -------------------------------------
        var gates: [HardGate] = []
        if c.isPrecipitating { gates.append(.activePrecipitation) }
        if c.gustMph >= gustLimit || c.windMph >= gustLimit {
            gates.append(.windAboveAircraftLimit)
        }
        if c.tempC < profile.minTempC || c.tempC > profile.maxTempC {
            gates.append(.temperatureOutOfRange)
        }
        if c.severeAlert != nil { gates.append(.severeWeatherAlert) }
        if c.visibilityMiles < 3 { gates.append(.lowVisibility) }

        // ---- Caution flags -------------------------------------------
        var flags: [CautionFlag] = []
        if profile.checksGoggleFog, c.humidityPercent > 85, c.tempC < 10 {
            flags.append(.goggleFog)
        }
        if c.tempC < 0, c.tempC >= profile.minTempC {
            flags.append(.coldBattery)
        }
        if c.windMph >= gustLimit * 0.7, c.windMph < gustLimit {
            flags.append(.sustainedWindHigh)
        }
        if let band = profile.fpvCautionGustMph,
           c.gustMph >= band, c.gustMph < gustLimit {
            flags.append(.fpvGustBand)
        }
        // Exactly at the threshold is still flyable (it already costs the
        // factor's full weight); above it is over the pilot's own limit.
        if c.humidityPercent > thresholds.maxHumidityPercent {
            flags.append(.humidityOverLimit)
        }
        if c.precipChancePercent > thresholds.maxPrecipChancePercent {
            flags.append(.rainChanceOverLimit)
        }

        // ---- Stage 2: weighted factors -------------------------------
        let gustCredit = credit(c.gustMph, full: 10, zero: gustLimit)
        let windCredit = credit(c.windMph, full: 8, zero: gustLimit)
        let precipCredit = credit(c.precipChancePercent,
                                  full: 10, zero: thresholds.maxPrecipChancePercent)
        let humidityCredit = credit(c.humidityPercent,
                                    full: 55, zero: thresholds.maxHumidityPercent)
        let tempCredit = temperatureCredit(c.tempC, profile: profile)
        let skyCredit = (visibilityCredit(c.visibilityMiles) + cloudCredit(c.cloudCoverPercent)) / 2

        let raw = gustCredit * Weight.gusts
            + windCredit * Weight.sustainedWind
            + precipCredit * Weight.precipChance
            + humidityCredit * Weight.humidity
            + tempCredit * Weight.temperature
            + skyCredit * Weight.sky

        let score = gates.isEmpty ? Int(raw.rounded()) : 0

        // ---- Verdict --------------------------------------------------
        let verdict: Verdict
        if !gates.isEmpty || score < 50 {
            verdict = .noGo
        } else if score < 75 || !flags.isEmpty {
            verdict = .caution
        } else {
            verdict = .go
        }

        // ---- Factor table (for the breakdown screen) ------------------
        let factors = buildFactors(
            c: c, profile: profile, gustLimit: gustLimit,
            credits: (gustCredit, windCredit, precipCredit,
                      humidityCredit, tempCredit, skyCredit))

        let binding = bindingSentence(
            c: c, profile: profile, gustLimit: gustLimit,
            gates: gates, flags: flags, verdict: verdict, factors: factors,
            credits: (gustCredit, windCredit, precipCredit,
                      humidityCredit, tempCredit, skyCredit))

        return FlightVerdict(
            verdict: verdict, score: score, bindingFactor: binding,
            gates: gates, flags: flags, factors: factors,
            profileID: profile.id, effectiveGustLimitMph: gustLimit)
    }

    // MARK: Credit curves

    /// Linear credit: 1.0 at or below `full`, 0.0 at or above `zero`.
    /// Degrades to a step function if the anchors invert (e.g. a user
    /// threshold set below the full-credit anchor).
    private func credit(_ value: Double, full: Double, zero: Double) -> Double {
        guard zero > full else { return value < zero ? 1 : 0 }
        if value <= full { return 1 }
        if value >= zero { return 0 }
        return (zero - value) / (zero - full)
    }

    /// Full credit 10–32 °C; linear falloff to 0 at the aircraft's
    /// operating limits on either side.
    private func temperatureCredit(_ tempC: Double, profile: DroneProfile) -> Double {
        if tempC < 10 {
            return credit(10 - tempC, full: 0, zero: 10 - profile.minTempC)
        }
        if tempC > 32 {
            return credit(tempC - 32, full: 0, zero: profile.maxTempC - 32)
        }
        return 1
    }

    /// ≥ 6 SM full credit; ≤ 3 SM zero (3 SM is also a hard gate).
    private func visibilityCredit(_ miles: Double) -> Double {
        if miles >= 6 { return 1 }
        if miles <= 3 { return 0 }
        return (miles - 3) / 3
    }

    /// Clear sky full credit, solid overcast zero.
    private func cloudCredit(_ percent: Double) -> Double {
        max(0, min(1, 1 - percent / 100))
    }

    // MARK: Presentation helpers

    private func buildFactors(
        c: ConditionsSnapshot, profile: DroneProfile, gustLimit: Double,
        credits: (gust: Double, wind: Double, precip: Double,
                  humidity: Double, temp: Double, sky: Double)
    ) -> [FactorScore] {
        func status(_ credit: Double) -> FactorScore.Status {
            if credit >= 0.999 { return .pass }
            if credit <= 0 { return .fail }
            return .warn
        }
        return [
            FactorScore(name: "Gusts",
                        valueText: "\(Self.mph(c.gustMph)) mph",
                        limitText: "< \(Self.mph(gustLimit)) mph",
                        status: status(credits.gust)),
            FactorScore(name: "Sustained wind",
                        valueText: "\(Self.mph(c.windMph)) mph",
                        limitText: "< \(Self.mph(gustLimit)) mph",
                        status: status(credits.wind)),
            FactorScore(name: "Rain chance",
                        valueText: "\(Int(c.precipChancePercent))%",
                        limitText: "< \(Int(thresholds.maxPrecipChancePercent))%",
                        status: status(credits.precip)),
            FactorScore(name: "Humidity",
                        valueText: "\(Int(c.humidityPercent))%",
                        limitText: "< \(Int(thresholds.maxHumidityPercent))%",
                        status: status(credits.humidity)),
            FactorScore(name: "Temperature",
                        valueText: "\(Int(c.tempF.rounded()))°F",
                        limitText: "14–104°F",
                        status: status(credits.temp)),
            FactorScore(name: "Sky / visibility",
                        valueText: "\(Int(c.cloudCoverPercent))% cloud · \(Self.mph(c.visibilityMiles)) SM",
                        limitText: "≥ 3 SM",
                        status: status(credits.sky)),
        ]
    }

    private func bindingSentence(
        c: ConditionsSnapshot, profile: DroneProfile, gustLimit: Double,
        gates: [HardGate], flags: [CautionFlag], verdict: Verdict,
        factors: [FactorScore],
        credits: (gust: Double, wind: Double, precip: Double,
                  humidity: Double, temp: Double, sky: Double)
    ) -> String {
        if let gate = gates.first {
            switch gate {
            case .windAboveAircraftLimit:
                return "Gusts \(Self.mph(c.gustMph)) mph ≥ \(profile.shortName) limit \(Self.mph(gustLimit)) mph"
            case .activePrecipitation:
                return "Precipitation falling — no DJI drone is weatherproof"
            case .severeWeatherAlert:
                return "Alert: \(c.severeAlert ?? "severe weather")"
            case .lowVisibility:
                return "Visibility \(Self.mph(c.visibilityMiles)) SM below 3 SM"
            case .temperatureOutOfRange:
                return "\(Int(c.tempF.rounded()))°F outside \(profile.shortName) operating range"
            }
        }
        /// "nearing 30% limit", "at your 30% limit", "over your 30% limit".
        func relation(_ value: Double, _ limit: Double) -> String {
            value > limit ? "over your" : value == limit ? "at your" : "nearing"
        }
        // Lowest-credit factor drives the message.
        let ranked: [(String, Double)] = [
            ("Gusts \(Self.mph(c.gustMph)) mph nearing \(Self.mph(gustLimit)) mph limit", credits.gust),
            ("Sustained wind \(Self.mph(c.windMph)) mph elevated", credits.wind),
            ("Rain chance \(Int(c.precipChancePercent))% "
                + "\(relation(c.precipChancePercent, thresholds.maxPrecipChancePercent)) "
                + "\(Int(thresholds.maxPrecipChancePercent))% limit", credits.precip),
            ("Humidity \(Int(c.humidityPercent))% "
                + "\(relation(c.humidityPercent, thresholds.maxHumidityPercent)) "
                + "\(Int(thresholds.maxHumidityPercent))% limit", credits.humidity),
            ("Temperature \(Int(c.tempF.rounded()))°F outside the comfort band", credits.temp),
            ("Low ceiling / reduced visibility", credits.sky),
        ]
        let worst = ranked.min(by: { $0.1 < $1.1 })
        if verdict == .go {
            // GO can still sit exactly on a limit (e.g. humidity 75% with a
            // 75% threshold) — name it rather than claim everything is within.
            if let worst, worst.1 <= 0 { return worst.0 }
            return "All factors within your limits"
        }
        if let worst, worst.1 < 0.999 {
            return worst.0
        }
        return flags.first?.label ?? "Marginal conditions"
    }

    /// "20" for whole numbers, "17.9" otherwise.
    static func mph(_ value: Double) -> String {
        value == value.rounded()
            ? String(Int(value))
            : String(format: "%.1f", value)
    }
}

// MARK: - Forecast horizon

/// Normalizes whatever a provider hands back into the one horizon the rest
/// of the app expects: the current hour plus the next twelve, in order.
///
/// Providers disagree about where their hourly series starts — Open-Meteo
/// can return rows from the top of the UTC day, WeatherKit from the last
/// completed hour — and an already-elapsed row at the front would shift the
/// whole window strip and poison "now" readings taken from `hours.first`.
enum ForecastWindow {
    /// Current hour + next 12.
    static let defaultLimit = 13

    static func upcoming(_ hours: [HourConditions],
                         from now: Date = .now,
                         limit: Int = ForecastWindow.defaultLimit,
                         calendar: Calendar = .current) -> [HourConditions] {
        let cutoff = calendar.dateInterval(of: .hour, for: now)?.start ?? now
        let ordered = hours
            .filter { $0.date >= cutoff }
            .sorted { $0.date < $1.date }
        return Array(ordered.prefix(limit))
    }
}

// MARK: - Best-window finder

enum WindowFinder {
    /// Longest consecutive run of GO hours; earliest wins ties.
    /// Interval end is the start of the hour after the last GO hour.
    static func bestGoWindow(_ hours: [(Date, Verdict)]) -> DateInterval? {
        var best: (start: Int, length: Int)?
        var runStart: Int?

        for (index, pair) in hours.enumerated() {
            if pair.1 == .go {
                if runStart == nil { runStart = index }
            } else if let start = runStart {
                let length = index - start
                if length > (best?.length ?? 0) { best = (start, length) }
                runStart = nil
            }
        }
        if let start = runStart {
            let length = hours.count - start
            if length > (best?.length ?? 0) { best = (start, length) }
        }
        guard let best, best.length >= 1 else { return nil }
        return DateInterval(start: hours[best.start].0,
                            duration: TimeInterval(best.length) * 3600)
    }
}
