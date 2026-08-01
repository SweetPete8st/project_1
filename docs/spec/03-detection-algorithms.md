# 03 — Detection Algorithms

The detection pipeline is a pure, deterministic, sample-rate-parameterized library
(`DetectionKit`) with **zero** dependencies on Core Motion, Core Location, UIKit, or the file
system. Input: typed frame streams (05 §3). Output: typed events + interval classifications.
This purity is what makes NFR-8 (headless fixture testing) possible — treat it as an
architectural invariant.

All thresholds below are **initial values**, centralized in `DetectionTuning` (a Codable
struct, shipped as a bundled JSON, overridable per-session for A/B fixture evaluation). Tuning
iteration happens against the fixture corpus (08), never by editing constants in code.

Literature grounding: board-mounted IMU studies achieve ~90% true-positive trick detection
with classical thresholds and >95% with small ANNs (Tilt'n'Roll; Corrêa et al. 2017,
arXiv:2005.04186; transfer-learning pipelines 2021). Pocket-mounted sensing is noisier; v1
uses robust physics-first heuristics (this doc) and grows an ML stage (§8) from user-confirmed
labels.

## 1. Signal preprocessing

Input frames at rate `f` (100 Hz nominal).

1. **World-frame projection.** Rotate `userAcceleration` and `rotationRate` into the world
   frame using the attitude quaternion → `aWorld` (x-east-ish, y-north-ish, z-up) and yaw
   rate `ψ̇`.
2. **Magnitudes.** `aMag = ‖userAcceleration‖` (g), `aRawMag = ‖rawAccel‖` (g),
   `ωMag = ‖rotationRate‖`.
3. **Filters.** Precomputed biquad cascades (Butterworth, coefficients derived from `f`):
   - `aLow` : 4th-order low-pass @ 6 Hz on `aWorld` (body dynamics, decel detection)
   - `aBand`: band-pass 8–25 Hz on `aMag` (board vibration signature — rolling produces a
     characteristic 10–20 Hz texture from urethane on pavement; this is the key
     riding-vs-walking discriminator)
   - `jerk` : first difference of `aRawMag × f` (impact sharpness)
4. **Feature ring buffers.** 4 s of preprocessed frames retained for event snippet extraction
   (FR-38) and windowed features: RMS(aBand) over 500 ms, mean/variance of gravity direction
   over 2 s (pocket-pose stability), yaw unwrap accumulator.

## 2. Activity segmentation (riding / idle / walking / airborne-candidate)

A 2 Hz state machine over windowed features:

| State | Enter condition (held 2 s except airborne) |
|---|---|
| **Riding** | RMS(aBand) > θ_vib AND (GNSS speed > 1.2 m/s OR ωMag pattern of pumping) |
| **Walking** | Pedometer cadence > 1.4 Hz AND RMS(aBand) < θ_vib/2 |
| **Idle** | RMS(aBand) < θ_idle AND GNSS speed < 0.5 m/s |
| **Airborne-candidate** | instantaneous, see §3 |

Riding time drives active-time stats and gates every detector below (no ollie detection while
walking — kills the #1 false-positive class: jogging/stair impacts). Idle > 90 s → auto-pause
(FR-5).

## 3. Airborne event detection (ollies, airs, drops) — FR-30

Physics: rider pops (sharp upward impulse), then rider+phone are ballistic (near free-fall:
`aRawMag` ≪ 1 g because the only proper acceleration is air drag/limb motion), then landing
(large spike). In the pocket, free-fall reads ~0.1–0.4 g (leg swing noise) vs ~1 g baseline.

Detector (state machine on 100 Hz frames, all windows in seconds × f):

1. **POP:** `jerk > θ_jerk_pop` AND `aRawMag > 1.8 g` while state = Riding → open candidate,
   record `t_pop`.
2. **FLIGHT:** within 250 ms of pop, `aRawMag < 0.45 g` sustained ≥ 90 ms → confirmed flight,
   `t_up` = start of low-g window. (Drops skip POP: a flight window ≥ 180 ms with no pop
   opens a Drop candidate.)
3. **LAND:** `aRawMag > 2.2 g` with `jerk > θ_jerk_land` ends flight → `t_land`.
   Landing peak g = max over [t_land, t_land + 150 ms] on raw stream; `clipped` per 02 §4.
4. **VALIDATE:** airtime `T = t_land − t_up` must be in [120 ms, 1200 ms] (ollie…big drop);
   post-landing must return to Riding vibration within 1 s (else → bail check §10); reject if
   pedometer stepped during flight.
5. **METRICS:** airtime `T` ± half-window uncertainty; est. height `h = g·T²/8` (both-feet
   ballistic approximation — systematically low vs true board height; UI labels "est.",
   FR-31); rotation from §5; classification:
   - pop present, `h < 0.9 m` bucket → **Ollie/Air**
   - no pop, preceded by riding at edge-height barometer step → **Drop**
   - airtime present during Riding with rotation ≥ 145° → also tagged **180/360** (§5)

Confidence score ∈ [0,1] from margin sizes (how far each gate cleared its threshold);
events < 0.6 render as "unconfirmed" (FR-39).

## 4. Impact & g-force envelope — FR-33

- Continuous envelope: per 1 s bucket, max `aRawMag` → session g-force sparkline.
- Impact events: local maxima ≥ 4 g with ≥ 300 ms separation → Impact{peak, clipped, context}
  where context back-references any overlapping airborne/decel event (a landing's impact is
  attached to its ollie, not duplicated in the timeline).

## 5. Rotation / spin detection — FR-32

During each FLIGHT window: unwrap world-frame yaw ψ (from attitude; fallback: integrate ψ̇ if
magnetic anomaly flag set). `Δψ = ψ(t_land) − ψ(t_up)`, drift-corrected by subtracting the
median pre-pop yaw rate. Buckets: |Δψ| < 60° → 0; 145–215° → 180; 325–395° → 360; else
"partial-N°" (stored, shown raw). Sign × current stance (§6) → frontside/backside label.

Additionally, non-airborne rotation ≥ 160° within 700 ms while Riding = **pivot/slide
rotation** (feeds powerslide detection §7 and no-comply/power-180 family).

## 6. Stance analytics (regular vs switch) — FR-20..23, the pocket-calibration feature

**Calibration (session start):** user picks pocket P ∈ {FL, FR, BL, BR} and stance
S ∈ {regular, goofy}. During the 5 s still window capture the mean attitude quaternion
`q_cal` and gravity direction `g_cal` (phone-in-pocket pose), with variance gate (FR-21).
From P we know which thigh the phone rides and the expected sign of the phone's forward axis
relative to the rider's chest direction. From S we know chest direction vs board direction
when riding "regular".

**Runtime classification (1 Hz over riding intervals):**
1. **Travel bearing** `β`: GNSS course when speedAccuracy is good; else short-horizon bearing
   from consecutive fixes; else indeterminate.
2. **Body facing** `φ`: current yaw (world frame) corrected by the calibrated phone-in-pocket
   offset (`q_cal` decomposed against the standing baseline) → rider chest bearing estimate.
3. **Stance angle** `σ = wrap(φ − β)`. Skating regular (for the declared stance) puts the
   chest roughly perpendicular to travel with a known sign: `σ ∈ [40°, 140°]` → **regular**;
   `σ ∈ [−140°, −40°]` → **switch**; else **indeterminate** (includes fakie ambiguity —
   fakie vs switch cannot be fully separated from thigh yaw alone; counted per the bucket
   the sign indicates and documented in UX copy).
4. **Hysteresis & smoothing:** 5 s majority vote; interval flips require 3 consecutive
   agreeing votes. Store as StanceInterval spans (05).
5. **Re-pocket detection (FR-23):** if the 2 s gravity-direction mean departs `g_cal` by
   > 35° while Idle/Walking and then restabilizes, re-baseline `q_cal` from the next 5 s
   stable window; mark boundary.

**Output:** time regular / switch / indeterminate; % split donut (06); switch-time PR. Sign
conventions for frontside/backside in §5 derive from S.

## 7. Speed, deceleration, powerslides — FR-34/35/45

- **Fused speed:** 1D Kalman filter; predict with world-frame longitudinal acceleration
  (aLow projected onto current travel bearing), correct with GNSS speed (R from
  speedAccuracy²). Output at 10 Hz for charts; top speed = max fused speed that is within
  1.5 m/s of a concurrent valid GNSS speed (prevents inertial-drift fake PRs).
- **Decel events (FR-34):** fused longitudinal accel ≤ −2.5 m/s² sustained ≥ 400 ms →
  event{Δv, peak, duration}.
- **Powerslide (FR-35):** decel event overlapping (±300 ms) a yaw excursion ≥ 120°/s with
  lateral (perpendicular-to-travel) low-passed accel ≥ 0.35 g and aBand texture change
  (sliding urethane reads different 20–40 Hz content than rolling — captured via a second
  band RMS ratio feature) → classify as powerslide, record slide angle (peak yaw excursion).

## 8. ML trick-family classifier (Milestone M5 — designed now, shipped later)

- **Training data:** every user confirm/reclassify action (FR-39) stores the event snippet
  (±3 s, both 100 Hz streams + attitude) with the label, locally; users can opt in to
  contribute anonymized snippets (07 §5).
- **Model:** 1D CNN (≤ 200k params) over 6-channel 100 Hz windows (aRaw xyz + ω xyz),
  Core ML, ANE-eligible, int8-quantized; classes = {ollie, 180, 360, drop, slide, other};
  runs *after* the physics detector as a re-ranker/refiner — physics gates recall, ML
  improves precision and family labeling. Never ship ML as the only detector.
- **Update path:** Background Assets model downloads; model version stamped on every event.

## 9. Push detection — FR-36

While Riding: pushes appear on the pocket leg as periodic 1–2 Hz asymmetric accel dips
(pushing leg) or torso bobs (standing leg) with simultaneous fused-speed upticks ≥ 0.3 m/s.
Detector: matched-filter correlation on aLow vertical + speed-delta gate; count + cadence.
Calibration knows which thigh the phone is on; mongo-pushing skews are absorbed by the
speed-delta gate (documented limitation).

## 10. Bail / fall detection — FR-37

Impact ≥ 6 g (or clipped) NOT preceded by a valid flight window, OR any impact followed by
tumble (ωMag > 400°/s for > 500 ms) → bail candidate. If next 3 s lack Riding/Walking
signature → Bail event (timeline + "shake it off" copy). If stillness ≥ 30 s → local
notification "You good?" tap-through to dismiss or call emergency contact (no auto-dial, 07
§6). Never label bails as tricks; bail wins any event-overlap conflict.

## 11. Elevation & drops — FR-46

Barometric relative altitude low-passed @ 0.5 Hz, fused with GNSS altitude (bias estimation,
GNSS anchors the absolute level, barometer supplies short-term shape). Descent/ascent totals
from the fused profile with 1.5 m hysteresis. Airborne DROP events cross-check the barometer
step within ±2 s (adds confidence + measured drop height, which for drops replaces the
ballistic estimate when available).

## 12. Event arbitration & timeline assembly

Single arbiter merges detector outputs: overlap resolution order = Bail > Airborne(+rotation)
> Powerslide > Decel > Impact > Push. Every survivor becomes an Event row (05 §5) with its
snippet, confidence, and back-references. The arbiter is also pure — fixtures assert on final
timelines, not on individual detector internals (08 §3).
