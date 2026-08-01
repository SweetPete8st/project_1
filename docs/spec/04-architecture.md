# 04 — Application Architecture

## 1. Tech stack

- **Language:** Swift 6.x, strict concurrency complete (NFR-5).
- **UI:** SwiftUI + Observation framework; no UIKit view controllers except where a wrapped
  `MKMapView`/`MapKit for SwiftUI` gap forces it.
- **Minimum OS:** iOS 26.0. Single target + widget/Live Activity extension.
- **Persistence:** SwiftData for structured entities (sessions, events, spots, PRs) +
  custom append-only binary chunk files for high-rate telemetry (05 §4). SwiftData never
  stores per-frame data.
- **Maps:** MapKit (polyline overlays with per-segment tint for speed heat).
- **ML (M5):** Core ML + Background Assets.
- **Dependencies:** ZERO third-party runtime dependencies at v1. (Test-only tooling allowed:
  swift-snapshot-testing.) This is deliberate: sensor pipelines outlive fashion.

## 2. Module map (SPM local packages in one workspace)

```
Shred.xcodeproj (app shell + LiveActivity extension)
 └── Packages/
     ├── ShredCore        // shared value types, units, clock, DeviceCapabilities, DetectionTuning
     ├── CaptureKit       // Core Motion / Core Location / CMAltimeter adapters → FrameStream
     ├── DetectionKit     // PURE: preprocessing, detectors, arbiter (03). No Apple frameworks
     │                    //  beyond Foundation+Accelerate. Compiles & tests on macOS/Linux.
     ├── TelemetryStore   // binary chunk writer/reader, SwiftData models, compaction, export
     ├── SessionEngine    // orchestrates a session: capture → detection → store → LiveActivity
     ├── RouteKit         // Kalman speed fusion, route simplification, spot clustering, geocode
     ├── HealthBridge     // HealthKit workout writing (opt-in)
     └── FeatureUI/       // one library per feature: Onboarding, LiveSession, Summary,
                          //  History, Spots, Settings, ShareCard
```

Dependency rule (enforced by package manifests): `DetectionKit` and `ShredCore` depend on
nothing app-specific; `CaptureKit` depends only on `ShredCore`; UI depends on engines, never
on `CaptureKit` directly. **DetectionKit compiling on Linux is a CI gate** — it guarantees the
purity that fixture testing (NFR-8) and cloud-environment development rely on.

## 3. Data flow

```
CMMotionManager ─┐ (delivery queues)
CMAltimeter ─────┼─► CapturePipeline (actor) ─► FrameBus (AsyncStream, back-pressured)
CLLocationUpdate─┘                                   │
                                   ┌─────────────────┼──────────────────┐
                                   ▼                 ▼                  ▼
                            TelemetryWriter    DetectionRunner    LiveStatsReducer
                            (binary chunks,    (DetectionKit      (speed, counts →
                             5 s batches)       state machines)     Live Activity, UI)
                                                     │
                                                     ▼
                                              EventStore (SwiftData)
```

- `FrameBus` fans out via `AsyncStream` copies with bounded buffers; the writer must never
  block detection and vice versa. Buffer overflow → drop-with-count (never stall the
  delivery queue), counted against NFR-1's 0.1% budget and persisted in session metadata.
- `DetectionRunner` executes DetectionKit incrementally (frame-push API, not batch) so events
  emit within NFR-4's 3 s.

## 4. Concurrency model

- `CapturePipeline`, `TelemetryWriter`, `EventStore` are actors.
- DetectionKit is synchronous pure code called from the `DetectionRunner` actor.
- UI observes `SessionEngine` via `@Observable` snapshots published at ≤ 2 Hz (no per-frame
  UI updates).
- No `DispatchQueue` usage outside CaptureKit's delivery shims; structured concurrency
  (`TaskGroup`) everywhere else.

## 5. Session state machine (SessionEngine)

```
idle → calibrating → active ⇄ autoPaused → ending → summarizing → saved
                     active → recovering (cold-launch after kill) → saved(recovered)
```

Transitions persist a durable `SessionCheckpoint` (JSON, atomic write, every 30 s + on every
transition) enabling FR-4 recovery: on launch, a checkpoint newer than last clean end triggers
`recovering`, which finalizes chunks, backfills from `CMSensorRecorder` (02 §2.5), runs
detection over recovered data, and saves.

## 6. Background execution model

The session's lifeline is **continuous background location** (UIBackgroundModes: location;
`allowsBackgroundLocationUpdates`). While location runs, Core Motion delivery continues in
background. Rules:

- Never stop location updates mid-session (auto-pause reduces *processing*, not the location
  subscription; it may drop accuracy to `kCLLocationAccuracyHundredMeters` during autoPaused
  and restore on resume — battery win without losing the lifeline).
- iOS 26 note: significant-change/region APIs no longer relaunch terminated apps reliably —
  do NOT design recovery around relaunch; recovery is next-user-launch based (FR-4).
- Live Activity is updated from within the app process (≤ 1 update/3 s, budget-aware);
  no push channel needed at v1.
- A `BGProcessingTask` registered for overnight work performs: chunk compaction (NFR-3),
  30-day raw expiry, spot re-clustering, (M5) training-snippet packaging.

## 7. Error taxonomy & watchdogs

- `CaptureError` (sensor unavailable, authorization lost mid-session, delivery stall
  > 2 s) → SessionEngine degrades per 06 §8 matrix and annotates the session.
- Delivery stall watchdog: a 1 Hz heartbeat comparing sensor-clock progress; stall triggers
  restart of the affected CM manager (known iOS behavior after thermal events).
- Thermal: on `.serious` thermal state, drop raw-accel persistence (keep detection) and
  Live Activity rate; annotate session.
- All degradations are visible in the session summary ("partial data" badges) — honest
  accuracy again.

## 8. Configuration & feature flags

`ShredConfig` (bundled JSON + local overrides in Settings debug menu): DetectionTuning
(03), rate limits, compaction windows, feature flags (`ml_reranker`, `share_video`,
`watch_link`). No remote config at v1; the file format must be forward-compatible (unknown
keys ignored) so remote config can arrive without migration.

## 9. Observability

- `os_log` categories per module; signposts around chunk writes and detection batches
  (Instruments-friendly).
- MetricKit subscriber persists battery/hang/crash diagnostics per session → shown in a
  hidden diagnostics screen (Settings ▸ tap version 5×) and attached to user-initiated
  data exports for support.
- Zero third-party analytics (07). Product KPIs come from opt-in local aggregate reporting
  deferred to post-v1 (spec'd separately when needed).

## 10. App shell & navigation

Tab bar: **Sesh** (start/live) · **History** · **Spots** · **You** (PRs, streaks, settings
entry). Deep links: `shred://session/<id>`, `shred://live` (Live Activity tap-through).
State restoration via `SceneStorage` for tab + pushed session id.
