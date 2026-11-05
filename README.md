# DroneCast 2.0 — watchOS

Go / no-go drone flight conditions on your wrist, scored against your personal thresholds (gusts < 20 mph, rain < 30 %, humidity < 75 %) and per-aircraft wind limits for the DJI Air 3S, Neo, Neo 2, and an FPV Practice profile. Gusts over the limit are an immediate NO-GO; humidity or rain chance above your threshold caps the verdict at CAUTION, so a day over any of your own limits is never GO.

**New in 2.0 — AI Briefing:** a plain-English briefing of the verdict under the score, a "Flight Briefing" complication, and a "Can I fly?" Siri shortcut. The deterministic scoring engine still decides everything; the language model only rewords its facts, and a hallucination guard throws away any text that changes a number or the verdict. See [AI Briefing](#ai-briefing-20).

Full product rationale lives in `DroneCast-Product-Spec.md` (delivered separately).

> **Build status:** the watch app is built and tested on the watchOS 27 simulator, and the iPhone companion is built for the iOS 27 simulator, by GitHub Actions (`.github/workflows/watchos.yml`). The Claude and iPhone briefing paths have not been exercised on real hardware — see [What hasn't been verified](#what-hasnt-been-verified).

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
│   ├── Services/                WeatherKit, Open-Meteo, location; Claude / iPhone / PCC briefing generators
│   ├── Intents/                 "Can I fly?" App Intent + Siri phrases
│   ├── Resources/               Assets.xcassets (icon slot is empty)
│   ├── Info.plist
│   └── DroneCastWatch.entitlements
├── DroneCastWidgets/            ← widget extension (verdict + briefing complications)
├── DroneCastPhone/              ← iPhone companion: runs the on-device model for the watch
├── Shared/                      ← briefing prompt + schema used by watch and iPhone
├── Config/                      ← build settings; Secrets.xcconfig (git-ignored) holds the Claude key
└── Tests/                       ← scorer + briefing unit tests (Swift Testing)
```

Requires **Xcode 27+** (Swift 6, Swift Testing), deployment targets **watchOS 27** and **iOS 27** (for the companion).

## Option A — generate the project with XcodeGen

```bash
brew install xcodegen
cd DroneCast
xcodegen generate
open DroneCast.xcodeproj
```

## Option B — manual Xcode setup (no tooling)

> Option B predates the iPhone companion and the Claude key config. For AI briefings beyond the template, use Option A — `project.yml` sets up the `DroneCastPhone` target, the watch-app embedding, and `Config/DroneCastWatch.xcconfig`.

1. Xcode → **File → New → Project → watchOS → App**. Product name `DroneCastWatch`, interface SwiftUI, language Swift. Check "Include Tests" if you want Xcode-managed test targets, or add a unit-test target later.
2. Delete the template `ContentView.swift` and the template App file.
3. Drag the folders `App`, `Views`, `Model`, `Domain`, `Persistence`, `Services`, `Resources` from `DroneCastWatch/` into the app target (copy items, add to DroneCastWatch target).
4. Replace the target's Info.plist entries with the keys from `DroneCastWatch/Info.plist` (most importantly `NSLocationWhenInUseUsageDescription`).
5. **File → New → Target → watchOS → Widget Extension**, name `DroneCastWidgets`, uncheck "Include Configuration App Intent". Replace the template Swift file with `DroneCastWidgets/DroneCastWidgets.swift`.
6. Select everything in `Domain/`, `Briefing/`, and `Persistence/SharedDefaults.swift` in the navigator and add **DroneCastWidgets** to their Target Membership (File Inspector). Also add `DroneCastWidgets/BriefingWidget.swift` to the widget target.
7. Add a **Unit Testing Bundle** target `DroneCastTests` (no host app), add everything in `Tests/`, and give the `Domain/`, `Briefing/`, and `Persistence/` files membership in this target too.

## Signing & capabilities (both options)

**Free personal team (default configuration):** the project ships with Open-Meteo as the weather provider and no WeatherKit entitlement, because personal teams cannot sign for WeatherKit — it requires paid Apple Developer Program membership.

1. Select each target (DroneCastWatch, DroneCastWidgets, DroneCastPhone) → **Signing & Capabilities** → set your **Team** (your "(Personal Team)" entry is fine). `project.yml` already sets team `7RLDYXQTNX`, so `xcodegen generate` keeps it.
2. Watch app target AND widget target → **+ Capability → App Groups** → create/select a group you own, e.g. `group.com.sguzyayev.dronecast`.
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
2. **`BriefingService`** checks model availability before every use, sends the facts as JSON (never prose) with one shared prompt (`Shared/BriefingPrompt.swift`), and gives up after 20 s.
3. **`ChainedBriefingGenerator`** tries the models in order and keeps the first answer that passes the guard:
   1. **Claude** (`ClaudeBriefingGenerator`) — the watch calls the Anthropic Messages API directly over Wi-Fi/cellular, with structured JSON output. Used when an API key is set.
   2. **Your iPhone** (`PhoneBriefingGenerator` → `DroneCastPhone`) — the facts go to the iPhone app over WatchConnectivity, the iPhone runs Apple's on-device model (`SystemLanguageModel`) and sends back the explanation sentence; the watch uses the engine's own headline and window around it. Used when the iPhone is in range. (Apple's ~3B on-device model kept overrunning the 40-character headline and inventing windows when asked for all three fields; with shorter, example-led instructions and the detail sentence only, all 8 GO / CAUTION / NO-GO test scenarios passed the guard when run against the on-device model on a Mac.)
   3. **Private Cloud Compute** (`PCCBriefingGenerator`) — only if you ever enable it (paid program, see below).
4. **`HallucinationGuard`** rejects any output where a number isn't in the facts, a number behind the binding factor is missing, a number is spelled out, the headline doesn't state the engine's verdict, or any wording implies a different verdict. A rejected answer gives the next model a turn.
5. **`BriefingTemplate`** produces a deterministic briefing whenever every model is off, unavailable, erroring, slow, or rejected. The card looks identical either way; a small **AI** / **Template** tag shows the source, and Settings → Briefing names the model that wrote it.
6. Briefings are **cached per aircraft + facts** in the App Group and only regenerated when the facts change. The complication and Siri intent read the cache only and never call a model. Background refreshes write the template; models are only asked in the foreground.

### Why not just Apple Intelligence on the watch?

- **There is no on-device language model on Apple Watch.** In the watchOS 27 SDK, `SystemLanguageModel` is marked unavailable on watchOS, and the watch does not borrow the iPhone's model on its own.
- The only Apple model the watch can call is **Private Cloud Compute**, and that needs a managed entitlement Apple grants only to App Store Small Business Program members — i.e. the paid Developer Program. A free personal team can't sign for it.
- So a free-team build gets AI text two other ways: Claude (no Apple entitlement involved) and the iPhone's on-device model, which DroneCast reaches explicitly through its iPhone companion app. Neither needs anything from Apple beyond free signing.

### Set up AI briefings (free personal team)

You can do either part or both. With both, Claude goes first and the iPhone backs it up.

**Part 1 — Claude (works anywhere the watch has internet)**

1. Create an Anthropic API key at [platform.claude.com](https://platform.claude.com/settings/keys) (add a little credit and set a low monthly spend limit). A briefing on the default `claude-haiku-5-5` costs a small fraction of a cent.
2. In Terminal:
   ```bash
   cd DroneCast-2.0
   cp Config/Secrets.example.xcconfig Config/Secrets.xcconfig
   open -e Config/Secrets.xcconfig
   ```
   Replace `sk-ant-REPLACE_ME` with your key (no quotes). `Config/Secrets.xcconfig` is git-ignored, so the key stays out of the repo.
3. In Xcode: **Product → Clean Build Folder** (⇧⌘K), then run the **DroneCastWatch** scheme on your watch.

The key ends up inside the watch app bundle. That's fine for a build that only lives on your own watch; don't hand this build to anyone else, and revoke the key in the Console if a device is lost. To change models, edit `ClaudeConfig.model` in `Services/ClaudeBriefingGenerator.swift`.

**Part 2 — your iPhone's on-device model (free, no key)**

Needs an iPhone 15 Pro or newer on iOS 27 with **Settings → Apple Intelligence & Siri** turned on and its model downloaded.

1. If an older watch-only DroneCast is on the watch, delete it first. The watch app's bundle ID changed to `com.sguzyayev.dronecast.watchkitapp` (a companion's watch app ID must start with the iPhone app's), so the old copy would sit beside the new one. Your thresholds reset once.
2. In Xcode, pick the **DroneCastPhone** scheme and your iPhone, and run. This installs the iPhone app and, through it, the watch app. If the watch app doesn't appear, open the **Watch** app on the iPhone → scroll to **DroneCast** → **Install**.
3. On the iPhone, the DroneCast screen should say **On-device model ready**. Tap **Test a sample briefing** to see the model write one.
4. Open DroneCast on the watch. With no Claude key (or no internet), Settings → Briefing should read **iPhone (Apple Intelligence)** once a briefing has been written.

The iPhone app doesn't need to stay open: iOS wakes it in the background for each request. It does need to be in Bluetooth/Wi-Fi range of the watch.

**Free-team housekeeping:** personal-team provisioning expires after **7 days** — re-run from Xcode weekly (both apps if you use the iPhone part). The iPhone app and new watch IDs use 3 of your 10 App IDs per week. The first run on a new iPhone needs **Settings → General → VPN & Device Management → trust your developer certificate**, and iOS asks you to enable **Developer Mode**.

### What the settings line means

| Settings → Briefing says | Meaning |
|---|---|
| Claude (Anthropic API) | Claude wrote the current briefing |
| iPhone (Apple Intelligence) | Your iPhone's on-device model wrote it |
| Template — No Claude API key set | No key and no iPhone app installed |
| Template — iPhone not reachable | iPhone app installed but out of range, and Claude isn't set up |
| Template — AI error | A model was tried and failed (bad key, no internet, iPhone model not ready) |
| Template — AI text failed checks | Every model's text changed a number or the verdict, so it was discarded |

### Enabling Private Cloud Compute later (paid program only)

1. Enrol in the App Store Small Business Program and request the Private Cloud Compute entitlement at [developer.apple.com/private-cloud-compute](https://developer.apple.com/private-cloud-compute/).
2. Add the entitlement to the **watch app** target (not the widget).
3. Flip `BriefingConfig.useCloudModel` to `true`. PCC joins the chain after Claude and the iPhone.

The **AI Briefing** toggle in Settings turns every model off at runtime; briefings then come from the template.

### What hasn't been verified

- A live Claude request from a real watch (the request and response handling is unit-tested against canned API JSON).
- The watch ⇄ iPhone round trip on real hardware, including how quickly iOS wakes the iPhone app in the background and whether iOS rate-limits background on-device generation.
- Real Private Cloud Compute responses (needs the entitlement).
- Siri invoking "Can I fly with DroneCast" by voice on a physical watch, and how the Flight Briefing complication renders on real watch faces.

## Known modelling limits

- The hourly window is scored **without** the alert feed — a severe alert gates "now" but not the next 12 hours, so the window strip carries a banner saying as much whenever one is active.
- The AI Briefing can only be as right as the engine: it restates the verdict, it never re-evaluates it.
- Every reading is a **surface** point forecast. Winds at 100–400 ft AGL routinely exceed them; the factor screen says so, and the per-aircraft clamp is the only margin the app applies for you.

## Safety footer (kept in-app, don't remove)

DroneCast is a weather decision aid. The pilot in command owns every flight decision, airspace authorization (B4UFLY / Aloft), and FAA compliance — TRUST/Part 107, registration + Remote ID ≥ 250 g, 400 ft AGL, VLOS.
