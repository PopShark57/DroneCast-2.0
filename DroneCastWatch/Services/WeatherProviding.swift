//
//  WeatherProviding.swift
//  DroneCast — Services layer
//
//  Provider abstraction: the scorer only ever sees ConditionsSnapshot /
//  HourConditions in normalized units (mph, °C, 0–100 percentages).
//

import Foundation
import CoreLocation

// MARK: - Provider preference

/// WeatherKit requires paid Apple Developer Program membership — personal
/// (free) teams can't sign for the capability. Open-Meteo is therefore the
/// default provider.
///
/// After joining the paid program: flip this to true, re-add the WeatherKit
/// capability in Signing & Capabilities (which restores
/// com.apple.developer.weatherkit in the entitlements), and enable
/// WeatherKit on the App ID in the developer portal.
enum WeatherConfig {
    static let preferWeatherKit = false
}

// MARK: - Protocol

protocol WeatherProviding: Sendable {
    var name: String { get }

    /// Current conditions plus (current hour + next 12) hourly rows.
    func fetch(at location: CLLocation) async throws
        -> (current: ConditionsSnapshot, hourly: [HourConditions])
}

enum WeatherProviderError: LocalizedError {
    case badResponse
    case httpStatus(Int)
    case noData

    var errorDescription: String? {
        switch self {
        case .badResponse:
            return "The weather service returned an error."
        case .httpStatus(let code):
            return "The weather service returned an error (HTTP \(code))."
        case .noData:
            return "The weather service returned no usable data."
        }
    }
}

// MARK: - Open-Meteo

/// Free, keyless REST provider (non-commercial license — fine for a
/// personal build; revisit before any App Store release). No entitlement
/// or Apple Developer Program membership required.
struct OpenMeteoProvider: WeatherProviding {
    let name = "Open-Meteo"

    /// A watch on cellular shouldn't sit on URLSession's 60 s default while
    /// the pilot stares at a spinner.
    private static let requestTimeout: TimeInterval = 15

    func fetch(at location: CLLocation) async throws
        -> (current: ConditionsSnapshot, hourly: [HourConditions]) {

        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        components.queryItems = [
            URLQueryItem(name: "latitude",
                         value: String(format: "%.4f", location.coordinate.latitude)),
            URLQueryItem(name: "longitude",
                         value: String(format: "%.4f", location.coordinate.longitude)),
            URLQueryItem(name: "current", value:
                "temperature_2m,relative_humidity_2m,precipitation,weather_code," +
                "wind_speed_10m,wind_gusts_10m,wind_direction_10m,cloud_cover"),
            URLQueryItem(name: "hourly", value:
                "temperature_2m,relative_humidity_2m,precipitation_probability," +
                "precipitation,weather_code,wind_speed_10m,wind_gusts_10m," +
                "cloud_cover,visibility"),
            URLQueryItem(name: "wind_speed_unit", value: "mph"),
            URLQueryItem(name: "timeformat", value: "unixtime"),
            // Two days of rows, trimmed to the current hour + next 12 below.
            // Open-Meteo's hourly series starts at the top of the UTC day, so
            // asking for exactly 13 hours can hand back mostly elapsed ones.
            URLQueryItem(name: "forecast_days", value: "2"),
        ]
        guard let url = components.url else { throw WeatherProviderError.badResponse }

        let request = URLRequest(url: url,
                                 cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: Self.requestTimeout)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw WeatherProviderError.badResponse
        }
        guard http.statusCode == 200 else {
            throw WeatherProviderError.httpStatus(http.statusCode)
        }
        let decoded = try JSONDecoder().decode(OpenMeteoResponse.self, from: data)

        let hours = ForecastWindow.upcoming(Self.parseHours(decoded.hourly))
        guard let currentHour = hours.first else { throw WeatherProviderError.noData }

        let current = decoded.current
        let snapshot = ConditionsSnapshot(
            timestamp: Date(),
            tempC: current.temperature_2m,
            humidityPercent: current.relative_humidity_2m,
            // No probability in the current block — use the current hour's.
            precipChancePercent: currentHour.precipChancePercent,
            isPrecipitating: current.precipitation > 0
                || Self.wmoPrecipCodes.contains(current.weather_code),
            windMph: current.wind_speed_10m,
            gustMph: current.wind_gusts_10m ?? current.wind_speed_10m,
            windDirectionDegrees: current.wind_direction_10m,
            cloudCoverPercent: current.cloud_cover,
            // Visibility isn't in the current block — use the current hour's.
            visibilityMiles: currentHour.visibilityMiles,
            severeAlert: nil,   // Open-Meteo has no alert feed (WeatherKit-only feature)
            providerName: name)

        return (snapshot, hours)
    }

    /// Open-Meteo returns parallel arrays. They are *supposed* to be the same
    /// length, so indexing them off `time.indices` used to be a crash waiting
    /// for a truncated payload — drop any row that isn't fully populated
    /// instead.
    private static func parseHours(_ hourly: OpenMeteoResponse.Hourly) -> [HourConditions] {
        hourly.time.indices.compactMap { index in
            guard let epoch = hourly.time[safe: index],
                  let tempC = hourly.temperature_2m[safe: index],
                  let humidity = hourly.relative_humidity_2m[safe: index],
                  let precipitation = hourly.precipitation[safe: index],
                  let code = hourly.weather_code[safe: index],
                  let wind = hourly.wind_speed_10m[safe: index],
                  let cloud = hourly.cloud_cover[safe: index]
            else { return nil }

            return HourConditions(
                date: Date(timeIntervalSince1970: epoch),
                tempC: tempC,
                humidityPercent: humidity,
                precipChancePercent: value(hourly.precipitation_probability,
                                           at: index, default: 0),
                isPrecipitating: precipitation > 0 || wmoPrecipCodes.contains(code),
                windMph: wind,
                gustMph: value(hourly.wind_gusts_10m, at: index, default: wind),
                cloudCoverPercent: cloud,
                visibilityMiles: value(hourly.visibility, at: index,
                                       default: 10_000) / 1609.344)
        }
    }

    /// Element of possibly-null, possibly-absent Open-Meteo arrays.
    private static func value(_ array: [Double?]?, at index: Int,
                              default fallback: Double) -> Double {
        guard let array, let element = array[safe: index] else { return fallback }
        return element ?? fallback
    }

    /// WMO weather codes that mean precipitation is falling:
    /// drizzle 51–57, rain 61–67, snow 71–77, showers 80–82,
    /// snow showers 85–86, thunderstorms 95–99.
    private static let wmoPrecipCodes: Set<Int> = [
        51, 53, 55, 56, 57,
        61, 63, 65, 66, 67,
        71, 73, 75, 77,
        80, 81, 82, 85, 86,
        95, 96, 99,
    ]
}

private extension Array {
    /// Bounds-checked access — the parallel-array contract is the API's, not
    /// something this app should crash over.
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

// MARK: Open-Meteo response models (property names match API keys)

private struct OpenMeteoResponse: Decodable {
    struct Current: Decodable {
        let temperature_2m: Double
        let relative_humidity_2m: Double
        let precipitation: Double
        let weather_code: Int
        let wind_speed_10m: Double
        let wind_gusts_10m: Double?
        let wind_direction_10m: Double?
        let cloud_cover: Double
    }

    struct Hourly: Decodable {
        let time: [Double]
        let temperature_2m: [Double]
        let relative_humidity_2m: [Double]
        let precipitation_probability: [Double?]?
        let precipitation: [Double]
        let weather_code: [Int]
        let wind_speed_10m: [Double]
        let wind_gusts_10m: [Double?]?
        let cloud_cover: [Double]
        let visibility: [Double?]?
    }

    let current: Current
    let hourly: Hourly
}
