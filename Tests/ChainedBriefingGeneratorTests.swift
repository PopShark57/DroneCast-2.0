//
//  ChainedBriefingGeneratorTests.swift
//  DroneCastTests
//
//  Claude → iPhone → template ordering, without a network or a phone.
//

import Testing
import Foundation

@MainActor
struct ChainedBriefingGeneratorTests {

    private let facts = Fixture.facts(.caution)

    private func good(_ provider: BriefingModelSource) -> @Sendable (BriefingFacts) throws -> BriefingDraft {
        { facts in
            var draft = BriefingTemplate.draft(for: facts)
            draft.provider = provider
            return draft
        }
    }

    private let flippedVerdict: @Sendable (BriefingFacts) throws -> BriefingDraft = { facts in
        var draft = BriefingTemplate.draft(for: facts)
        draft.headline = "GO · all clear"
        return draft
    }

    @Test func firstAvailableLinkWins() async throws {
        let claude = MockGenerator(output: good(.claude))
        let phone = MockGenerator(output: good(.iPhone))
        let draft = try await ChainedBriefingGenerator([claude, phone]).generate(from: facts)

        #expect(draft.provider == .claude)
        #expect(await phone.calls.count == 0)
    }

    @Test func unavailableLinkIsSkippedWithoutBeingCalled() async throws {
        let claude = MockGenerator(availabilityResult: .unavailable(.missingAPIKey), output: good(.claude))
        let phone = MockGenerator(output: good(.iPhone))
        let draft = try await ChainedBriefingGenerator([claude, phone]).generate(from: facts)

        #expect(draft.provider == .iPhone)
        #expect(await claude.calls.count == 0)
    }

    @Test func failingLinkFallsThroughToNext() async throws {
        let claude = MockGenerator(output: { _ in throw MockModelError.boom })
        let phone = MockGenerator(output: good(.iPhone))
        let draft = try await ChainedBriefingGenerator([claude, phone]).generate(from: facts)

        #expect(draft.provider == .iPhone)
        #expect(await claude.calls.count == 1)
    }

    @Test func guardRejectedTextGivesTheNextLinkATurn() async throws {
        let claude = MockGenerator(output: flippedVerdict)
        let phone = MockGenerator(output: good(.iPhone))
        let draft = try await ChainedBriefingGenerator([claude, phone]).generate(from: facts)

        #expect(draft.provider == .iPhone)
    }

    @Test func allRejectedReturnsFirstRejectedSoTheServiceRecordsIt() async throws {
        let claude = MockGenerator(output: flippedVerdict)
        let phone = MockGenerator(output: flippedVerdict)
        let draft = try await ChainedBriefingGenerator([claude, phone]).generate(from: facts)

        #expect(draft.headline == "GO · all clear")
        #expect(await phone.calls.count == 1)
    }

    @Test func allFailingThrowsLastError() async {
        let claude = MockGenerator(output: { _ in throw MockModelError.boom })
        let phone = MockGenerator(output: { _ in throw ClaudeBriefingError.noText })
        await #expect(throws: ClaudeBriefingError.noText) {
            try await ChainedBriefingGenerator([claude, phone]).generate(from: facts)
        }
    }

    @Test func availabilityPrefersAReachabilityReasonOverNotSetUp() async {
        let claude = MockGenerator(availabilityResult: .unavailable(.missingAPIKey))
        let phone = MockGenerator(availabilityResult: .unavailable(.phoneUnreachable))
        #expect(await ChainedBriefingGenerator([claude, phone]).availability()
                == .unavailable(.phoneUnreachable))
    }

    @Test func availabilityReportsFirstReasonWhenNothingIsSetUp() async {
        let claude = MockGenerator(availabilityResult: .unavailable(.missingAPIKey))
        let phone = MockGenerator(availabilityResult: .unavailable(.phoneAppMissing))
        #expect(await ChainedBriefingGenerator([claude, phone]).availability()
                == .unavailable(.missingAPIKey))
    }

    @Test func serviceTagsBriefingWithProvider() async {
        let phone = MockGenerator(output: good(.iPhone))
        let service = BriefingService(
            generator: ChainedBriefingGenerator([
                MockGenerator(availabilityResult: .unavailable(.missingAPIKey)), phone]),
            defaults: Fixture.defaults())
        let briefing = await service.briefing(for: facts, snapshotTimestamp: Fixture.base, aiEnabled: true)

        #expect(briefing.source == .ai)
        #expect(briefing.provider == .iPhone)
    }

    @Test func briefingCachedBeforeProviderFieldStillDecodes() throws {
        let template = BriefingTemplate.briefing(for: facts, snapshotTimestamp: Fixture.base, reason: nil)
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(template)) as! [String: Any]
        json.removeValue(forKey: "provider")
        let decoded = try JSONDecoder().decode(
            Briefing.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.provider == nil)
        #expect(decoded.headline == template.headline)
    }
}
