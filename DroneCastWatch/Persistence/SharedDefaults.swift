//
//  SharedDefaults.swift
//  DroneCast — Persistence layer (compiled into app + widget targets)
//
//  The persisted snapshot is the ONLY bridge between the app and the
//  widget. The widget never fetches weather itself, which keeps the
//  WeatherKit call budget predictable and the extension trivial.
//

import Foundation

enum AppGroup {
    /// ⚠️ Must match the App Group enabled in BOTH targets'
    /// Signing & Capabilities, and registered on the developer portal.
    /// Rename to your own reverse-DNS group before first build.
    static let identifier = "group.com.sguzyayev.dronecast"
}

struct PersistedState: Codable, Sendable {
    var snapshot: ConditionsSnapshot?
    var hourly: [HourConditions]
    var verdict: FlightVerdict?
    var hourlyVerdicts: [HourVerdict]
    var profileID: String
    var thresholds: UserThresholds
}

enum SharedStore {
    private static let key = "dronecast.state.v1"

    private static var defaults: UserDefaults {
        // Falls back to .standard if the App Group isn't configured yet, so
        // the app still runs before capabilities are wired up (the widget
        // just won't see data until the group exists).
        UserDefaults(suiteName: AppGroup.identifier) ?? .standard
    }

    static func load() -> PersistedState? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(PersistedState.self, from: data)
    }

    static func save(_ state: PersistedState) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: key)
    }
}
