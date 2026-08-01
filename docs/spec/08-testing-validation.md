# 08 — Testing & Validation

Governing constraint (NFR-8): the implementing environment is cloud-based with **no iPhone,
no simulator sensor injection**. Therefore the pipeline is built fixture-first: DetectionKit
is pure and replayable, and hardware-dependent code is isolated behind protocols with
scripted fakes. Real-device validation happens at defined human-in-the-loop gates (§5) —
the implementing session must prepare those protocols as runnable checklists, not perform
them.

## 1. Test pyramid

| Layer | Tool | What |
|---|---|---|
| Unit (pure) | swift-testing | DSP filters (coefficient + impulse-response asserts), state machines, arbiter, Kalman, chunk codec round-trip, stance math with synthetic quaternions |
| Replay (pure) | swift-testing + fixture corpus | Full pipeline: fixture in → asserted event timeline out (golden JSON, reviewed diffs) |
| Property | swift-testing custom generators | Chunk codec (arbitrary frame sequences), yaw unwrap (random walks), timestamp anchors (drifted clocks) |
| Integration | XCTest on macOS/Catalyst where possible | TelemetryStore + SwiftData flows, recovery from torn chunks, migrations |
| UI | XCUITest, simulator | Navigation, calibration flow (with FakeCaptureKit), permission-denial matrix (06 §8), snapshot tests for summary components |
| Device (human gate) | Field protocol | §5 |

CI (GitHub Actions): macOS runner for the app + packages; **Linux job compiling & testing
DetectionKit + ShredCore** (purity gate, 04 §2). PRs blocked on all green + zero
strict-concurrency warnings.

## 2. Fixture corpus (`fixtures/`)

Format: `.shredfix` = zip of `.shredchunk` streams + `truth.json` (hand/video-labeled ground
truth events, stance intervals, route stats) + `meta.json` (device, pocket, stance, notes).

Two provenances:
1. **Synthetic** (buildable now, in-repo): `FixtureSynth` tool (SPM executable, part of M1)
   generates physically-modeled sessions — ballistic flights with configurable airtime +
   noise, pop/land impulse shapes from literature-typical profiles, riding vibration as
   band-limited noise, GPS tracks with realistic accuracy jitter, stance geometry from
   quaternion composition. Synthetic fixtures make TDD of every detector possible with zero
   hardware, and encode edge cases at will (clipped impacts, magnetic anomalies, re-pockets,
   tunnel GPS loss).
2. **Recorded** (from the field, M2+): the app ships an internal **Fixture Recorder** debug
   mode (Settings ▸ Diagnostics) that captures sessions with a videotimestamp sync beep so a
   human labeler can align video ground truth. Recorded fixtures graduate into the corpus in
   a `fixtures-real/` LFS-backed directory.

Golden rule: **every detection bug fix starts with a fixture that reproduces it.**

## 3. Replay harness

`shred-replay` (SPM executable): `shred-replay run fixtures/ --tuning DetectionTuning.json
--report out.json` — streams fixtures through DetectionKit at configurable rates, emits
per-fixture timelines + corpus-level metrics (precision/recall per event kind, airtime MAE,
stance time accuracy, top-speed error). CI runs it on every PR and posts the metric table;
regressions beyond thresholds fail the build. This is also the tuning tool (03 preamble):
tuning PRs show metric diffs, not vibes.

## 4. Accuracy targets (release gates, measured on the recorded corpus)

| Metric | Target |
|---|---|
| Airborne event recall / precision | ≥ 0.90 / ≥ 0.85 |
| Airtime MAE | ≤ 30 ms |
| Rotation bucket accuracy (airborne) | ≥ 0.85 |
| Stance time correctly attributed | ≥ 0.90 of determinate time; indeterminate ≤ 20% of riding time |
| Top speed vs RTK/reference | ≤ 3% error open sky |
| Push count error | ≤ 15% |
| Powerslide precision | ≥ 0.80 |
| False bail notifications | ≤ 1 per 10 sessions |

## 5. Field validation protocol (human gate, per milestone M2/M4/M6)

Runnable checklist the implementing session must keep updated in `docs/field-protocol.md`:
- 3+ skaters (mix regular/goofy), 4 pocket positions, ≥ 10 sessions, ≥ 2 spot types
  (street, park), phone-camera ground truth with sync beep.
- Scripted segments per session: 10 ollies, 5 × 180s, pushes-only lap, powerslide set,
  walking interlude, phone re-pocket, idle break.
- Label with the corpus tooling; run `shred-replay`; publish metric table vs §4.
- Battery: full-charge 2 h session, report %/h vs NFR-2 (Instruments + MetricKit).
- 3 h background survival test (FR-3) and kill-recovery test (FR-4) scripts.

## 6. Non-detection test musts

- Chunk torn-write recovery (kill writer mid-chunk in test, §05 §4).
- SwiftData migration test per schema stage against a fixture store.
- Timestamp anchor drift (simulated 50 ppm clock skew over 3 h).
- Thermal degradation path (inject `.serious`) keeps detection alive minus raw persistence.
- Live Activity update budget compliance (rate-limit unit test on the reducer).
- Permission matrix UI tests: all 6 rows of 06 §8.
- Performance: replay 3 h fixture in < 60 s on CI (detection is ~O(n); catches accidental
  quadratic buffers), allocation-count regression harness on the hot path.

## 7. Beta program

TestFlight, two rings: internal (fixture-recorder builds) → external beta at M6 with
in-app "report bad detection" (attaches event snippet + label locally; user shares
manually — consistent with 07). Beta exit = §4 targets met on ≥ 25 external-beta recorded
sessions + crash-free ≥ 99.8%.
