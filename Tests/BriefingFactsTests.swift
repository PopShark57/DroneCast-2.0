//
//  BriefingFactsTests.swift
//  DroneCastTests
//
//  BriefingFacts must be a faithful, pre-formatted copy of engine output —
//  nothing computed that the engine didn't compute.
//

import Testing
import Foundation

struct BriefingFactsTests {

    @Test func factsCopyTheEngineVerdictScoreAndBindingFactor() {
        let verdict = Fixture.verdict(.caution)
        let facts = Fixture.facts(.caution)

        #expect(facts.verdict == verdict.verdict)
        #expect(facts.verdict == .caution)
        #expect(facts.score == verdict.score)
        #expect(facts.primaryFactor == verdict.bindingFactor)
        #expect(facts.aircraftID == DroneProfile.neo2.id)
        #expect(facts.aircraftName == "DJI Neo 2")
    }

    @Test func windIsFormattedExactlyLikeTheFactorScreen() {
        let facts = Fixture.facts(.caution)
        #expect(facts.wind.gustMph == "19")
        #expect(facts.wind.sustainedMph == "4")
        #expect(facts.wind.gustLimitMph == "20")
        #expect(facts.wind.gustLimitSetBy == "pilot threshold")
    }

    @Test func perAircraftClampIsCarriedThrough() {
        // Neo is rated 17.9 mph — the aircraft, not the pilot, sets the limit.
        let facts = Fixture.facts(.noGoGate)
        #expect(facts.wind.gustLimitMph == "17.9")
        #expect(facts.wind.gustLimitSetBy == "aircraft rating")
        #expect(facts.verdict == .noGo)
        #expect(facts.score == 0)
        #expect(facts.headlineReason == HardGate.windAboveAircraftLimit.briefingReason)
    }

    @Test func precipitationTemperatureAndVisibility() {
        let facts = Fixture.facts(.go, mutate: {
            $0.precipChancePercent = 12; $0.tempC = -5; $0.visibilityMiles = 4.5
        })
        #expect(facts.precipitation.chancePercent == "12")
        #expect(facts.precipitation.chanceLimitPercent == "30")
        #expect(facts.precipitation.fallingNow == false)
        #expect(facts.temperatureF == "23")
        #expect(facts.visibilityMiles == "4.5")
    }

    @Test func gatesAndFlagsBeyondTheBindingFactorAreListed() {
        let facts = Fixture.facts(.go, mutate: { $0.isPrecipitating = true; $0.visibilityMiles = 2 })
        #expect(facts.verdict == .noGo)
        #expect(facts.otherFactors.contains(HardGate.activePrecipitation.label))
        #expect(facts.otherFactors.contains(HardGate.lowVisibility.label))
        #expect(!facts.otherFactors.contains(facts.primaryFactor))
    }

    @Test func bestWindowUsesTheInjectedCalendarAndLocale() {
        #expect(Fixture.facts(.go).bestWindow == "2 PM – 5 PM")
        #expect(Fixture.facts(.go, window: nil).bestWindow == nil)
        #expect(Fixture.facts(.go).windowHorizonHours == "12")
    }

    @Test func dataSourceFollowsTheProvider() {
        #expect(BriefingFacts.DataSource(providerName: "Open-Meteo") == .openMeteo)
        #expect(BriefingFacts.DataSource(providerName: "Apple Weather") == .weatherKit)
        let facts = Fixture.facts(.go, mutate: { $0.providerName = "Apple Weather" })
        #expect(facts.dataSource == .weatherKit)
    }

    @Test func snapshotTimestampIsNotAFact() {
        // Re-fetching identical weather must hit the briefing cache.
        let early = Fixture.facts(.go)
        let later = Fixture.facts(.go, mutate: { $0.timestamp = Fixture.base.addingTimeInterval(600) })
        #expect(early == later)
    }

    @Test func changedWeatherChangesTheFacts() {
        #expect(Fixture.facts(.go) != Fixture.facts(.go, mutate: { $0.gustMph = 8 }))
    }

    @Test func factsRebuiltFromPersistedStateMatchTheLiveOnes() {
        let snapshot = Fixture.Scenario.caution.snapshot
        let verdict = Fixture.verdict(.caution)
        let hours = (0..<4).map { offset in
            HourVerdict(date: Fixture.base.addingTimeInterval(Double(offset) * 3600),
                        verdict: offset < 3 ? .go : .noGo, score: 90,
                        gustMph: 7, precipChancePercent: 5)
        }
        let state = PersistedState(snapshot: snapshot, hourly: [], verdict: verdict,
                                   hourlyVerdicts: hours, profileID: DroneProfile.neo2.id,
                                   thresholds: .standard)
        let fromState = BriefingFacts(state: state, calendar: Fixture.utc, locale: Fixture.posix)
        #expect(fromState == Fixture.facts(.caution))
    }

    @Test func jsonIsStructuredAndRoundTrips() throws {
        let facts = Fixture.facts(.noGoGate)
        let json = try facts.jsonString()
        #expect(json.contains(#""verdict":"NO-GO""#))
        #expect(json.contains(#""gustLimitMph":"17.9""#))
        let decoded = try JSONDecoder().decode(BriefingFacts.self, from: Data(json.utf8))
        #expect(decoded == facts)
    }

    @Test func numberInventory() {
        let facts = Fixture.facts(.noGoGate)
        #expect(facts.allowedNumbers.isSuperset(of: ["19", "17.9", "0", "2", "5", "12"]))
        #expect(!facts.allowedNumbers.contains("18"))
        #expect(facts.requiredNumbers == ["19", "17.9"])
        // No number in "All factors within your limits" → the score is required.
        let go = Fixture.facts(.go)
        #expect(go.requiredNumbers == ["\(go.score)"])
    }

    @Test func numberExtraction() {
        #expect(BriefingNumbers.extract("Gusts 19 mph ≥ NEO limit 17.9 mph.") == ["19", "17.9"])
        #expect(BriefingNumbers.extract("-5°F and −5°F") == ["-5", "-5"])
        #expect(BriefingNumbers.extract("2-5 PM") == ["2", "5"])
        #expect(BriefingNumbers.extract("DJI Air 3S, NEO2") == ["3", "2"])
        #expect(BriefingNumbers.extract("no digits").isEmpty)
    }
}
