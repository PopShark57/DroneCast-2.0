//
//  BriefingTemplateTests.swift
//  DroneCastTests
//
//  The template is the fallback for every failure, so it has to be right
//  for every verdict — and pass the same guard the model has to pass.
//

import Testing
import Foundation

struct BriefingTemplateTests {

    @Test(arguments: Fixture.Scenario.allCases)
    func scenarioProducesItsVerdict(_ scenario: Fixture.Scenario) {
        #expect(Fixture.facts(scenario).verdict == scenario.expectedVerdict)
    }

    @Test(arguments: Fixture.Scenario.allCases)
    func templatePassesTheHallucinationGuard(_ scenario: Fixture.Scenario) {
        let facts = Fixture.facts(scenario)
        let draft = BriefingTemplate.draft(for: facts)
        #expect(HallucinationGuard.violations(in: draft, for: facts) == [])
    }

    @Test(arguments: Fixture.Scenario.allCases)
    func templatePassesTheGuardWithoutAWindow(_ scenario: Fixture.Scenario) {
        let facts = Fixture.facts(scenario, window: nil)
        let draft = BriefingTemplate.draft(for: facts)
        #expect(HallucinationGuard.violations(in: draft, for: facts) == [])
        #expect(draft.window == "No clear window in the next 12 hours")
    }

    @Test(arguments: Fixture.Scenario.allCases)
    func headlineLeadsWithTheVerdictAndFitsAComplication(_ scenario: Fixture.Scenario) {
        let headline = BriefingTemplate.headline(for: Fixture.facts(scenario))
        #expect(headline.hasPrefix(scenario.expectedVerdict.rawValue + " · "))
        #expect(headline.count <= HallucinationGuard.maxHeadlineLength)
    }

    @Test func goTemplate() {
        let facts = Fixture.facts(.go)
        let draft = BriefingTemplate.draft(for: facts)
        #expect(draft.headline == "GO · within your limits")
        #expect(draft.detail == "DJI Neo 2: all factors within your limits, score \(facts.score). "
                + "Gusts 7 mph against a 20 mph limit.")
        #expect(draft.window == "Best window 2 PM – 5 PM")
    }

    @Test func cautionTemplate() {
        let facts = Fixture.facts(.caution)
        let draft = BriefingTemplate.draft(for: facts)
        #expect(draft.headline == "CAUTION · score \(facts.score)")
        #expect(draft.detail == "DJI Neo 2: marginal, score \(facts.score). "
                + "Gusts 19 mph nearing 20 mph limit.")
    }

    @Test func noGoGateTemplate() {
        let draft = BriefingTemplate.draft(for: Fixture.facts(.noGoGate))
        #expect(draft.headline == "NO-GO · wind over aircraft limit")
        #expect(draft.detail == "DJI Neo: stay grounded, score 0. Gusts 19 mph ≥ NEO limit 17.9 mph.")
    }

    @Test func noGoScoreTemplate() {
        let facts = Fixture.facts(.noGoScore)
        let draft = BriefingTemplate.draft(for: facts)
        #expect(facts.score < 50)
        #expect(draft.headline == "NO-GO · score \(facts.score)")
        #expect(draft.detail.hasPrefix("DJI Neo 2: stay grounded, score \(facts.score). "))
    }

    @Test func severeAlertWindowSaysTheHoursIgnoreIt() {
        let facts = Fixture.facts(.go, mutate: { $0.severeAlert = "High Wind Warning" })
        let draft = BriefingTemplate.draft(for: facts)
        #expect(facts.verdict == .noGo)
        #expect(draft.headline == "NO-GO · severe weather alert")
        #expect(draft.window == "Forecast window 2 PM – 5 PM, alert not included")
        #expect(HallucinationGuard.violations(in: draft, for: facts) == [])
    }

    @Test(arguments: DroneProfile.fleet)
    func everyAircraftAndGateStaysInsideTheGuard(_ profile: DroneProfile) {
        let cases: [(inout ConditionsSnapshot) -> Void] = [
            { _ in },
            { $0.gustMph = 19 },
            { $0.gustMph = 16 },
            { $0.isPrecipitating = true },
            { $0.tempC = -12 },
            { $0.tempC = -5 },
            { $0.visibilityMiles = 2 },
            { $0.humidityPercent = 90; $0.tempC = 5 },
            { $0.windMph = 15; $0.gustMph = 15 },
            { $0.severeAlert = "Wind Advisory" },
            { $0.humidityPercent = 75 },
            { $0.humidityPercent = 80 },
            { $0.precipChancePercent = 30 },
            { $0.precipChancePercent = 35 },
            { $0.humidityPercent = 80; $0.precipChancePercent = 35 },
        ]
        for mutate in cases {
            let snapshot = Fixture.conditions(mutate)
            let verdict = FlightScorer(thresholds: .standard).evaluate(snapshot, profile: profile)
            let facts = BriefingFacts(verdict: verdict, snapshot: snapshot, profile: profile,
                                      thresholds: .standard, bestWindow: nil,
                                      calendar: Fixture.utc, locale: Fixture.posix)
            let draft = BriefingTemplate.draft(for: facts)
            #expect(HallucinationGuard.violations(in: draft, for: facts) == [],
                    "\(profile.id): \(draft)")
        }
    }

    @Test func humidityOverLimitBriefsCautionNotWithinLimits() {
        // Regression: the briefing used to read "GO · within your limits".
        let facts = Fixture.facts(.go, mutate: { $0.humidityPercent = 80 })
        let draft = BriefingTemplate.draft(for: facts)
        #expect(facts.verdict == .caution)
        #expect(draft.headline == "CAUTION · humidity over limit")
        #expect(draft.detail.hasSuffix("Humidity 80% over your 75% limit."))
        #expect(!draft.detail.contains("within your limits"))
        #expect(HallucinationGuard.violations(in: draft, for: facts) == [])
    }

    @Test func goAtALimitNamesItInsteadOfWithinLimits() {
        let facts = Fixture.facts(.go, mutate: { $0.humidityPercent = 75 })
        let draft = BriefingTemplate.draft(for: facts)
        #expect(facts.verdict == .go)
        #expect(draft.headline == "GO · humidity at limit")
        #expect(draft.detail.hasPrefix("DJI Neo 2: humidity 75% at your 75% limit, score "))
        #expect(!draft.headline.contains("within"))
        #expect(HallucinationGuard.violations(in: draft, for: facts) == [])
    }

    @Test func templateBriefingIsMarkedAsTemplate() {
        let briefing = BriefingTemplate.briefing(
            for: Fixture.facts(.caution), snapshotTimestamp: Fixture.base, reason: .timedOut)
        #expect(briefing.source == .template)
        #expect(briefing.fallbackReason == .timedOut)
        #expect(briefing.verdict == .caution)
        #expect(briefing.profileID == DroneProfile.neo2.id)
    }
}
