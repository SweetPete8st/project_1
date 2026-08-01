# 02 — Sensor Platform & iOS API Grounding

This document is the ground truth for what the hardware and OS actually give us. Every claim
here was re-researched for this spec (August 2026); do not carry over assumptions from any
earlier design.

## 1. iPhone 17 sensor array (what exists in the phone)

| Sensor | iPhone 17 / 17 Pro hardware | Exposed to apps? |
|---|---|---|
| Dual-core accelerometer | High-g part, up to **256 g** (crash detection class) | Partially — public API delivers the *low-g fused range* (~±16 g practical clip); the 256 g range is system-reserved |
| High dynamic range gyroscope | Extreme-rate capable (crash detection class) | Via Core Motion rotation rate; practical clip ~±2000°/s |
| Barometer | Relative + absolute altitude | Yes (CMAltimeter) |
| Magnetometer | 3-axis compass | Yes (calibrated via device motion attitude) |
| GNSS | Dual-frequency **L1 + L5** (Pro; GPS/Galileo/GLONASS/BeiDou/QZSS) | Yes (Core Location; sub-3 m typical, sub-meter ideal open sky) |
| Proximity / ambient light | Present | Not needed (pocket state comes from motion + screen state) |
| UWB (U-series) | Present | Not used in v1 |
| N1 networking chip | Wi-Fi 7 / BT6 | Not used in v1 (Watch/peripheral Phase 2) |

**Design consequence:** the "full sensor array" pitch is delivered through five app-visible
streams — device motion (100 Hz), raw accelerometer (100 Hz), GNSS (~1 Hz), barometer
(~1–10 Hz event-driven), and heading (from attitude). Everything in 03 is built on exactly
these five.

## 2. Core Motion capture plan

### 2.1 Primary stream — Device Motion (100 Hz)
`CMMotionManager.startDeviceMotionUpdates(using: .xMagneticNorthZVertical, to: queue)`

- `deviceMotionUpdateInterval = 1.0 / 100.0` — 100 Hz is the vetted per-sample ceiling for
  third-party iPhone apps.
- Delivers per frame: `userAcceleration` (gravity-removed, g units), `gravity` (unit g vector),
  `rotationRate` (rad/s, bias-corrected), `attitude` (quaternion vs magnetic-north world
  frame), `timestamp` (seconds since boot, sensor clock), `heading`.
- The `.xMagneticNorthZVertical` reference frame gives us world-frame yaw for free — required
  by stance (03 §6) and rotation (03 §5) detection. It activates magnetometer fusion; expect
  the calibration figure-8 prompt to be unnecessary in practice but handle
  `CMErrorDeviceRequiresMovement`.

### 2.2 Secondary stream — Raw Accelerometer (100 Hz)
`CMMotionManager.startAccelerometerUpdates(to:)` at 100 Hz, in parallel with device motion.

Rationale: `userAcceleration` is a *fused, filtered* signal — impact peaks are attenuated by
the fusion filter. The raw accelerometer preserves sharper transients and a wider usable range.
Impact metrics (FR-33) read peaks from this stream; event *shape* detection uses the fused
stream. Both are persisted.

### 2.3 Altimeter
`CMAltimeter.startRelativeAltitudeUpdates` (relative pressure/altitude, high resolution, used
for elevation profile and drop measurement) **and** `startAbsoluteAltitudeUpdates` (fused
absolute altitude, used to anchor the profile). Requires `NSMotionUsageDescription` coverage
and `CMAltimeter.isRelativeAltitudeAvailable()` guards.

### 2.4 Pedometer (cross-check only)
`CMPedometer` runs during sessions purely as a *negative* signal: high step cadence + low
board vibration signature = walking, feeding the auto-pause/idle classifier (03 §2). Push
detection does NOT use pedometer (pushes are not steps; 03 §9 has its own detector).

### 2.5 Sensor recorder (crash-recovery net)
`CMSensorRecorder.recordAccelerometer(forDuration:)` (50 Hz, system-buffered) is armed for the
expected session length at session start. If the app dies mid-session (FR-4), recovery pulls
the missed accelerometer interval from the recorder so event *counts* can be backfilled at
degraded fidelity (no gyro → no rotation/stance for the gap; gap is marked in the timeline).

## 3. The 800 Hz question (settled)

`CMBatchedSensorManager` (800 Hz accelerometer / 200 Hz device motion, WWDC23) is
**Apple Watch–only** (Series 8/Ultra and later). It does not exist for third-party use on
iPhone as of iOS 26. Therefore:

1. All iPhone detection algorithms are specified and validated at **100 Hz** (03).
2. `CaptureKit` must expose sample rate as a stream property, and every algorithm parameter
   expressed in samples must derive from seconds × rate (NFR-8 fixtures replay at arbitrary
   rates). If Apple ever ships high-rate iPhone access, capture upgrades via a runtime
   capability probe (`if #available` + availability check) with zero algorithm rewrites.
3. A Phase-2 Watch companion can contribute 800 Hz wrist data; the data model (05) already
   reserves a `source` field per stream so this lands without migration.

## 4. G-force truth: the 256 g accelerometer vs the API clip

The iPhone 17's headline 256 g accelerometer feeds **system** crash detection; public Core
Motion clips far lower (±8 to ±16 g depending on model/stream — the exact clip must be
measured on hardware during M2 and stored in `DeviceCapabilities`). SHRED's policy:

- Report impact peaks from the raw stream up to the measured clip.
- When ≥ 99% of clip is touched for ≥ 2 consecutive samples, set `clipped = true` on the
  Impact event; UI renders "**≥ 16 g**" (measured clip value), never a fake larger number.
- A *saturation-duration heuristic* (time-at-clip × ringdown decay fit) produces an internal
  severity score used only for bail detection ranking (FR-37), never shown as a g number.

This is the honest-accuracy principle (00 §6) applied to hardware marketing numbers.

## 5. Core Location plan

- Modern async API: `CLLocationUpdate.liveUpdates(.fitness)` consumed by an `AsyncSequence`
  task inside `CaptureKit` (fallback to `CLLocationManager` delegate on any regression —
  wrap behind protocol `LocationSource`).
- `CLLocationManager` still owns configuration: `desiredAccuracy =
  kCLLocationAccuracyBestForNavigation`, `activityType = .fitness`,
  `allowsBackgroundLocationUpdates = true`, `pausesLocationUpdatesAutomatically = false`
  (we implement our own auto-pause, FR-5; OS auto-pause would kill background runtime).
- Authorization: request **When In Use** at first session; sessions run with the app
  foreground-launched, and the background location entitlement + active session keeps
  delivery alive when locked (this is the app's background lifeline — see 04 §6).
- Each fix persists: coordinate, horizontalAccuracy, altitude ± verticalAccuracy, speed ±
  speedAccuracy, course ± courseAccuracy, timestamp. Fixes with `horizontalAccuracy > 20 m`
  or negative speedAccuracy are stored but flagged; detection consumes only unflagged fixes.
- Dual-frequency L1+L5 (iPhone 14 Pro+) is automatic — no API switch — but expect visibly
  better urban multipath behavior on Pro devices; NFR-11 requires wider displayed error bands
  when `speedAccuracy` is poor, not device-model sniffing.

## 6. Stream timing & alignment

- Sensor clock: Core Motion `timestamp` is seconds since boot; Core Location timestamps are
  wall-clock `Date`s. At session start record the anchor pair
  `(ProcessInfo.systemUptime, Date())`; every persisted frame stores the sensor-clock time,
  and the anchor converts to wall clock at read time (FR-15).
- Handle clock anchor drift on long sessions by re-recording the anchor every 10 min; use
  piecewise anchors at read time.
- Delivery queues: one dedicated high-priority `OperationQueue` (maxConcurrentOperationCount
  = 1) per motion stream, handing off immediately to the `CapturePipeline` actor (04 §4).
  No processing on the delivery queue beyond enqueue.

## 7. Sampling & power budget (NFR-2 backing math)

| Stream | Rate | Bytes/frame (05 §4) | MB/hour |
|---|---|---|---|
| Device motion | 100 Hz | 4 (ts-delta) + 13×4 floats = 56 | ~20 |
| Raw accel | 100 Hz | 4 + 3×4 = 16 | ~5.8 |
| GNSS | ~1 Hz | 64 | ~0.23 |
| Barometer | ~10 Hz | 12 | ~0.43 |
| **Total raw** | | | **~26 MB/h** (within NFR-3 with headroom) |

Power: continuous 100 Hz motion + BestForNavigation GNSS is the dominant draw. Measured
budget check is an M2 exit criterion on hardware; the pipeline must not add CPU wake-ups
beyond delivery (batch writes every 5 s, coalesced; no timers faster than 1 Hz outside the
delivery path).

## 8. Permission & capability matrix

| Capability | Key / entitlement | When requested |
|---|---|---|
| Motion & fitness | `NSMotionUsageDescription` | Pocket-calibration step of first session |
| Location When-In-Use | `NSLocationWhenInUseUsageDescription` | First session start |
| Background location | UIBackgroundModes `location` | Build-time |
| HealthKit (write workout) | HealthKit entitlement + usage strings | First session summary, opt-in card |
| Notifications (local) | Provisional → full | After first detected bail or first summary |
| iCloud (CloudKit private) | Optional, off by default | Settings toggle only |

Every permission has a written denial path in 06 §8 — the app must remain useful (inertial-only
or route-only) under any single denial.
