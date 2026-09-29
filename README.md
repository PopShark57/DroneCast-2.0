# DroneCast — watchOS

Go / no-go drone flight conditions on your wrist, scored against your personal thresholds (gusts < 20 mph, rain < 30 %, humidity < 75 %) and per-aircraft wind limits for the DJI Air 3S, Neo, Neo 2, and an FPV Practice profile.

Full product rationale lives in `DroneCast-Product-Spec.md` (delivered separately).

> **Heads-up:** this source tree was written off-Mac and has not been compiled. Expect the possibility of a few small fixups on first build — the domain layer (scorer + tests) is plain Foundation and should be the most solid part.

## Project layout

```
DroneCast/
├── project.yml                  ← XcodeGen spec (option A)
├── DroneCastWatch/              ← watch app target
│   ├── App/                     DroneCastApp.swift (entry point)
│   ├── Views/                   Verdict · Factors · Window · Settings
│   ├── Model/                   FlightStore (observable state + refresh)
│   ├── Domain/                  Models + FlightScorer   ← shared w/ widget & tests
│   ├── Persistence/             SharedDefaults (App Group) ← shared w/ widget
│   ├── Services/                WeatherKit provider, Open-Meteo stub, location
│   ├── Resources/               Assets.xcassets (icon slot is empty)
│   ├── Info.plist
│   └── DroneCastWatch.entitlements
├── DroneCastWidgets/            ← widget extension (circular + rectangular)
└── Tests/                       ← FlightScorer unit tests (Swift Testing)
```

Requires **Xcode 16+** (Swift 6, Swift Testing), deployment target **watchOS 11**.

## Option A — generate the project with XcodeGen

```bash
brew install xcodegen
cd DroneCast
xcodegen generate
open DroneCast.xcodeproj
```

## Option B — manual Xcode setup (no tooling)

1. Xcode → **File → New → Project → watchOS → App**. Product name `DroneCastWatch`, interface SwiftUI, language Swift. Check "Include Tests" if you want Xcode-managed test targets, or add a unit-test target later.
2. Delete the template `ContentView.swift` and the template App file.
3. Drag the folders `App`, `Views`, `Model`, `Domain`, `Persistence`, `Services`, `Resources` from `DroneCastWatch/` into the app target (copy items, add to DroneCastWatch target).
4. Replace the target's Info.plist entries with the keys from `DroneCastWatch/Info.plist` (most importantly `NSLocationWhenInUseUsageDescription`).
5. **File → New → Target → watchOS → Widget Extension**, name `DroneCastWidgets`, uncheck "Include Configuration App Intent". Replace the template Swift file with `DroneCastWidgets/DroneCastWidgets.swift`.
6. Select `Domain/Models.swift`, `Domain/FlightScorer.swift`, and `Persistence/SharedDefaults.swift` in the navigator and add **DroneCastWidgets** to their Target Membership (File Inspector).
7. Add a **Unit Testing Bundle** target `DroneCastTests` (no host app), add `Tests/FlightScorerTests.swift`, and give the two `Domain` files membership in this target too.

## Signing & capabilities (both options)

**Free personal team (default configuration):** the project ships with Open-Meteo as the weather provider and no WeatherKit entitlement, because personal teams cannot sign for WeatherKit — it requires paid Apple Developer Program membership.

1. Select each target → **Signing & Capabilities** → set your **Team** (your "(Personal Team)" entry is fine).
2. App target AND widget target → **+ Capability → App Groups** → create/select a group you own, e.g. `group.com.sguzyayev.dronecast`.
   - If you use a different group ID, update it in **three places**: both `.entitlements` files and `AppGroup.identifier` in `Persistence/SharedDefaults.swift`.
3. Personal-team limits to expect: provisioning expires after **7 days** (rebuild/reinstall to your watch weekly), max 10 App IDs and 3 devices at a time, and no App Store/TestFlight distribution.

**Upgrading to WeatherKit later (paid Developer Program only):**

1. Flip `WeatherConfig.preferWeatherKit` to `true` in `Services/WeatherProviding.swift` (Open-Meteo automatically becomes the failover).
2. App target → **+ Capability → WeatherKit** (restores `com.apple.developer.weatherkit` in the entitlements).
3. On [developer.apple.com](https://developer.apple.com/account) → Certificates, Identifiers & Profiles → your App ID: confirm **WeatherKit is checked on both the *Capabilities* tab and the *App Services* tab**, then save.
4. **Wait ~30 minutes.** WeatherKit entitlement propagation is slow; a `Failed to generate jwt token` / auth error on first run almost always means "not propagated yet", not a code problem.

## Running

- Scheme `DroneCastWatch` → a watchOS 11+ simulator or paired watch. First launch asks for location, fetches Apple Weather, and shows the verdict. Simulator tip: **Features → Location → Custom Location** if no fix arrives.
- Complications: on the watch face, add the **Flight Conditions** complication — circular, rectangular, inline, or corner. It reads the app's last snapshot, so open the app once first; after that a background task keeps it current (see below).
- Background refresh: the app asks watchOS to wake it roughly every 30 minutes to re-fetch and re-score, which is what keeps the complication out of its gray STALE state between launches. watchOS rations these wake-ups (roughly one an hour for an installed complication) and ignores the request entirely for an app that isn't on the watch face or in the dock — so on the simulator, expect to drive refreshes by opening the app.

## Tests

`Cmd-U` on the DroneCastWatch scheme (or the DroneCastTests scheme in the manual setup). The suite covers the entire go/no-go policy: hard gates, per-aircraft gust clamping (19 mph gusts → Neo NO-GO, Neo 2/Air 3S CAUTION), threshold math, FPV goggle-fog and cold-battery flags, the freshness policy, the forecast horizon (`ForecastWindow`), and the best-window finder.

## Deliberately out of scope in v1.0

- **WeatherKit as primary provider** — fully implemented in `WeatherKitProvider.swift` but disabled by default (`WeatherConfig.preferWeatherKit = false`) because it requires the paid Developer Program. Open-Meteo (implemented, keyless, free for non-commercial use) is the active provider. Two caveats: Open-Meteo carries no severe-weather-alert feed, so the severe-alert hard gate only activates on WeatherKit; and with WeatherKit off there is no failover provider, because the entitlement it needs can't be signed by a personal team.
- **AI flight coach** — v2, targeting on-device/PCC foundation models on watchOS 27.

## Known modelling limits

- The hourly window is scored **without** the alert feed — a severe alert gates "now" but not the next 12 hours, so the window strip carries a banner saying as much whenever one is active.
- Every reading is a **surface** point forecast. Winds at 100–400 ft AGL routinely exceed them; the factor screen says so, and the per-aircraft clamp is the only margin the app applies for you.

## Safety footer (kept in-app, don't remove)

DroneCast is a weather decision aid. The pilot in command owns every flight decision, airspace authorization (B4UFLY / Aloft), and FAA compliance — TRUST/Part 107, registration + Remote ID ≥ 250 g, 400 ft AGL, VLOS.
