//
//  BriefingServiceTests.swift
//  DroneCastTests
//
//  The whole pipeline against a mock model: availability handling, errors,
//  timeouts, caching, and the user toggle. No device, no network.
//

import Testing
import Foundation

@MainActor
struct BriefingServiceTests {

    private let facts = Fixture.facts(.caution)

    private func makeService(_ generator: MockGenerator?,
                         defaults: UserDefaults = Fixture.defaults(),
                         timeout: Duration = .seconds(5)) -> BriefingService {
        BriefingService(generator: generator, defaults: defaults, timeout: timeout)
    }

    // MARK: Happy path

    @Test func guardApprovedOutputIsUsedAndMarkedAI() async {
        let draft = BriefingDraft(
            headline: "CAUTION · gusts near limit",
            detail: "Gusts of 19 mph are close to the 20 mph limit for the DJI Neo 2.",
            window: "Best window 2 PM – 5 PM")
        let briefing = await makeService(MockGenerator(output: { _ in draft }))
            .briefing(for: facts, snapshotTimestamp: Fixture.base, aiEnabled: true)

        #expect(briefing.source == .ai)
        #expect(briefing.fallbackReason == nil)
        #expect(briefing.headline == draft.headline)
        #expect(briefing.detail == draft.detail)
        #expect(briefing.verdict == .caution)   // from the engine, not the text
    }

    // MARK: Availability — checked before every use

    @Test(arguments: [BriefingModelAvailability.Reason.deviceNotEligible,
                      .systemNotReady, .quotaReached, .unknown])
    func unavailableModelFallsBackWithoutBeingCalled(_ reason: BriefingModelAvailability.Reason) async {
        let generator = MockGenerator(availabilityResult: .unavailable(reason))
        let briefing = await makeService(generator)
            .briefing(for: facts, snapshotTimestamp: Fixture.base, aiEnabled: true)

        #expect(briefing.source == .template)
        #expect(briefing.fallbackReason == .modelUnavailable(reason))
        #expect(await generator.calls.count == 0)
    }

    @Test func noGeneratorMeansNotConfigured() async {
        let briefing = await makeService(nil)
            .briefing(for: facts, snapshotTimestamp: Fixture.base, aiEnabled: true)
        #expect(briefing.source == .template)
        #expect(briefing.fallbackReason == .modelUnavailable(.notConfigured))
    }

    @Test func userToggleOffNeverCallsTheModel() async {
        let generator = MockGenerator()
        let briefing = await makeService(generator)
            .briefing(for: facts, snapshotTimestamp: Fixture.base, aiEnabled: false)
        #expect(briefing.source == .template)
        #expect(briefing.fallbackReason == .disabledByUser)
        #expect(await generator.calls.count == 0)
    }

    // MARK: Errors and timeouts

    @Test func modelErrorFallsBack() async {
        let generator = MockGenerator(output: { _ in throw MockModelError.boom })
        let briefing = await makeService(generator)
            .briefing(for: facts, snapshotTimestamp: Fixture.base, aiEnabled: true)
        #expect(briefing.source == .template)
        guard case .generationFailed? = briefing.fallbackReason else {
            Issue.record("expected generationFailed, got \(String(describing: briefing.fallbackReason))")
            return
        }
    }

    @Test func slowModelTimesOut() async {
        let generator = MockGenerator(delay: .seconds(30))
        let started = ContinuousClock.now
        let briefing = await makeService(generator, timeout: .milliseconds(100))
            .briefing(for: facts, snapshotTimestamp: Fixture.base, aiEnabled: true)
        #expect(briefing.source == .template)
        #expect(briefing.fallbackReason == .timedOut)
        #expect(ContinuousClock.now - started < .seconds(10))
    }

    // MARK: Caching

    @Test func sameFactsDoNotRegenerate() async {
        let defaults = Fixture.defaults()
        let generator = MockGenerator()
        let service = makeService(generator, defaults: defaults)

        let first = await service.briefing(for: facts, snapshotTimestamp: Fixture.base, aiEnabled: true)
        let later = Fixture.base.addingTimeInterval(600)
        let second = await service.briefing(for: facts, snapshotTimestamp: later, aiEnabled: true)

        #expect(await generator.calls.count == 1)
        #expect(first.source == .ai)
        #expect(second.headline == first.headline)
        #expect(second.snapshotTimestamp == later)   // freshness follows the snapshot
    }

    @Test func changedFactsRegenerate() async {
        let generator = MockGenerator()
        let service = makeService(generator)
        _ = await service.briefing(for: facts, snapshotTimestamp: Fixture.base, aiEnabled: true)
        let windier = Fixture.facts(.caution, mutate: { $0.gustMph = 19.5 })
        _ = await service.briefing(for: windier, snapshotTimestamp: Fixture.base, aiEnabled: true)
        #expect(await generator.calls.count == 2)
    }

    @Test func cacheIsPerAircraft() async {
        let defaults = Fixture.defaults()
        let generator = MockGenerator()
        let service = makeService(generator, defaults: defaults)
        let neo = Fixture.facts(.noGoGate)

        _ = await service.briefing(for: facts, snapshotTimestamp: Fixture.base, aiEnabled: true)
        _ = await service.briefing(for: neo, snapshotTimestamp: Fixture.base, aiEnabled: true)
        _ = await service.briefing(for: facts, snapshotTimestamp: Fixture.base, aiEnabled: true)

        #expect(await generator.calls.count == 2)
        #expect(BriefingStore.entry(forProfile: DroneProfile.neo2.id, in: defaults)?.facts == facts)
        #expect(BriefingStore.entry(forProfile: DroneProfile.neo.id, in: defaults)?.facts == neo)
    }

    @Test func guardRejectionIsNotRetriedForTheSameFacts() async {
        let generator = MockGenerator(output: { _ in
            BriefingDraft(headline: "GO · fine", detail: "Fly.", window: "Now")
        })
        let service = makeService(generator)
        _ = await service.briefing(for: facts, snapshotTimestamp: Fixture.base, aiEnabled: true)
        let again = await service.briefing(for: facts, snapshotTimestamp: Fixture.base, aiEnabled: true)
        #expect(await generator.calls.count == 1)
        #expect(again.source == .template)
    }

    @Test func transientUnavailabilityIsRetriedOnceTheModelIsBack() async {
        let defaults = Fixture.defaults()
        _ = await makeService(MockGenerator(availabilityResult: .unavailable(.systemNotReady)),
                          defaults: defaults)
            .briefing(for: facts, snapshotTimestamp: Fixture.base, aiEnabled: true)

        let recovered = MockGenerator()
        let briefing = await makeService(recovered, defaults: defaults)
            .briefing(for: facts, snapshotTimestamp: Fixture.base, aiEnabled: true)
        #expect(await recovered.calls.count == 1)
        #expect(briefing.source == .ai)
    }

    // MARK: Immediate briefing (what the UI and widget see first)

    @Test func immediateBriefingIsTheTemplateAndIsPersisted() {
        let defaults = Fixture.defaults()
        let briefing = makeService(MockGenerator(), defaults: defaults)
            .immediateBriefing(for: facts, snapshotTimestamp: Fixture.base, aiEnabled: true)
        #expect(briefing.source == .template)
        #expect(BriefingStore.entry(forProfile: facts.aircraftID, in: defaults)?.briefing == briefing)
    }

    @Test func immediateBriefingReusesACachedAIBriefing() async {
        let defaults = Fixture.defaults()
        let service = makeService(MockGenerator(), defaults: defaults)
        let ai = await service.briefing(for: facts, snapshotTimestamp: Fixture.base, aiEnabled: true)
        let immediate = service.immediateBriefing(
            for: facts, snapshotTimestamp: Fixture.base, aiEnabled: true)
        #expect(ai.source == .ai)
        #expect(immediate == ai)
    }

    @Test func toggleOffReplacesACachedAIBriefingWithTheTemplate() async {
        let defaults = Fixture.defaults()
        let service = makeService(MockGenerator(), defaults: defaults)
        _ = await service.briefing(for: facts, snapshotTimestamp: Fixture.base, aiEnabled: true)
        let off = service.immediateBriefing(for: facts, snapshotTimestamp: Fixture.base, aiEnabled: false)
        #expect(off.source == .template)
        #expect(off.fallbackReason == .disabledByUser)
    }

    @Test func aiAndTemplateBriefingsShareTheSameShape() async {
        // The UI renders both identically; only `source` differs.
        let service = makeService(MockGenerator())
        let ai = await service.briefing(for: facts, snapshotTimestamp: Fixture.base, aiEnabled: true)
        let template = BriefingTemplate.briefing(for: facts, snapshotTimestamp: Fixture.base, reason: nil)
        #expect(ai.source == .ai)
        #expect(template.source == .template)
        #expect(ai.headline == template.headline)   // mock model echoes the template
        #expect(ai.verdict == template.verdict)
    }
}

// MARK: - Siri answer

struct BriefingAnswerTests {

    private func state(timestamp: Date = Fixture.base,
                       aiEnabled: Bool? = nil) -> PersistedState {
        var snapshot = Fixture.Scenario.caution.snapshot
        snapshot.timestamp = timestamp
        return PersistedState(snapshot: snapshot, hourly: [],
                              verdict: Fixture.verdict(.caution), hourlyVerdicts: [],
                              profileID: DroneProfile.neo2.id, thresholds: .standard,
                              aiBriefingEnabled: aiEnabled)
    }

    private func answer(_ state: PersistedState?, cache: [String: BriefingCacheEntry] = [:],
                        now: Date = Fixture.base.addingTimeInterval(60)) -> String {
        BriefingAnswer.text(state: state, cache: cache, now: now,
                            calendar: Fixture.utc, locale: Fixture.posix)
    }

    @Test func noStateSaysSo() {
        #expect(answer(nil) == BriefingAnswer.noData)
    }

    @Test func freshStateReadsTheTemplate() {
        let text = answer(state())
        #expect(text.hasPrefix("CAUTION · score"))
        #expect(text.contains("Gusts 19 mph nearing 20 mph limit."))
        #expect(!text.contains("minutes ago"))
    }

    @Test func staleStateSaysHowOld() {
        let text = answer(state(), now: Fixture.base.addingTimeInterval(45 * 60))
        #expect(text.hasSuffix("This is from 45 minutes ago."))
    }

    @Test func expiredStateRefusesToAnswer() {
        let text = answer(state(), now: Fixture.base.addingTimeInterval(3 * 3600))
        #expect(text.contains("over 2 hours old"))
        #expect(!text.contains("CAUTION"))
    }

    @Test func matchingCachedBriefingIsUsed() {
        let facts = BriefingFacts(state: state(), calendar: Fixture.utc, locale: Fixture.posix)!
        let cached = Briefing(headline: "CAUTION · gusts near limit",
                              detail: "Gusts 19 mph, limit 20 mph.", window: "No clear window",
                              source: .ai, fallbackReason: nil, verdict: .caution,
                              profileID: facts.aircraftID, snapshotTimestamp: Fixture.base)
        let cache = [facts.aircraftID: BriefingCacheEntry(facts: facts, briefing: cached, modelSettled: true)]
        #expect(answer(state(), cache: cache).hasPrefix("CAUTION · gusts near limit."))
        // Toggle off → template even with an AI briefing cached.
        #expect(answer(state(aiEnabled: false), cache: cache).hasPrefix("CAUTION · score"))
    }
}
