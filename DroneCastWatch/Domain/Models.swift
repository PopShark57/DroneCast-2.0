//
//  Models.swift
//  DroneCast — Domain layer (compiled into app, widget, and test targets)
//
//  Pure value types. No I/O, no framework dependencies beyond Foundation
//  (plus an optional SwiftUI color extension at the bottom).
//

import Foundation

// MARK: - Aircraft profiles

/// Manufacturer limits verified July 2026:
///   Air 3S  — 12 m/s ≈ 26.8 mph, −10…40 °C, 724 g
///   Neo     —  8 m/s ≈ 17.9 mph (Level 4), −10…40 °C, 135 g
///   Neo 2   — 10.7 m/s ≈ 23.9 mph (Level 5), −10…40 °C, 151 g
struct DroneProfile: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let name: String
    /// Short label for complications ("A3S", "NEO2", …)
    let shortName: String
    /// Manufacturer max wind resistance, mph.
    let maxWindMph: Double
    let minTempC: Double
    let maxTempC: Double
    /// Multiplier applied to `maxWindMph` before clamping against the user
    /// threshold. 1.0 for GPS camera flying; 0.85 for FPV practice, where
    /// low-altitude turbulence near obstacles deserves extra margin.
    let gustMarginFactor: Double
    /// FPV only — high humidity + cold air fogs the Goggles N3 lens.
    let checksGoggleFog: Bool
    /// FPV only — gusts at or above this value raise a caution flag even
    /// when below the hard limit.
    let fpvCautionGustMph: Double?

    static let air3s = DroneProfile(
        id: "air3s", name: "DJI Air 3S", shortName: "A3S",
        maxWindMph: 26.8, minTempC: -10, maxTempC: 40,
        gustMarginFactor: 1.0, checksGoggleFog: false, fpvCautionGustMph: nil)

    static let neo = DroneProfile(
        id: "neo", name: "DJI Neo", shortName: "NEO",
        maxWindMph: 17.9, minTempC: -10, maxTempC: 40,
        gustMarginFactor: 1.0, checksGoggleFog: false, fpvCautionGustMph: nil)

    static let neo2 = DroneProfile(
        id: "neo2", name: "DJI Neo 2", shortName: "NEO2",
        maxWindMph: 23.9, minTempC: -10, maxTempC: 40,
        gustMarginFactor: 1.0, checksGoggleFog: false, fpvCautionGustMph: nil)

    /// Neo 2 airframe flown manual/acro with Goggles N3 + FPV Controller 3.
    static let fpvPractice = DroneProfile(
        id: "fpv", name: "FPV Practice", shortName: "FPV",
        maxWindMph: 23.9, minTempC: -10, maxTempC: 40,
        gustMarginFactor: 0.85, checksGoggleFog: true, fpvCautionGustMph: 15)

    static let fleet: [DroneProfile] = [.air3s, .neo, .neo2, .fpvPractice]

    static func profile(id: String) -> DroneProfile {
        fleet.first { $0.id == id } ?? .neo2
    }
}

// MARK: - User thresholds

struct UserThresholds: Codable, Equatable, Sendable {
    var maxHumidityPercent: Double
    var maxPrecipChancePercent: Double
    var maxGustMph: Double

    /// Personal defaults: humidity < 75 %, rain chance < 30 %, gusts < 20 mph.
    static let standard = UserThresholds(
        maxHumidityPercent: 75,
        maxPrecipChancePercent: 30,
        maxGustMph: 20)
}

// MARK: - Weather models (provider-normalized units)

struct ConditionsSnapshot: Codable, Equatable, Sendable {
    var timestamp: Date
    var tempC: Double
    var humidityPercent: Double        // 0–100
    var precipChancePercent: Double    // 0–100, current-hour forecast
    var isPrecipitating: Bool          // precip falling right now
    var windMph: Double
    var gustMph: Double                // == windMph when provider omits gusts
    var windDirectionDegrees: Double?
    var cloudCoverPercent: Double      // 0–100
    var visibilityMiles: Double        // statute miles
    var severeAlert: String?           // active severe/extreme alert summary
    var providerName: String

    var tempF: Double { tempC * 9 / 5 + 32 }
}

struct HourConditions: Codable, Equatable, Sendable, Identifiable {
    var id: Date { date }
    var date: Date
    var tempC: Double
    var humidityPercent: Double
    var precipChancePercent: Double
    var isPrecipitating: Bool
    var windMph: Double
    var gustMph: Double
    var cloudCoverPercent: Double
    var visibilityMiles: Double

    /// Bridge an hourly row through the same scoring engine as "now".
    func asSnapshot(provider: String, alert: String?) -> ConditionsSnapshot {
        ConditionsSnapshot(
            timestamp: date, tempC: tempC,
            humidityPercent: humidityPercent,
            precipChancePercent: precipChancePercent,
            isPrecipitating: isPrecipitating,
            windMph: windMph, gustMph: gustMph,
            windDirectionDegrees: nil,
            cloudCoverPercent: cloudCoverPercent,
            visibilityMiles: visibilityMiles,
            severeAlert: alert, providerName: provider)
    }
}

// MARK: - Verdict types

enum Verdict: String, Codable, Sendable {
    case go = "GO"
    case caution = "CAUTION"
    case noGo = "NO-GO"

    /// VoiceOver reads "NO-GO" as "no dash go"; spell it out instead.
    var spokenLabel: String {
        switch self {
        case .go:      return "Go"
        case .caution: return "Caution"
        case .noGo:    return "No go"
        }
    }
}

enum HardGate: String, Codable, Sendable, CaseIterable, Equatable {
    case activePrecipitation
    case windAboveAircraftLimit
    case temperatureOutOfRange
    case severeWeatherAlert
    case lowVisibility

    var label: String {
        switch self {
        case .activePrecipitation:    return "Active precipitation"
        case .windAboveAircraftLimit: return "Wind at or above aircraft limit"
        case .temperatureOutOfRange:  return "Temperature outside operating range"
        case .severeWeatherAlert:     return "Severe weather alert"
        case .lowVisibility:          return "Visibility below 3 SM"
        }
    }
}

enum CautionFlag: String, Codable, Sendable, Hashable {
    case goggleFog
    case coldBattery
    case sustainedWindHigh
    case fpvGustBand
    /// Above the pilot's own humidity threshold — caps the verdict at CAUTION.
    case humidityOverLimit
    /// Above the pilot's own rain-chance threshold — caps the verdict at CAUTION.
    case rainChanceOverLimit

    var label: String {
        switch self {
        case .goggleFog:         return "Goggles N3 may fog (humid + cold)"
        case .coldBattery:       return "Cold LiPo — hover 30–60 s, expect shorter flights"
        case .sustainedWindHigh: return "Sustained wind near limit"
        case .fpvGustBand:       return "Gusty for low-altitude acro"
        case .humidityOverLimit:   return "Humidity over your limit"
        case .rainChanceOverLimit: return "Rain chance over your limit"
        }
    }
}

struct FactorScore: Codable, Sendable, Equatable, Identifiable {
    enum Status: String, Codable, Sendable, Equatable {
        case pass, warn, fail

        /// On screen this status is a coloured dot and nothing else.
        var label: String {
            switch self {
            case .pass: return "within limits"
            case .warn: return "near your limit"
            case .fail: return "over your limit"
            }
        }
    }
    var id: String { name }
    let name: String
    let valueText: String
    let limitText: String
    let status: Status
}

struct FlightVerdict: Codable, Sendable, Equatable {
    let verdict: Verdict
    /// 0–100 weighted score. 0 when a hard gate fired.
    let score: Int
    /// Human sentence naming the binding factor.
    let bindingFactor: String
    let gates: [HardGate]
    let flags: [CautionFlag]
    let factors: [FactorScore]
    let profileID: String
    let effectiveGustLimitMph: Double
}

/// Compact per-hour result persisted for the widget timeline.
struct HourVerdict: Codable, Sendable, Equatable, Identifiable {
    var id: Date { date }
    let date: Date
    let verdict: Verdict
    let score: Int
    let gustMph: Double
    let precipChancePercent: Double
}

// MARK: - Freshness policy (app + widget)

/// One definition of "how old is too old", shared by the app and the
/// complication so they can never disagree about what the pilot is looking at.
enum DataFreshness {
    /// Foreground refresh kicks in above this age.
    static let refreshAfter: TimeInterval = 10 * 60
    /// Verdict still shown, badged STALE.
    static let staleAfter: TimeInterval = 30 * 60
    /// Verdict suppressed entirely — a refresh is required.
    static let expiresAfter: TimeInterval = 2 * 60 * 60

    /// Age of a snapshot taken at `timestamp`, or nil when there is none.
    static func age(of timestamp: Date?, now: Date = .now) -> TimeInterval? {
        timestamp.map { now.timeIntervalSince($0) }
    }

    /// Missing data counts as expired, so callers can treat nil as "refresh".
    static func isStale(_ age: TimeInterval?) -> Bool { (age ?? .infinity) > staleAfter }
    static func isExpired(_ age: TimeInterval?) -> Bool { (age ?? .infinity) > expiresAfter }
    static func needsRefresh(_ age: TimeInterval?) -> Bool { (age ?? .infinity) > refreshAfter }
}

// MARK: - SwiftUI color mapping (app + widget)

#if canImport(SwiftUI)
import SwiftUI

extension Verdict {
    var tint: Color {
        switch self {
        case .go:      return .green
        case .caution: return .yellow
        case .noGo:    return .red
        }
    }
}
#endif
