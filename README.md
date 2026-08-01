# SHRED — Skateboarding High-Rate Event Detection

**SHRED** is a production iOS application that turns an iPhone riding in your pocket into a
full skateboarding telemetry rig: g-force, ollie/airtime detection, speed, deceleration and
powerslides, GPS route mapping, regular-vs-switch stance time (calibrated from the pocket the
phone was placed in), spin/rotation tracking, elevation, pushes, automatic session start from
your push rhythm, and session analytics.

No board-mounted hardware. No account. Everything on-device.

## Status

Implemented and verified (Swift 6, strict concurrency, **41 tests green on Linux**, synthetic
replay corpus passing every accuracy gate):

- **ShredCore** — portable math/frame/tuning types
- **TelemetryStore** — `.shredchunk` binary telemetry codec (crc32, torn-write recovery),
  chunk store, checkpoints, fixture bundles
- **DetectionKit** — the full pipeline: activity segmentation, airborne (ollie/drop) with
  in-flight rotation, impacts with clip labeling, pocket-calibrated stance, Kalman speed
  fusion + powerslide discrimination, pushes, bails, elevation fusion, event arbitration —
  plus the placement-independent **AutoStartDetector**
- **SessionEngine** — session lifecycle actor (manual + auto-start paths, backdating,
  duplicate prevention, chunked persistence, kill recovery)
- **RouteKit** — routes, distance, simplification, spot clustering
- **SynthKit / fixture-synth / shred-replay** — physically-modeled synthetic corpus +
  scoring harness with hard accuracy gates (CI-enforced)
- **iOS layer** — CaptureKit (Core Motion/Location adapters), HealthBridge, FeatureUI
  (SwiftUI app: onboarding-lite home, calibration flow, live screen, summary with map /
  stance donut / charts / timeline, history, PRs, settings), Live Activity, app target

Synthetic corpus metrics (gate-enforced in CI): airborne/drop/powerslide/decel/bail
**1.000 precision & recall**, airtime MAE **1 ms**, rotation buckets **100%**, stance time
**0.966**. Real-world validation is the next milestone — see `docs/field-protocol.md`
(these numbers are synthetic-tier; field targets live in docs/spec/08 §4).

## Building

**Core (any platform, incl. Linux):**
```sh
swift build && swift test
swift run fixture-synth fixtures
swift run shred-replay run fixtures --gates
```

**iOS app (Mac + Xcode 16+):**
```sh
brew install xcodegen
xcodegen generate
open Shred.xcodeproj    # scheme: Shred
```

The iOS layer was authored in a Linux environment and compiles there only as guarded stubs —
its first Xcode build may need small fixes; everything below FeatureUI is machine-verified.

## Repository layout

```
docs/spec/            Product specification (00–09; start at 00-product-overview.md)
docs/decisions/       ADRs — deviations from spec, with rationale
docs/integration/     Auto-start feature integration report
docs/field-protocol.md  Hardware validation script (M2 gate)
Sources/              SPM targets (see docs/decisions/ADR-0001)
Tests/                swift-testing suites
App/                  iOS app + Live Activity extension (XcodeGen: project.yml)
fixtures/             Synthetic corpus (regenerate with fixture-synth)
```
