//
//  WeatherKitProvider.swift
//  DroneCast — Services layer
//
//  Requires: WeatherKit capability on the App ID (developer portal, both
//  "Capabilities" and "App Services" tabs) and the
//  com.apple.developer.weatherkit entitlement (already in
//  DroneCastWatch.entitlements). Entitlement propagation can take ~30 min
//  after enabling — a JWT auth error on first run usually just means wait.
//

import Foundation
import CoreLocation
import WeatherKit

struct WeatherKitProvider: WeatherProviding {
    let name = "Apple Weather"

    func fetch(at location: CLLocation) async throws
        -> (current: ConditionsSnapshot, hourly: [HourConditions]) {

        let (current, hourlyForecast, alerts) = try await WeatherService.shared
            .weather(for: location, including: .current, .hourly, .alerts)

        let now = Date()

        // Active severe/extreme alert, if any.
        let severe = alerts?.first {
            $0.severity == .severe || $0.severity == .extreme
        }

        // Current hour's row supplies precipitation chance for "now".
        let hours = hourlyForecast.forecast
        let currentHour = hours.first {
            Calendar.current.isDate($0.date, equalTo: now, toGranularity: .hour)
        } ?? hours.first

        let snapshot = ConditionsSnapshot(
            timestamp: now,
            tempC: current.temperature.converted(to: .celsius).value,
            humidityPercent: current.humidity * 100,
            precipChancePercent: (currentHour?.precipitationChance ?? 0) * 100,
            isPrecipitating: current.condition.isActivePrecipitation,
            windMph: current.wind.speed.mph,
            gustMph: current.wind.gust?.mph ?? current.wind.speed.mph,
            windDirectionDegrees: current.wind.direction.converted(to: .degrees).value,
            cloudCoverPercent: current.cloudCover * 100,
            visibilityMiles: current.visibility.converted(to: .miles).value,
            severeAlert: severe?.summary,
            providerName: name)

        // Current hour + next 12, trimmed by the same rule the widget and the
        // window strip assume.
        let horizon = ForecastWindow.upcoming(
            hours.map { hour in
                HourConditions(
                    date: hour.date,
                    tempC: hour.temperature.converted(to: .celsius).value,
                    humidityPercent: hour.humidity * 100,
                    precipChancePercent: hour.precipitationChance * 100,
                    isPrecipitating: hour.condition.isActivePrecipitation,
                    windMph: hour.wind.speed.mph,
                    gustMph: hour.wind.gust?.mph ?? hour.wind.speed.mph,
                    cloudCoverPercent: hour.cloudCover * 100,
                    visibilityMiles: hour.visibility.converted(to: .miles).value)
            },
            from: now)

        guard !horizon.isEmpty else { throw WeatherProviderError.noData }
        return (snapshot, horizon)
    }

    /// Apple requires the Weather mark + a legal link wherever data appears.
    /// Rendered on the factor-breakdown screen.
    static func attribution() async throws -> (markDark: URL, legal: URL) {
        let attribution = try await WeatherService.shared.attribution
        return (attribution.combinedMarkDarkURL, attribution.legalPageURL)
    }
}

// MARK: - Unit + condition helpers

private extension Measurement where UnitType == UnitSpeed {
    var mph: Double { converted(to: .milesPerHour).value }
}

extension WeatherCondition {
    /// Conservative: any falling-precipitation condition is a hard gate.
    var isActivePrecipitation: Bool {
        switch self {
        case .drizzle, .rain, .heavyRain, .sunShowers,
             .freezingDrizzle, .freezingRain, .sleet, .wintryMix, .hail,
             .snow, .heavySnow, .flurries, .sunFlurries, .blowingSnow, .blizzard,
             .thunderstorms, .isolatedThunderstorms, .scatteredThunderstorms,
             .strongStorms, .tropicalStorm, .hurricane:
            return true
        default:
            return false
        }
    }
}
