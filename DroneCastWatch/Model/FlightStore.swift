//
//  FlightStore.swift
//  DroneCast — Model layer
//
//  Single @Observable source of truth. Fetch pipeline:
//  location → provider (WeatherKit, Open-Meteo fallback) → score →
//  briefing (template now, model later) → persist snapshot → reload
//  widget timelines.
//

import SwiftUI
import CoreLocation
import WidgetKit
import WatchKit
import Observation

@MainActor
@Observable
final class FlightStore {

    enum Phase: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    // MARK: State

    private(set) var phase: Phase = .idle
    private(set) var snapshot: ConditionsSnapshot?
    private(set) var hourly: [HourConditions] = []
    private(set) var verdict: FlightVerdict?
    private(set) var hourlyVerdicts: [HourVerdict] = []
    private(set) var attributionMarkURL: URL?
    private(set) var attributionLegalURL: URL?
    /// Set when a refresh fails while older data is still on screen. Without
    /// it the app silently kept showing stale numbers as if nothing happened.
    private(set) var lastRefreshError: String?
    /// Plain-English briefing of the current verdict. Always present when a
    /// verdict is: the template appears immediately, and a guard-approved
    /// model version may replace it moments later.
    private(set) var briefing: Briefing?

    var selectedProfile: DroneProfile {
        didSet {
            guard oldValue != selectedProfile else { return }
            rescore()
            persist()
        }
    }

    var thresholds: UserThresholds {
        didSet {
            guard oldValue != thresholds else { return }
            rescore()
            persist()
        }
    }

    /// Settings toggle. Off → template briefings only, no model calls.
    var aiBriefingEnabled: Bool {
        didSet {
            guard oldValue != aiBriefingEnabled else { return }
            updateBriefing(allowModel: true)
            persist()
        }
    }

    // MARK: Dependencies

    /// The app-wide instance. The SwiftUI scene and the background-refresh
    /// delegate have to share one store — two would double-fetch and fight
    /// over the persisted snapshot.
    static let shared = FlightStore()

    private let provider: any WeatherProviding
    private let fallback: (any WeatherProviding)?
    private let locationService = LocationService()
    private let briefingService: BriefingService
    private var refreshTask: Task<Void, Never>?
    private var widgetReloadTask: Task<Void, Never>?
    private var briefingTask: Task<Void, Never>?
    private var briefingTaskFacts: BriefingFacts?

    init(provider: (any WeatherProviding)? = nil,
         fallback: (any WeatherProviding)? = nil,
         briefingGenerator: (any BriefingGenerating)? = nil) {
        // Open-Meteo is primary on free personal teams (WeatherKit needs
        // the paid Developer Program). Flip WeatherConfig.preferWeatherKit
        // after joining.
        self.provider = provider ?? (WeatherConfig.preferWeatherKit
            ? WeatherKitProvider() as any WeatherProviding
            : OpenMeteoProvider())
        // Only WeatherKit-first builds get a failover. With WeatherKit off,
        // it can't be signed for, so trying it after Open-Meteo fails just
        // replaces a useful network error with a cryptic JWT one.
        let defaultFallback: (any WeatherProviding)? =
            WeatherConfig.preferWeatherKit ? OpenMeteoProvider() : nil
        self.fallback = fallback ?? defaultFallback

        // Same pattern as WeatherKit: the Private Cloud Compute model needs
        // an entitlement personal teams can't get, so it's compiled out by
        // default and every briefing is the deterministic template.
        let defaultGenerator: (any BriefingGenerating)? =
            BriefingConfig.useCloudModel ? PCCBriefingGenerator() : nil
        self.briefingService = BriefingService(generator: briefingGenerator ?? defaultGenerator)

        // Warm-start from the persisted snapshot (didSet doesn't fire in init).
        let saved = SharedStore.load()
        selectedProfile = DroneProfile.profile(id: saved?.profileID ?? DroneProfile.neo2.id)
        thresholds = saved?.thresholds ?? .standard
        snapshot = saved?.snapshot
        hourly = saved?.hourly ?? []
        verdict = saved?.verdict
        hourlyVerdicts = saved?.hourlyVerdicts ?? []
        aiBriefingEnabled = saved?.aiBriefingEnabled ?? true
        if snapshot != nil { phase = .loaded }
        updateBriefing(allowModel: false)
    }

    // MARK: Staleness

    var dataAge: TimeInterval? { DataFreshness.age(of: snapshot?.timestamp) }

    /// > 30 min — verdict still shown, badged STALE.
    var isStale: Bool { DataFreshness.isStale(dataAge) }

    /// > 2 h — verdict suppressed entirely; refresh required.
    var isExpired: Bool { DataFreshness.isExpired(dataAge) }

    // MARK: Refresh pipeline

    /// Silent refresh on foreground when the snapshot is > 10 min old.
    func refreshIfNeeded() async {
        if DataFreshness.needsRefresh(dataAge) {
            await refresh()
        } else {
            // Data is fresh, but the model may not have seen it yet (e.g. a
            // background refresh wrote a template). Cached facts are free.
            updateBriefing(allowModel: true)
            await loadAttributionIfNeeded()
        }
    }

    /// Woken by `WKApplicationRefreshBackgroundTask`. Same pipeline, but it
    /// reuses a cached fix rather than waking the radios for a new one —
    /// background location is unreliable under when-in-use authorization,
    /// and the weather grid is far coarser than an hour of drift.
    func refreshInBackground() async {
        await refresh(locationMaxCacheAge: 60 * 60, allowModel: false)
    }

    /// Concurrent callers join the in-flight fetch instead of starting a
    /// second one: launch fires both `.task` and the `.active` scene change,
    /// which used to race and flash a spurious "no location" failure.
    ///
    /// `allowModel: false` (background wake-ups) writes the template
    /// briefing only — the model is asked when the pilot is actually
    /// looking, which keeps the daily Private Cloud Compute quota for them.
    func refresh(locationMaxCacheAge: TimeInterval = 5 * 60, allowModel: Bool = true) async {
        if let refreshTask {
            await refreshTask.value
            return
        }
        let task = Task {
            await performRefresh(locationMaxCacheAge: locationMaxCacheAge,
                                 allowModel: allowModel)
        }
        refreshTask = task
        await task.value
        refreshTask = nil
    }

    private func performRefresh(locationMaxCacheAge: TimeInterval, allowModel: Bool) async {
        phase = .loading
        do {
            let location = try await locationService.currentLocation(
                maxCacheAge: locationMaxCacheAge)

            let result: (current: ConditionsSnapshot, hourly: [HourConditions])
            do {
                result = try await provider.fetch(at: location)
            } catch {
                // Primary failed — try the failover, but keep the primary's
                // error if that fails too: it's the one worth reading.
                guard let fallback,
                      let failover = try? await fallback.fetch(at: location) else {
                    throw error
                }
                result = failover
            }

            let previousVerdict = verdict?.verdict
            snapshot = result.current
            hourly = result.hourly
            rescore(allowModel: allowModel)
            phase = .loaded
            lastRefreshError = nil
            playHaptic(from: previousVerdict, to: verdict?.verdict)
            persist(reloadWidgets: .immediate)
        } catch {
            // Keep any stale snapshot visible; the age badge tells the story.
            lastRefreshError = error.localizedDescription
            phase = snapshot == nil ? .failed(error.localizedDescription) : .loaded
        }
        await loadAttributionIfNeeded()
    }

    // MARK: Scoring

    /// Re-runs the engine, then refreshes the briefing from its output.
    private func rescore(allowModel: Bool = true) {
        defer { updateBriefing(allowModel: allowModel) }
        guard let snapshot else {
            verdict = nil
            hourlyVerdicts = []
            return
        }
        let scorer = FlightScorer(thresholds: thresholds)
        verdict = scorer.evaluate(snapshot, profile: selectedProfile)
        hourlyVerdicts = hourly.map { hour in
            let hourVerdict = scorer.evaluate(
                hour.asSnapshot(provider: snapshot.providerName, alert: nil),
                profile: selectedProfile)
            return HourVerdict(
                date: hour.date,
                verdict: hourVerdict.verdict,
                score: hourVerdict.score,
                gustMph: hour.gustMph,
                precipChancePercent: hour.precipChancePercent)
        }
    }

    var bestWindow: DateInterval? {
        WindowFinder.bestGoWindow(hourlyVerdicts.map { ($0.date, $0.verdict) })
    }

    /// Live view of the clamp for the settings screen.
    var effectiveGustLimit: Double {
        FlightScorer(thresholds: thresholds).effectiveGustLimit(for: selectedProfile)
    }

    var aircraftLimitBinds: Bool {
        effectiveGustLimit < thresholds.maxGustMph
    }

    // MARK: Briefing

    /// Engine output → facts. nil when there's nothing current to brief.
    private var currentFacts: BriefingFacts? {
        guard let snapshot, let verdict, !isExpired else { return nil }
        return BriefingFacts(verdict: verdict,
                             snapshot: snapshot,
                             profile: selectedProfile,
                             thresholds: thresholds,
                             bestWindow: bestWindow)
    }

    /// Template (or cached) briefing right now; then, if allowed, the model
    /// pipeline in the background. A result is only applied if the facts
    /// haven't moved on while it was generating.
    private func updateBriefing(allowModel: Bool) {
        guard let facts = currentFacts, let timestamp = snapshot?.timestamp else {
            cancelBriefingTask()
            briefing = nil
            return
        }
        // Launch fires both `.task` and the `.active` scene change; don't
        // cancel (and pay for) a request that's already answering this.
        if briefingTask != nil, briefingTaskFacts == facts, aiBriefingEnabled { return }
        cancelBriefingTask()

        briefing = briefingService.immediateBriefing(
            for: facts, snapshotTimestamp: timestamp, aiEnabled: aiBriefingEnabled)

        guard allowModel, aiBriefingEnabled, briefing?.source != .ai else { return }
        briefingTaskFacts = facts
        briefingTask = Task {
            let result = await briefingService.briefing(
                for: facts, snapshotTimestamp: timestamp, aiEnabled: true)
            guard !Task.isCancelled, currentFacts == facts else { return }
            let textChanged = result.headline != briefing?.headline
                || result.detail != briefing?.detail
                || result.window != briefing?.window
            briefing = result
            briefingTask = nil
            briefingTaskFacts = nil
            if textChanged {
                WidgetCenter.shared.reloadTimelines(ofKind: BriefingStore.widgetKind)
            }
        }
    }

    private func cancelBriefingTask() {
        briefingTask?.cancel()
        briefingTask = nil
        briefingTaskFacts = nil
    }

    /// One-line status for Settings.
    var briefingStatusText: String {
        guard aiBriefingEnabled else { return "Off — using templates" }
        guard let briefing else { return "Waiting for weather" }
        switch briefing.source {
        case .ai:
            return "Apple Intelligence (Private Cloud Compute)"
        case .template:
            switch briefing.fallbackReason {
            case .modelUnavailable(let reason)?: return "Template — \(reason.label)"
            case .timedOut?:                     return "Template — AI timed out"
            case .generationFailed?:             return "Template — AI error"
            case .rejectedByGuard?:              return "Template — AI text failed checks"
            case .disabledByUser?, nil:          return "Template"
            }
        }
    }

    // MARK: Side effects

    private func persist(reloadWidgets: WidgetReload = .coalesced) {
        SharedStore.save(PersistedState(
            snapshot: snapshot,
            hourly: hourly,
            verdict: verdict,
            hourlyVerdicts: hourlyVerdicts,
            profileID: selectedProfile.id,
            thresholds: thresholds,
            aiBriefingEnabled: aiBriefingEnabled))

        // Profile/threshold switches change the verdict — push it to the
        // complication right away, not just after the next weather fetch.
        switch reloadWidgets {
        case .immediate:
            widgetReloadTask?.cancel()
            widgetReloadTask = nil
            WidgetCenter.shared.reloadAllTimelines()
        case .coalesced:
            scheduleWidgetReload()
        }
    }

    private enum WidgetReload {
        /// A fresh fetch — push it out now.
        case immediate
        /// A settings edit — hold briefly, since every stepper tap lands here
        /// and WidgetKit rations reloads.
        case coalesced
    }

    private func scheduleWidgetReload() {
        widgetReloadTask?.cancel()
        widgetReloadTask = Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            WidgetCenter.shared.reloadAllTimelines()
            widgetReloadTask = nil
        }
    }

    /// Haptic only when a fresh fetch CHANGES the verdict — never on
    /// unchanged results, never on profile/threshold edits.
    private func playHaptic(from old: Verdict?, to new: Verdict?) {
        guard let old, let new, old != new else { return }
        WKInterfaceDevice.current().play(new == .noGo ? .notification : .success)
    }

    private func loadAttributionIfNeeded() async {
        // Apple's mark is only required (and only fetchable) when WeatherKit
        // is the data source; Open-Meteo attribution is static text.
        guard WeatherConfig.preferWeatherKit else { return }
        guard attributionMarkURL == nil else { return }
        if let attribution = try? await WeatherKitProvider.attribution() {
            attributionMarkURL = attribution.markDark
            attributionLegalURL = attribution.legal
        }
    }
}
