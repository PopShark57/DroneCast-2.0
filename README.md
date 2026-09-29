# DroneCast 2.0 — watchOS

Go / no-go drone flight conditions on your wrist, scored against your personal thresholds (gusts < 20 mph, rain < 30 %, humidity < 75 %) and per-aircraft wind limits for the DJI Air 3S, Neo, Neo 2, and an FPV Practice profile. Gusts over the limit are an immediate NO-GO; humidity or rain chance above your threshold caps the verdict at CAUTION, so a day over any of your own limits is never GO.

**New in 2.0 — AI Briefing:** a plain-English briefing of the verdict under the score, a "Flight Briefing" complication, and a "Can I fly?" Siri shortcut. The deterministic scoring engine still decides everything; the language model only rewords its facts, and a hallucination guard throws away any text that changes a number or the verdict. See [AI Briefing](#ai-briefing-20).

Full product rationale lives in `DroneCast-Product-Spec.md` (delivered separately).

> **Build status:** 2.0 is built and tested on the watchOS 27 simulator by GitHub Actions (`.github/workflows/watchos.yml`). The Private Cloud Compute model path has not been exercised on a real device — see [What hasn't been verified](#what-hasnt-been-verified).

## Project layout

```
DroneCast/
├── project.yml                  ← XcodeGen spec (option A)
├── DroneCastWatch/              ← watch app target
│   ├── App/                     DroneCastApp.swift (entry point)
│   ├── Views/                   Verdict · Factors · Window · Settings
│   ├── Model/                   FlightStore (observable state + refresh)
│   ├── Domain/                  Models + FlightScorer   ← shared w/ widget & tests
│   ├── Briefing/                Facts, template, guard, service, cache ← shared w/ widget & tests
│   ├── Persistence/             SharedDefaults (App Group) ← shared w/ widget
│   ├── Services/                WeatherKit, Open-Meteo, location, PCC briefing generator
│   ├── Intents/                 "Can I fly?" App Intent + Siri phrases
│   ├── Resources/               Assets.xcassets (icon slot is empty)
│   ├── Info.plist
│   └── DroneCastWatch.entitlements
├── DroneCastWidgets/            ← widget extension (verdict + briefing complications)
└── Tests/                       ← scorer + briefing unit tests (Swift Testing)
```

Requires **Xcode 27+** (Swift 6, Swift Testing), deployment target **watchOS 27** (Foundation Models is watchOS 27+).

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
6. Select everything in `Domain/`, `Briefing/`, and `Persistence/SharedDefaults.swift` in the navigator and add **DroneCastWidgets** to their Target Membership (File Inspector). Also add `DroneCastWidgets/BriefingWidget.swift` to the widget target.
7. Add a **Unit Testing Bundle** target `DroneCastTests` (no host app), add everything in `Tests/`, and give the `Domain/`, `Briefing/`, and `Persistence/` files membership in this target too.

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
- Complications: on the watch face, add the **Flight Conditions** complication — circular, rectangular, inline, or corner — and/or the **Flight Briefing** complication (rectangular or inline), which shows the briefing headline. It reads the app's last snapshot, so open the app once first; after that a background task keeps it current (see below).
- Background refresh: the app asks watchOS to wake it roughly every 30 minutes to re-fetch and re-score, which is what keeps the complication out of its gray STALE state between launches. watchOS rations these wake-ups (roughly one an hour for an installed complication) and ignores the request entirely for an app that isn't on the watch face or in the dock — so on the simulator, expect to drive refreshes by opening the app.

## Tests

`Cmd-U` on the DroneCastWatch scheme (or the DroneCastTests scheme in the manual setup). The suite covers the entire go/no-go policy: hard gates, humidity / rain-chance thresholds capping the verdict at CAUTION, per-aircraft gust clamping (19 mph gusts → Neo NO-GO, Neo 2/Air 3S CAUTION), threshold math, FPV goggle-fog and cold-battery flags, the freshness policy, the forecast horizon (`ForecastWindow`), and the best-window finder.

2.0 adds briefing tests that need no device or network — the model sits behind the `BriefingGenerating` protocol and tests use a mock:

- `BriefingFactsTests` — facts are a faithful, pre-formatted copy of engine output (clamp, window, data source, JSON round-trip, cache-key semantics).
- `BriefingTemplateTests` — the template for every verdict (GO, CAUTION, NO-GO by gate, NO-GO by score), and every aircraft × condition passes the hallucination guard.
- `HallucinationGuardTests` — wrong, rounded, missing, spelled-out and invented numbers; flipped and softened verdicts; and that the service falls back to the template for each.
- `BriefingServiceTests` — every availability case, model errors, timeouts, caching per aircraft + facts, the user toggle, and the Siri answer.

## Deliberately out of scope in v1.0

- **WeatherKit as primary provider** — fully implemented in `WeatherKitProvider.swift` but disabled by default (`WeatherConfig.preferWeatherKit = false`) because it requires the paid Developer Program. Open-Meteo (implemented, keyless, free for non-commercial use) is the active provider. Two caveats: Open-Meteo carries no severe-weather-alert feed, so the severe-alert hard gate only activates on WeatherKit; and with WeatherKit off there is no failover provider, because the entitlement it needs can't be signed by a personal team.

## AI Briefing (2.0)

### How it works

1. **`BriefingFacts`** is built from the scoring engine's output: aircraft, verdict, score, binding factor and any other gates/flags, wind/gust vs. the per-aircraft clamp, precipitation, temperature, visibility, the best GO window, and the data source. Every number is pre-formatted exactly as the factor screen shows it.
2. **`BriefingService`** checks the model's availability before every use, sends the facts as JSON (never prose) to a `LanguageModelSession` with guided generation (`@Generable` headline ≤ 40 chars, 1–2 sentence detail, window), with a 12 s timeout.
3. **`HallucinationGuard`** rejects the output if any number isn't in the facts, a number behind the binding factor is missing, a number is spelled out, the headline doesn't state the engine's verdict, or any wording implies a different verdict.
4. **`BriefingTemplate`** produces a deterministic briefing whenever the model is off, unavailable, erroring, slow, or rejected. The card looks identical either way; a small **AI** / **Template** tag shows the source.
5. Briefings are **cached per aircraft + facts** in the App Group and only regenerated when the facts change. The complication and Siri intent read the cache only and never call a model. Background refreshes write the template; the model is only asked in the foreground.

### Platform reality on watchOS 27 (read before enabling)

- **There is no on-device language model on Apple Watch.** `SystemLanguageModel` is not available on watchOS. Foundation Models on watchOS 27 always goes to **Private Cloud Compute** (`PrivateCloudComputeLanguageModel`) over Wi-Fi or cellular — not via the iPhone. Weather facts (never location) leave the device; Apple states PCC stores no prompts.
- Its availability reports `available`, `deviceNotEligible`, or `systemNotReady`, plus a separate per-user daily **quota**. All are handled and fall back to the template.
- **Personal teams can't use it.** PCC needs a managed entitlement that Apple grants only to App Store Small Business Program members (< 2M first-time downloads) — i.e. the paid Developer Program. So, exactly like WeatherKit, it ships **off**: `BriefingConfig.useCloudModel = false` in `Services/PCCBriefingGenerator.swift`, and no entitlement is added. With it off, every briefing is the template and the settings row says "Template — Not enabled in this build".

### Enabling the model later (paid program only)

1. Enrol in the App Store Small Business Program and request the Private Cloud Compute entitlement at [developer.apple.com/private-cloud-compute](https://developer.apple.com/private-cloud-compute/).
2. Add the entitlement to the **app** target (not the widget).
3. Flip `BriefingConfig.useCloudModel` to `true`.

The **AI Briefing** toggle in Settings turns the model off at runtime at any time; briefings then come from the template.

### What hasn't been verified

- Real Private Cloud Compute responses: output quality, latency on cellular, quota behaviour, and how often the guard rejects real output. None of this can run without the entitlement.
- Siri invoking "Can I fly with DroneCast" by voice on a physical watch, and how the Flight Briefing complication renders on real watch faces.

## Known modelling limits

- The hourly window is scored **without** the alert feed — a severe alert gates "now" but not the next 12 hours, so the window strip carries a banner saying as much whenever one is active.
- The AI Briefing can only be as right as the engine: it restates the verdict, it never re-evaluates it.
- Every reading is a **surface** point forecast. Winds at 100–400 ft AGL routinely exceed them; the factor screen says so, and the per-aircraft clamp is the only margin the app applies for you.

## Safety footer (kept in-app, don't remove)

DroneCast is a weather decision aid. The pilot in command owns every flight decision, airspace authorization (B4UFLY / Aloft), and FAA compliance — TRUST/Part 107, registration + Remote ID ≥ 250 g, 400 ft AGL, VLOS.
