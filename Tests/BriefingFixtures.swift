//
//  BriefingFixtures.swift
//  DroneCastTests
//
//  Shared scenarios for the briefing tests. Every fact comes from the real
//  FlightScorer — the tests never hand-write engine output.
//

import Foundation

enum Fixture {

    /// Fixed zone + locale so window strings don't depend on the test host.
    static var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }
    static let posix = Locale(identifier: "en_US_POSIX")

    /// 2025-06-15 14:00:00 UTC — an exact hour boundary.
    static let base = Date(timeIntervalSince1970: 1_749_996_000)

    /// Calm baseline: 72 °F, 45 % RH, 5 % rain, 4 mph wind / 7 mph gusts,
    /// 20 % cloud, 10 SM.
    static func conditions(provider: String = "Open-Meteo",
                           _ mutate: (inout ConditionsSnapshot) -> Void = { _ in }) -> ConditionsSnapshot {
        var conditions = ConditionsSnapshot(
            timestamp: base, tempC: 22, humidityPercent: 45,
            precipChancePercent: 5, isPrecipitating: false,
            windMph: 4, gustMph: 7, windDirectionDegrees: 270,
            cloudCoverPercent: 20, visibilityMiles: 10,
            severeAlert: nil, providerName: provider)
        mutate(&conditions)
        return conditions
    }

    /// The four verdict shapes the templates have to cover.
    enum Scenario: String, CaseIterable, Sendable {
        case go                 // calm day
        case caution            // 19 mph gusts on a Neo 2 (limit 20)
        case noGoGate           // 19 mph gusts on a Neo (limit 17.9)
        case noGoScore          // no gate, score < 50

        var profile: DroneProfile {
            self == .noGoGate ? .neo : .neo2
        }

        var snapshot: ConditionsSnapshot {
            switch self {
            case .go:
                return Fixture.conditions()
            case .caution, .noGoGate:
                return Fixture.conditions { $0.gustMph = 19 }
            case .noGoScore:
                return Fixture.conditions {
                    $0.windMph = 15; $0.gustMph = 16
                    $0.precipChancePercent = 29; $0.humidityPercent = 74
                    $0.cloudCoverPercent = 100
                }
            }
        }

        var expectedVerdict: Verdict {
            switch self {
            case .go:                   return .go
            case .caution:              return .caution
            case .noGoGate, .noGoScore: return .noGo
            }
        }
    }

    static func verdict(_ scenario: Scenario,
                        thresholds: UserThresholds = .standard) -> FlightVerdict {
        FlightScorer(thresholds: thresholds).evaluate(scenario.snapshot, profile: scenario.profile)
    }

    /// A 2 PM – 5 PM UTC window unless told otherwise.
    static func facts(_ scenario: Scenario,
                      window: DateInterval? = DateInterval(start: base, duration: 3 * 3600),
                      mutate: ((inout ConditionsSnapshot) -> Void)? = nil) -> BriefingFacts {
        var snapshot = scenario.snapshot
        mutate?(&snapshot)
        let verdict = FlightScorer(thresholds: .standard).evaluate(snapshot, profile: scenario.profile)
        return BriefingFacts(verdict: verdict, snapshot: snapshot,
                             profile: scenario.profile, thresholds: .standard,
                             bestWindow: window, calendar: utc, locale: posix)
    }

    /// An isolated defaults suite per test, so cache tests can't collide.
    static func defaults() -> UserDefaults {
        let name = "DroneCastTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }
}

// MARK: - Mock model

enum MockModelError: Error, Equatable {
    case boom
}

actor CallCounter {
    private(set) var count = 0
    func increment() { count += 1 }
}

/// Stand-in for the Private Cloud Compute generator.
struct MockGenerator: BriefingGenerating {
    var availabilityResult: BriefingModelAvailability = .available
    /// Given the facts, what the "model" writes. Defaults to the template —
    /// i.e. a perfectly well-behaved model.
    var output: @Sendable (BriefingFacts) throws -> BriefingDraft = { BriefingTemplate.draft(for: $0) }
    var delay: Duration?
    let calls = CallCounter()

    func availability() async -> BriefingModelAvailability { availabilityResult }

    func generate(from facts: BriefingFacts) async throws -> BriefingDraft {
        await calls.increment()
        if let delay { try await Task.sleep(for: delay) }
        return try output(facts)
    }
}
