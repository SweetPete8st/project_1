# 00 — Product Overview

**Product:** SHRED (Skateboarding High-Rate Event Detection)
**Platform:** iOS 26+, optimized for iPhone 17 / 17 Pro / 17 Pro Max (functional on iPhone 14 Pro and later)
**Form factor:** Phone-in-pocket. No board-mounted hardware, no wearable required at v1.
**Status:** Specification v1.0 — ground-up rewrite. All prior designs are superseded and void.

## 1. Vision

Skaters already carry the most capable inertial measurement unit they will ever own. SHRED is
"Strava for street skating": drop the phone in a pocket, tap **Start Sesh**, and skate. When the
session ends, the skater gets a complete telemetry story — every ollie with airtime and estimated
pop height, peak g-forces on landings, top speed and every hard deceleration or powerslide, the
GPS route on a map with a speed heat gradient, how much of the session was ridden regular vs
switch, spins (180s/360s), pushes, elevation, and personal records over time.

The differentiator vs every prior attempt in this category (Syrmo, SPINNAX — board-mounted
sensors; Wheels, Ollee — GPS-centric) is doing **credible trick-level detection from a pocketed
phone alone**, with honest accuracy labeling, on hardware the skater already owns.

## 2. Target users / personas

| Persona | Description | Primary needs |
|---|---|---|
| **Street rat** (core) | Skates street/parks 3–6×/week, films clips, competitive with friends | Trick counts, airtime PRs, stance split, shareable session cards |
| **Commuter/cruiser** | Longboard or cruiser transport | Speed, route, distance, deceleration safety stats, elevation |
| **Comeback skater** | 28–45, returning to skating, fitness-motivated | Session time, calories (HealthKit), streaks, gentle progression |
| **Downhill rider** | Longboard downhill | Top speed accuracy, g-force in corners, decel/slide analytics |

## 3. What the product measures (headline features)

1. **G-force** — continuous g-force envelope; peak impact g on every landing; saturation-aware
   "≥16 g" labeling for impacts beyond the public API range (see 02 §4).
2. **Ollies & airs** — detection of pop → free-fall → landing signatures; count, airtime,
   estimated height, per-trick g on landing.
3. **Speed** — live and max speed via dual-frequency GNSS fused with inertial data.
4. **Deceleration** — braking/slide events, decel curve, powerslide signature detection.
5. **GPS route** — full route polyline, speed heatmap, spot detection (clustered dwell zones).
6. **Stance time (regular vs switch)** — calibrated from the pocket the phone was initially
   placed in plus the rider's declared stance; continuous classification of riding direction
   vs body orientation → time spent regular, switch, and fakie/nollie-ambiguous.
7. **Rotation** — yaw integration during airborne windows → 180/360 spin detection; plus
   full-session board-direction changes.
8. **Elevation** — barometric relative altitude for hills, drops, and route elevation profile.
9. **Pushes** — push (kick) count and cadence from the accelerometer signature.
10. **Session analytics** — duration, active vs idle time, distance, calories (HealthKit
    workout), PR tracking, weekly streaks.

## 4. Explicit non-goals (v1)

- No board-mounted or external sensor support.
- No Apple Watch companion app (Phase 2 candidate; the Watch's 800 Hz batched accelerometer is
  attractive but out of scope — see 02 §3).
- No social network/feed. Share is via rendered session-card image/video export only.
- No named flip-trick classification (kickflip vs heelflip) at launch. v1 ships trick *families*
  (ollie/air, 180, 360, drop, slide). Named-trick ML is Milestone M5 (see 03 §8, 09).
- No Android.

## 5. Competitive landscape (2026)

| Product | Approach | Weakness SHRED exploits |
|---|---|---|
| Syrmo / SPINNAX | Board-mounted IMU riser/sensor | Requires hardware purchase & install; abandoned/niche |
| Wheels: Skate Tracking | Phone GPS session tracker | No trick/inertial detection |
| Ollee | Activity tracker + sharing | No pocket trick detection, no stance analytics |
| Strava (generic) | GPS fitness | Zero skate awareness |

Nobody in the market does **pocket-calibrated stance analytics** or **saturation-aware impact
g-force** — these are SHRED's two novel headline stats.

## 6. Honest-accuracy principle (product law)

Every derived metric in the UI carries a confidence treatment. Detection from a pocketed phone
is inherently noisier than a board-mounted IMU; academic work shows ~90% true-positive trick
detection is achievable with board IMUs, and pocket detection will trail that. The product
**never fakes precision**: airtime shows ±ms band in detail view, uncertain events are labeled
"unconfirmed" and are user-confirmable (which doubles as ML training data collection, 03 §8).
This principle governs UX copy, marketing, and App Review notes.

## 7. Success metrics (product KPIs)

- D30 retention ≥ 25% of activated users (activated = completed ≥1 session with ≥1 detected event).
- Ollie detection recall ≥ 0.90, precision ≥ 0.85 on the field validation corpus (08 §5).
- Session battery burn ≤ 10%/hour on iPhone 17 (NFR-2).
- Crash-free sessions ≥ 99.8%.
- Median time from app install → first completed session < 10 minutes.

## 8. Monetization (informational; build free tier first)

Free: unlimited sessions, live stats, 30-day history. **SHRED Pro** (subscription): unlimited
history, ML trick families, video-overlay export, advanced downhill analytics. Paywall
infrastructure is Milestone M6; nothing before it may depend on entitlements.
