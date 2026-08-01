# Automatic Session Start — Integration Report

Feature: *"Automatically detect when I start skating"* — armed passive detection of a
repeated skateboard-push rhythm auto-starts the session timer, backdated to the first push.
Source material: the `SkatePushAutoStart` prototype (see ADR-0004 for the file-by-file
disposition and the two prototype defects fixed during the rewrite).

## Final architecture (layers, per the brief's recommended separation)

1. **Motion collection** — `CaptureKit/CoreMotionCapture(sampleRate: 50, armedMode: true)`:
   device-motion only while armed (no GPS, no altimeter, no raw-accel stream → minimum
   arming power). A confirmed session hands over to the full 100 Hz session capture.
2. **Signal processing / classification** — `DetectionKit/AutoStartDetector`: pure,
   frame-in/decision-out, sample-rate parameterized, zero platform imports. Config in
   `AutoStartConfig` (Codable → remote-config-ready). Independently testable: synthetic
   positives and negatives in `SynthKit/AutoStartScenarios`.
3. **Start decision → domain event** — `AutoStartDetection { firstPushTime, confirmedTime,
   confidence, estimatedPushesPerMinute, pushCount }` (sensor-clock; wall conversion via
   `ClockAnchors`).
4. **Session orchestration** — `SessionEngine` (the app's ONLY session manager) gained:
   `.armed` engine state, `arm()`/`disarm()`, the automatic start path, and
   `StartSource.automatic` + `AutoStartMetadata` on `SessionRecord`. Automatic sessions run
   the same production pathway as manual ones (same pipeline, chunk persistence,
   checkpoints, summary assembly).
5. **Background/lifecycle** — `FeatureUI/AutoStartBackgroundService`
   (BGContinuedProcessingTask, iOS 26+, state-driven completion) + re-arm hooks in
   `AppModel` (launch, session end, setting toggle).
6. **Persistence** — start source, auto metadata, and the backdated timestamps persist in
   the session archive; no separate store.
7. **Diagnostics** — detector `Output` exposes per-frame horizontalG / candidateCount /
   confidence for a future calibration screen; the fixture-recorder debug mode (08 §2)
   doubles as the labeled-session exporter.
8. **User-facing state** — persistent toggle + armed status card in `SeshHomeView`
   ("Armed — listening for pushes"), automatic-start banner on the summary screen showing
   confidence, error states surfaced through `AppModel.lastError`.

## Session behavior (brief checklist → implementation)

- **Timer is the essential behavior** — automatic start requires only motion frames; GPS,
  barometer, calibration all absent by construction in the armed phase.
- **Backdating** — `SessionRecord.startedAtSensor/WatchWall = firstPushTime`; additionally
  the armed phase keeps a ~12 s motion ring buffer that is replayed into the session
  pipeline, so push count / g-envelope / speed cover the backdated span (not just the
  timer).
- **Duplicate prevention** — `startAutomatically` no-ops unless the engine is `.armed`
  (the detector also self-latches); `startSession` while active returns the existing id.
  Test: `continuedPushingAfterAutoStartDoesNotDuplicate`.
- **Manual override** — `startSession` while armed kills the detector and reuses the
  running feed. Test: `manualStartWhileArmedOverridesCleanly`.
- **Placement-independence boundary** — automatic sessions have `calibration == nil`,
  which *structurally* disables stance/pocket-dependent analytics downstream (the stance
  classifier requires a CalibrationRecord to vote at all). The summary carries the
  `calibrationDegraded` flag and explains it in UI copy. Tests assert `pocket == nil`,
  zero stance seconds.
- **Detection stops after start** — the auto detector is discarded on session start; the
  session pipeline's own (different, speed-fused) push counter takes over.
- **Re-arm** — on session end and on app launch when the setting is on.

## Detection quality status

Synthetic validation (13 detector tests + 4 engine integration tests): steady, gentle
(0.24 g), and aggressive pushing detect across random pocket orientations; walking,
jogging, car ride, and hand-fumbling never confirm, also across orientations; broken
rhythm (3 pushes + gap + 3 pushes) never confirms; double-bump pushes count once.
Thresholds remain **field-unvalidated** — the corpus is synthetic. The field protocol
(docs/spec/08 §5) now includes auto-start rows: 20+ real arming sessions per pocket, plus
the negative-control activity script, before the defaults are called production-calibrated.

## Unavoidable iOS limitations (honest UX contract)

- Raw motion cannot wake a suspended app. Arming is a foreground user action; a finite
  background window continues it on iOS 26+ (`BGContinuedProcessingTask`, cancellable by
  the system); on earlier iOS the armed state pauses in background and resumes on
  foreground. The armed card copy never promises always-on listening.
- The armed phase deliberately runs motion-only at 50 Hz; a *backdated* session therefore
  has no GPS points for the pre-confirmation seconds (typically < 5 s). Distance for that
  sliver is inertial-only and negligible; documented here rather than papered over.

## Files added/changed for this feature

- `Sources/DetectionKit/AutoStartDetector.swift` (new)
- `Sources/SynthKit/AutoStartScenarios.swift` (new)
- `Tests/DetectionKitTests/AutoStartDetectorTests.swift` (new)
- `Sources/SessionEngine/SessionEngine.swift` (armed state, automatic path, ring backfill)
- `Sources/SessionEngine/SessionRecord.swift` (StartSource, AutoStartMetadata)
- `Tests/SessionEngineTests/SessionEngineTests.swift` (AutoStartIntegrationTests suite)
- `Sources/FeatureUI/AutoStartBackgroundService.swift` (new)
- `Sources/FeatureUI/AppModel.swift` (setting, arming lifecycle, re-arm)
- `Sources/FeatureUI/SeshViews.swift` (toggle + armed status card)
- `Sources/FeatureUI/SummaryView.swift` (auto-start banner)
- `App/Shred/ShredApp.swift` (BG task registration)
- `project.yml` (BGTaskSchedulerPermittedIdentifiers, background modes, usage strings)
