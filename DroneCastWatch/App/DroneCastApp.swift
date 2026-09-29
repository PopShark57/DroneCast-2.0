//
//  DroneCastApp.swift
//  DroneCast
//

import SwiftUI
import WatchKit
import os

@main
struct DroneCastApp: App {
    @WKApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var store = FlightStore.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environment(store)
                .task { await store.refreshIfNeeded() }
                .onChange(of: scenePhase) { _, newPhase in
                    switch newPhase {
                    case .active:
                        Task { await store.refreshIfNeeded() }
                    case .background:
                        // Leaving the app is the moment to line up the next
                        // wake-up; the complication is what's on screen now.
                        BackgroundRefresh.schedule()
                    default:
                        break
                    }
                }
        }
    }
}

// MARK: - Background refresh

/// Keeps the complication honest between launches. Without this the widget
/// only ever sees data from the last time the app was opened, which on a
/// watch face is most of the day.
enum BackgroundRefresh {
    /// Matches the 30-minute STALE threshold: ask to be woken just as the
    /// complication would start graying out. watchOS rations wake-ups
    /// (roughly hourly for an installed complication) and simply runs late
    /// when the budget is spent, so asking on the optimistic side is free.
    static let interval: TimeInterval = DataFreshness.staleAfter

    private static var log: Logger {
        Logger(subsystem: Bundle.main.bundleIdentifier ?? "DroneCast",
               category: "BackgroundRefresh")
    }

    /// Safe to call repeatedly — each request replaces the pending one.
    static func schedule(after delay: TimeInterval = BackgroundRefresh.interval) {
        Task { @MainActor in
            WKApplication.shared().scheduleBackgroundRefresh(
                withPreferredDate: Date().addingTimeInterval(delay),
                userInfo: nil
            ) { error in
                if let error {
                    log.error("Scheduling failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }
}

/// WatchKit calls these on the main thread and the SDK protocol is
/// `@MainActor`-isolated, so the store hops below are free.
final class AppDelegate: NSObject, WKApplicationDelegate {

    func applicationDidFinishLaunching() {
        BackgroundRefresh.schedule()
    }

    func handle(_ backgroundTasks: Set<WKRefreshBackgroundTask>) {
        for task in backgroundTasks {
            switch task {
            case let refreshTask as WKApplicationRefreshBackgroundTask:
                Task {
                    await FlightStore.shared.refreshInBackground()
                    // Chain the next wake-up only after this one has run,
                    // so a failed fetch doesn't end the chain.
                    BackgroundRefresh.schedule()
                    refreshTask.setTaskCompletedWithSnapshot(true)
                }
            case let snapshotTask as WKSnapshotRefreshBackgroundTask:
                snapshotTask.setTaskCompleted(restoredDefaultState: true,
                                              estimatedSnapshotExpiration: .distantFuture,
                                              userInfo: nil)
            default:
                task.setTaskCompletedWithSnapshot(false)
            }
        }
    }
}
