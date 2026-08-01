# 01 — Requirements

Requirement IDs are stable and referenced across all other docs and in code comments/tests
(`// FR-12`). Never renumber; deprecate with strikethrough and append new IDs.

## 1. Functional requirements

### Session lifecycle
- **FR-1** User can start, pause, resume, and end a session with ≤2 taps from app launch.
- **FR-2** Session start runs the pocket-calibration flow (FR-20) unless a valid calibration
  from the last 5 minutes exists.
- **FR-3** A session continues capturing with the phone locked and the app backgrounded for the
  entire session duration (target ≥ 3 h continuous).
- **FR-4** If the app is killed (user or watchdog) mid-session, on next launch the app recovers
  the session: route from persisted chunks, motion gap noted, session marked "recovered".
- **FR-5** Sessions auto-pause when the rider is stationary > 90 s (configurable) and
  auto-resume on motion; idle time is tracked separately from active time.
- **FR-6** A Live Activity shows live session stats (duration, speed, event count) on the Lock
  Screen and Dynamic Island; ending the session is possible from the Live Activity.

### Capture
- **FR-10** Capture device motion (user acceleration, gravity, rotation rate, attitude
  quaternion) at 100 Hz for the full session and persist it losslessly (05 §4).
- **FR-11** Capture raw accelerometer at 100 Hz in parallel (wider range than fused user
  acceleration; used for impact peaks).
- **FR-12** Capture GNSS location at navigation accuracy (dual-frequency L1+L5 where hardware
  supports it) at the OS-delivered rate (~1 Hz), with speed and course.
- **FR-13** Capture barometric relative altitude at the maximum CMAltimeter delivery rate.
- **FR-14** Capture magnetometer-derived heading as delivered by device motion attitude
  (`.xMagneticNorthZVertical` reference frame).
- **FR-15** All capture streams carry both a monotonic timestamp (sensor clock) and a wall-clock
  anchor so streams can be aligned to ±10 ms (05 §2).

### Calibration & stance
- **FR-20** Pocket calibration: user selects pocket (front-left, front-right, back-left,
  back-right) and declares stance (regular or goofy); app captures a 5 s standing-still
  baseline to record the pocket pose quaternion and gravity vector.
- **FR-21** Calibration is validated: if variance during the still window exceeds threshold,
  the flow asks the user to stand still and retries (max 3 attempts, then proceeds degraded
  with stance analytics disabled for the session and a visible notice).
- **FR-22** The app continuously classifies riding intervals as **regular**, **switch**, or
  **indeterminate**, using pocket pose + body yaw vs GPS course (03 §6), and accumulates time
  in each.
- **FR-23** If the phone's in-pocket orientation changes materially mid-session (re-pocketing),
  the app detects the discontinuity and silently re-baselines, marking the interval boundary.

### Detection
- **FR-30** Detect **airborne events** (ollie/air/drop): pop-spike → free-fall window →
  landing-impact signature. Record t_pop, t_land, airtime, estimated height, landing peak g.
- **FR-31** Estimated ollie height uses the ballistic model `h = g·t²/8` on the free-fall
  window and is labeled "est." in UI (documented underestimate for rider center-of-mass).
- **FR-32** Detect **rotation** during airborne windows by integrating world-frame yaw:
  buckets 0° (straight), 180°, 360° with ±35° tolerance; sign gives frontside/backside
  relative to stance.
- **FR-33** Record continuous g-force envelope (1 s max-magnitude downsample for UI); record
  every impact ≥ 4 g as an Impact event with peak value; peaks at API clip are stored as
  `clipped = true` and displayed "≥ ⟨clip⟩ g" (02 §4).
- **FR-34** Detect **hard deceleration** events: sustained longitudinal decel ≤ −2.5 m/s² for
  ≥ 400 ms; record duration, Δv, peak decel.
- **FR-35** Detect **powerslides**: hard decel coincident with yaw-rate spike ≥ 120°/s and
  lateral acceleration signature; classified separately from plain braking/footbrake.
- **FR-36** Detect **pushes** (kick strokes) and report count + cadence.
- **FR-37** Detect probable **bails/falls**: impact ≥ threshold with tumbling rotation and
  ≥ 3 s post-event stillness → mark event; if stillness ≥ 30 s, fire a local notification
  "You good?" (no auto-SOS in v1; see 07 §6).
- **FR-38** Every detected event stores a ±3 s window of the underlying 100 Hz motion data
  (an "event snippet") for detail rendering, replay, user confirmation, and ML training.
- **FR-39** Users can confirm, reclassify (from the trick-family list), or delete any detected
  event; edits are stored as labels alongside, never overwriting, the raw detection (03 §8).

### Route & environment
- **FR-45** Persist the full route; render polyline with speed-gradient coloring on the summary
  map; compute distance, top speed (GNSS-validated, 03 §7), moving average speed.
- **FR-46** Compute the elevation profile from fused barometer + GNSS altitude; report total
  descent/ascent and biggest continuous descent.
- **FR-47** Cluster dwell zones (≥ 10 min within 75 m radius) into named "Spots" (reverse
  geocoded, user-renamable); sessions and PRs are attributable per-spot.

### History & analytics
- **FR-50** Session summary screen per 06 §5: stat header, map, event timeline, stance donut,
  speed/elevation chart, PR callouts.
- **FR-51** Personal records tracked globally and per-spot: longest airtime, highest est.
  height, top speed, most ollies/session, longest session, biggest decel.
- **FR-52** History: calendar + list of sessions, weekly/monthly aggregate stats, streaks.
- **FR-53** Sessions save to HealthKit as a `skatingSports` workout with distance and active
  energy (opt-in).
- **FR-54** Session-card export: rendered image (and Phase-2 video) with map, headline stats,
  and selected trick highlights; share sheet.
- **FR-55** Full data export per session (GPX for route + JSON events + optional raw binary) —
  privacy requirement, see 07 §4.

## 2. Non-functional requirements

- **NFR-1 Performance:** capture pipeline sustains 100 Hz × 2 streams with zero sample drops
  over 3 h (drop budget: < 0.1% frames/session, measured and stored per session).
- **NFR-2 Battery:** ≤ 10%/h screen-off capture on iPhone 17; ≤ 14%/h on iPhone 14 Pro.
- **NFR-3 Storage:** ≤ 60 MB/h raw telemetry; automatic raw-data compaction after 30 days
  (keep events + snippets + aggregates, drop continuous streams) unless user opts to keep.
- **NFR-4 Latency:** detection is near-real-time; an event surfaces in the Live Activity ≤ 3 s
  after the landing.
- **NFR-5 Concurrency:** Swift 6 strict concurrency, no data races (build with
  `-strict-concurrency=complete`, zero warnings).
- **NFR-6 Privacy:** on-device by default; no network calls required for any v1 feature except
  optional iCloud sync and reverse geocoding (07).
- **NFR-7 Reliability:** crash-free session rate ≥ 99.8%; watchdog-safe (no main-thread work in
  the capture path).
- **NFR-8 Testability:** the entire detection pipeline runs headless against recorded fixtures
  (no device, no simulator sensors) — see 08. This is a hard requirement because the
  implementing environment has no iPhone.
- **NFR-9 Accessibility:** Dynamic Type through XL, VoiceOver labels on all stats, no
  color-only encodings (speed heat also varies line width).
- **NFR-10 Localization-ready:** all strings in String Catalogs; v1 ships English.
- **NFR-11 Device floor:** app must degrade gracefully on non-Pro/older devices: no
  dual-frequency GNSS → wider speed error bands shown; no barometer failure mode (all target
  devices have one) but altimeter authorization denial → elevation features hidden.

## 3. Assumptions & constraints

- **A-1** Public Core Motion on iPhone caps at 100 Hz (CMMotionManager / device motion). The
  256 g high-g accelerometer and 800 Hz batched pipeline that power system crash detection are
  **not exposed** to third-party iPhone apps (CMBatchedSensorManager is Apple Watch-only as of
  iOS 26). All detection algorithms in 03 are designed for 100 Hz and validated at 100 Hz.
  If Apple opens higher-rate iPhone APIs, capture upgrades transparently (02 §3 runtime probe)
  — algorithms must be sample-rate-parameterized, never hardcoded to 100 Hz.
- **A-2** GNSS delivery is ~1 Hz; speed between fixes is inertially interpolated (03 §7).
- **A-3** A pocketed phone measures the **rider's thigh**, not the board. Board-only motion
  (e.g., the board flipping under the rider) is invisible; this bounds v1 trick taxonomy to
  rider-body-observable families (00 §4).
- **A-4** Sessions happen outdoors with usable GNSS; indoor skateparks degrade to
  inertial-only mode (route/speed features suppressed, trick detection unaffected).
