//
//  LocationService.swift
//  DroneCast — Services layer
//
//  One-shot "where am I" fix. Requests when-in-use authorization in
//  context on first use; ~100 m accuracy is plenty for a weather grid.
//

import Foundation
import CoreLocation

@MainActor
final class LocationService: NSObject, CLLocationManagerDelegate {

    enum LocationError: LocalizedError {
        case denied
        case unavailable
        case timedOut

        var errorDescription: String? {
            switch self {
            case .denied:
                return "Location access is off. Enable it in Settings → Privacy → Location Services."
            case .unavailable:
                return "Couldn't get a location fix."
            case .timedOut:
                return "Location is taking too long — try again with a clear view of the sky."
            }
        }
    }

    /// How long to wait for a fix once we're authorized, and the longer
    /// budget that also covers the user reading the permission prompt.
    private enum Timeout {
        static let fix: TimeInterval = 15
        static let prompt: TimeInterval = 45
    }

    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<CLLocation, Error>?
    private var timeoutTask: Task<Void, Never>?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    /// One-shot fix. `maxCacheAge` lets a background refresh reuse an older
    /// cached fix rather than spinning up the radios: the weather grid is
    /// coarse enough that a fix from earlier in the hour is still right.
    func currentLocation(maxCacheAge: TimeInterval = 300) async throws -> CLLocation {
        if let cached = manager.location,
           -cached.timestamp.timeIntervalSinceNow < maxCacheAge {
            return cached
        }

        let status = manager.authorizationStatus
        switch status {
        case .denied, .restricted:
            throw LocationError.denied
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
            // requestLocation() fires from the authorization callback.
        default:
            break
        }

        // A dropped callback (no fix indoors, an unanswered prompt) used to
        // leave the continuation hanging forever, pinning the UI in .loading
        // with the refresh button disabled. Always give it a deadline.
        let budget = status == .notDetermined ? Timeout.prompt : Timeout.fix

        return try await withCheckedThrowingContinuation { continuation in
            if self.continuation != nil {
                continuation.resume(throwing: LocationError.unavailable)
                return
            }
            self.continuation = continuation
            self.timeoutTask = Task {
                try? await Task.sleep(for: .seconds(budget))
                guard !Task.isCancelled else { return }
                self.finish(.failure(LocationError.timedOut))
            }
            if self.isAuthorized {
                self.manager.requestLocation()
            }
        }
    }

    private var isAuthorized: Bool {
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways: return true
        default: return false
        }
    }

    private func finish(_ result: Result<CLLocation, Error>) {
        timeoutTask?.cancel()
        timeoutTask = nil
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(with: result)
    }

    // MARK: CLLocationManagerDelegate (nonisolated → hop to main)

    nonisolated func locationManager(_ manager: CLLocationManager,
                                     didUpdateLocations locations: [CLLocation]) {
        let location = locations.last
        Task { @MainActor in
            if let location {
                self.finish(.success(location))
            } else {
                self.finish(.failure(LocationError.unavailable))
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager,
                                     didFailWithError error: Error) {
        Task { @MainActor in
            self.finish(.failure(error))
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            guard self.continuation != nil else { return }
            switch status {
            case .authorizedWhenInUse, .authorizedAlways:
                self.manager.requestLocation()
            case .denied, .restricted:
                self.finish(.failure(LocationError.denied))
            default:
                break
            }
        }
    }
}
