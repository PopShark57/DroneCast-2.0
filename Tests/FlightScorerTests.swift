//
//  FlightScorerTests.swift
//  DroneCastTests
//
//  Swift Testing (Xcode 16+). The test target compiles the Domain sources
//  directly, so no host app is required — these run on the watch simulator
//  in seconds.
//

import Testing
import Foundation

struct FlightScorerTests {

    let scorer = FlightScorer(thresholds: .standard)

    /// Calm baseline: 72 °F, 45 % RH, 5 % rain, 4 mph wind / 7 mph gusts,
    /// 20 % cloud, 10 SM.
    private func calm(_ mutate: (inout ConditionsSnapshot) -> Void = { _ in }) -> ConditionsSnapshot {
        var conditions = ConditionsSnapshot(
            timestamp: .now, tempC: 22, humidityPercent: 45,
            precipChancePercent: 5, isPrecipitating: false,
            windMph: 4, gustMph: 7, windDirectionDegrees: 270,
            cloudCoverPercent: 20, visibilityMiles: 10,
            severeAlert: nil, providerName: "Test")
        mutate(&conditions)
        return conditions
    }

    // MARK: Baseline

    @Test func calmDayIsGo() {
        let verdict = scorer.evaluate(calm(), profile: .neo2)
        #expect(verdict.verdict == .go)
        #expect(verdict.score >= 95)
        #expect(verdict.gates.isEmpty)
        #expect(verdict.flags.isEmpty)
    }

    // MARK: Per-aircraft gust clamping

    @Test func neoClampsBelowUserGustThreshold() {
        // User allows 20 mph, but the Neo is only rated ~17.9 mph —
        // the aircraft limit must win.
        #expect(scorer.effectiveGustLimit(for: .neo) == 17.9)

        let verdict = scorer.evaluate(calm { $0.gustMph = 19 }, profile: .neo)
        #expect(verdict.verdict == .noGo)
        #expect(verdict.gates.contains(.windAboveAircraftLimit))
    }

    @Test func nineteenGustsAreCautionNotGoOnStrongerAirframes() {
        for profile in [DroneProfile.neo2, .air3s] {
            let verdict = scorer.evaluate(calm { $0.gustMph = 19 }, profile: profile)
            #expect(!verdict.gates.contains(.windAboveAircraftLimit))
            #expect(verdict.verdict == .caution) // heavy gust penalty
        }
    }

    @Test func userThresholdCannotExceedAircraftRating() {
        let permissive = FlightScorer(thresholds: UserThresholds(
            maxHumidityPercent: 75, maxPrecipChancePercent: 30, maxGustMph: 25))
        #expect(permissive.effectiveGustLimit(for: .neo) == 17.9)
        #expect(permissive.effectiveGustLimit(for: .air3s) == 25)
    }

    @Test func gustExactlyAtLimitGates() {
        let verdict = scorer.evaluate(calm { $0.gustMph = 17.9 }, profile: .neo)
        #expect(verdict.verdict == .noGo)
        #expect(verdict.gates.contains(.windAboveAircraftLimit))
    }

    // MARK: Hard gates

    @Test func activePrecipitationHardGates() {
        let verdict = scorer.evaluate(calm { $0.isPrecipitating = true }, profile: .air3s)
        #expect(verdict.verdict == .noGo)
        #expect(verdict.score == 0)
        #expect(verdict.gates == [.activePrecipitation])
    }

    @Test func severeAlertGates() {
        let verdict = scorer.evaluate(
            calm { $0.severeAlert = "High Wind Warning" }, profile: .air3s)
        #expect(verdict.verdict == .noGo)
        #expect(verdict.gates.contains(.severeWeatherAlert))
    }

    @Test func lowVisibilityGates() {
        let verdict = scorer.evaluate(calm { $0.visibilityMiles = 2 }, profile: .neo2)
        #expect(verdict.verdict == .noGo)
        #expect(verdict.gates.contains(.lowVisibility))
    }

    @Test func temperatureFloorGates() {
        let verdict = scorer.evaluate(calm { $0.tempC = -12 }, profile: .neo2)
        #expect(verdict.verdict == .noGo)
        #expect(verdict.gates.contains(.temperatureOutOfRange))
        // Below the operating floor entirely — not merely a cold-battery flag.
        #expect(!verdict.flags.contains(.coldBattery))
    }

    // MARK: Weighted factors & thresholds

    @Test func humidityAtThresholdCostsItsFullWeight() {
        let verdict = scorer.evaluate(calm { $0.humidityPercent = 75 }, profile: .neo2)
        #expect(verdict.gates.isEmpty)
        #expect(verdict.verdict == .go)          // still flyable…
        #expect((88...92).contains(verdict.score)) // …but humidity paid its 10 pts
    }

    // MARK: Personal thresholds cap the verdict

    @Test func humidityAboveThresholdIsNeverGo() {
        // Regression: 80 % humidity on an otherwise calm day scored 90 and
        // showed GO with "All factors within your limits".
        let verdict = scorer.evaluate(calm { $0.humidityPercent = 80 }, profile: .neo2)
        #expect(verdict.verdict == .caution)
        #expect(verdict.flags.contains(.humidityOverLimit))
        #expect(verdict.bindingFactor == "Humidity 80% over your 75% limit")
    }

    @Test func rainChanceAboveThresholdIsNeverGo() {
        let verdict = scorer.evaluate(calm { $0.precipChancePercent = 35 }, profile: .air3s)
        #expect(verdict.verdict == .caution)
        #expect(verdict.flags.contains(.rainChanceOverLimit))
        #expect(verdict.bindingFactor == "Rain chance 35% over your 30% limit")
    }

    @Test func overLimitCapsEveryAircraft() {
        for profile in DroneProfile.fleet {
            let verdict = scorer.evaluate(calm { $0.humidityPercent = 76 }, profile: profile)
            #expect(verdict.verdict != .go, "\(profile.id)")
        }
    }

    @Test func exactlyAtThresholdStaysGoButSaysSo() {
        let verdict = scorer.evaluate(calm { $0.humidityPercent = 75 }, profile: .neo2)
        #expect(verdict.verdict == .go)
        #expect(!verdict.flags.contains(.humidityOverLimit))
        #expect(verdict.bindingFactor == "Humidity 75% at your 75% limit")
    }

    @Test func thresholdsFollowThePilotsSettings() {
        let relaxed = FlightScorer(thresholds: UserThresholds(
            maxHumidityPercent: 85, maxPrecipChancePercent: 40, maxGustMph: 20))
        let verdict = relaxed.evaluate(
            calm { $0.humidityPercent = 78; $0.precipChancePercent = 32 }, profile: .neo2)
        #expect(verdict.flags.isEmpty)
        #expect(verdict.verdict == .go)
    }

    @Test func calmDaySaysAllFactorsWithinLimits() {
        #expect(scorer.evaluate(calm(), profile: .neo2).bindingFactor == "All factors within your limits")
    }

    // MARK: Caution flags

    @Test func fpvGoggleFogFlag() {
        let verdict = scorer.evaluate(
            calm { $0.humidityPercent = 90; $0.tempC = 5 }, profile: .fpvPractice)
        #expect(verdict.flags.contains(.goggleFog))
        #expect(verdict.verdict == .caution)
    }

    @Test func goggleFogDoesNotApplyToCameraProfiles() {
        let verdict = scorer.evaluate(
            calm { $0.humidityPercent = 90; $0.tempC = 5 }, profile: .air3s)
        #expect(!verdict.flags.contains(.goggleFog))
    }

    @Test func coldBatteryFlagBelowFreezing() {
        let verdict = scorer.evaluate(calm { $0.tempC = -5 }, profile: .neo2)
        #expect(verdict.gates.isEmpty)
        #expect(verdict.flags.contains(.coldBattery))
        #expect(verdict.verdict == .caution)
    }

    @Test func fpvGustBandFlagsBelowHardLimit() {
        // 16 mph gusts: fine for the Neo 2 camera profile, flagged for FPV.
        let camera = scorer.evaluate(calm { $0.gustMph = 16 }, profile: .neo2)
        #expect(!camera.flags.contains(.fpvGustBand))

        let fpv = scorer.evaluate(calm { $0.gustMph = 16 }, profile: .fpvPractice)
        #expect(fpv.flags.contains(.fpvGustBand))
        #expect(fpv.verdict == .caution)
    }

    @Test func sustainedWindNearTheLimitFlagsCaution() {
        // 15 mph sustained is 75 % of the 20 mph default limit — under the
        // hard gate, over the "watch it" line.
        let verdict = scorer.evaluate(
            calm { $0.windMph = 15; $0.gustMph = 15 }, profile: .neo2)
        #expect(verdict.gates.isEmpty)
        #expect(verdict.flags.contains(.sustainedWindHigh))
        #expect(verdict.verdict == .caution)
    }

    @Test func fpvMarginOnlyBitesOnceThePilotRaisesTheirOwnLimit() {
        // 23.9 mph airframe × 0.85 FPV margin = 20.3, so at the 20 mph
        // default the user threshold is still the binding one…
        #expect(scorer.effectiveGustLimit(for: .fpvPractice) == 20)

        // …and a pilot who raises their limit inherits the margin instead.
        let permissive = FlightScorer(thresholds: UserThresholds(
            maxHumidityPercent: 75, maxPrecipChancePercent: 30, maxGustMph: 25))
        #expect(abs(permissive.effectiveGustLimit(for: .fpvPractice) - 20.315) < 0.0001)
    }

    @Test func mphFormattingDropsMeaninglessDecimals() {
        #expect(FlightScorer.mph(20) == "20")
        #expect(FlightScorer.mph(17.9) == "17.9")
    }

    // MARK: Freshness policy

    @Test func missingDataCountsAsExpired() {
        #expect(DataFreshness.isStale(nil))
        #expect(DataFreshness.isExpired(nil))
        #expect(DataFreshness.needsRefresh(nil))
    }

    @Test func freshnessThresholds() {
        #expect(!DataFreshness.needsRefresh(9 * 60))
        #expect(DataFreshness.needsRefresh(11 * 60))
        #expect(!DataFreshness.isStale(29 * 60))
        #expect(DataFreshness.isStale(31 * 60))
        #expect(!DataFreshness.isExpired(90 * 60))
        #expect(DataFreshness.isExpired(3 * 3600))
    }

    // MARK: Forecast horizon

    /// Fixed zone so the hour-boundary math doesn't depend on the test host.
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    /// 1_749_999_600 is an exact UTC hour boundary.
    private let hourBase = Date(timeIntervalSince1970: 1_749_999_600)

    private func forecastHour(offset: Int) -> HourConditions {
        HourConditions(
            date: hourBase.addingTimeInterval(Double(offset) * 3600),
            tempC: 20, humidityPercent: 50, precipChancePercent: 5,
            isPrecipitating: false, windMph: 4, gustMph: 7,
            cloudCoverPercent: 20, visibilityMiles: 10)
    }

    @Test func forecastWindowStartsAtTheCurrentHourNotTheApiCursor() {
        // Providers hand back elapsed rows: Open-Meteo from the top of the
        // UTC day, WeatherKit from the last completed hour.
        let hours = (-6...20).map { forecastHour(offset: $0) }
        let window = ForecastWindow.upcoming(
            hours, from: hourBase.addingTimeInterval(12 * 60), calendar: utc)

        #expect(window.count == ForecastWindow.defaultLimit)
        #expect(window.first?.date == hourBase)
        #expect(window.last?.date == hourBase.addingTimeInterval(12 * 3600))
    }

    @Test func forecastWindowOrdersRowsAndDropsElapsedOnes() {
        let scrambled = [2, -1, 1, 0].map { forecastHour(offset: $0) }
        let window = ForecastWindow.upcoming(scrambled, from: hourBase, calendar: utc)

        #expect(window.map(\.date) == [
            hourBase,
            hourBase.addingTimeInterval(3600),
            hourBase.addingTimeInterval(2 * 3600),
        ])
    }

    @Test func forecastWindowIsEmptyWhenEveryRowHasElapsed() {
        let stale = (-5 ... -1).map { forecastHour(offset: $0) }
        #expect(ForecastWindow.upcoming(stale, from: hourBase, calendar: utc).isEmpty)
    }

    // MARK: Best-window finder

    @Test func bestWindowFindsLongestRun() {
        let base = Date(timeIntervalSince1970: 1_750_000_000)
        let sequence: [Verdict] = [.noGo, .go, .go, .caution, .go, .go, .go, .noGo]
        let hours = sequence.enumerated().map { index, verdict in
            (base.addingTimeInterval(Double(index) * 3600), verdict)
        }

        let window = WindowFinder.bestGoWindow(hours)
        #expect(window?.start == base.addingTimeInterval(4 * 3600))
        #expect(window?.duration == TimeInterval(3 * 3600))
    }

    @Test func bestWindowPrefersEarliestOnTies() {
        let base = Date(timeIntervalSince1970: 1_750_000_000)
        let sequence: [Verdict] = [.go, .go, .noGo, .go, .go]
        let hours = sequence.enumerated().map { index, verdict in
            (base.addingTimeInterval(Double(index) * 3600), verdict)
        }

        let window = WindowFinder.bestGoWindow(hours)
        #expect(window?.start == base)
        #expect(window?.duration == TimeInterval(2 * 3600))
    }

    @Test func bestWindowNilForEmptyForecast() {
        #expect(WindowFinder.bestGoWindow([]) == nil)
    }

    @Test func bestWindowNilWhenNoGoHours() {
        let base = Date(timeIntervalSince1970: 1_750_000_000)
        let hours: [(Date, Verdict)] = [(base, .caution), (base.addingTimeInterval(3600), .noGo)]
        #expect(WindowFinder.bestGoWindow(hours) == nil)
    }
}
