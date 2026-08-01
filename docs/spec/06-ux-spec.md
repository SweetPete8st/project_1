# 06 — UX Specification

Design language: dark-first, high-contrast, "telemetry deck" aesthetic — big numerals,
mono-spaced stat digits, grip-tape black + safety-orange accent (exact tokens in
`FeatureUI/DesignSystem`; all colors semantic, light mode supported). Motion design minimal
during sessions (battery). Every stat view has a VoiceOver sentence form (NFR-9).

## 1. Onboarding (first run)

1. Three-card value pitch (pocket telemetry, honest stats, private by default).
2. Stance setup: "Regular or goofy?" with looping illustration; stored as default
   (changeable per session).
3. Permission pre-prompt explaining Motion & Location before the system dialogs (requested
   lazily at first session start, not here — cards only *explain*).
No account. Onboarding completable in < 30 s.

## 2. Sesh tab (home / start)

- Giant **Start Sesh** button; below: pocket picker (4-position phone-in-pants diagram,
  remembers last), stance chip (defaults from onboarding), today's mini-stats.
- Tapping Start → permission requests if needed → Calibration.

## 3. Calibration flow (FR-20/21)

Full-screen, 3 steps, ~15 s total:
1. "Phone goes in your ⟨front right⟩ pocket" confirm card.
2. "Stand still on your board — 5 seconds" with progress ring; variance failure →
   "Hold still a sec, trying again" (max 3, then degraded-mode notice: "Stance stats off
   this sesh — couldn't get a clean baseline").
3. "Pocket it and push off 🤙" → capture starts on screen lock or 5 s timeout.
Audio + haptic cues at each step so the flow finishes with the phone already pocketed.

## 4. Live session

- **In-app live screen** (rarely watched): elapsed, speed, event ticker, pause/end.
- **Live Activity / Dynamic Island** (primary surface): elapsed, current speed, ollie count,
  last event chip ("360! 0.62 s air"); End button (long-press confirm). Updates ≤ 1/3 s.
- Event haptics/audio: optional "click" through connected audio on detected landing
  (Settings toggle, default off).
- Auto-pause states render in the Live Activity ("Chilling — auto-paused").

## 5. Session summary (the payoff screen)

Order (scrolling):
1. **Header:** duration (active/idle split), distance, top speed (with validation badge),
   event count, calories (if HealthKit on).
2. **Map:** route polyline, speed heat gradient (+ width), event pins (tap → detail),
   spot chip.
3. **Highlights row:** best air (airtime + est. height), biggest impact ("≥16 g" treatment
   when clipped), biggest slide, any PRs (confetti-restrained).
4. **Stance donut:** regular / switch / indeterminate with time labels; first-run tooltip
   explaining how pocket calibration powers this + honest note on fakie ambiguity.
5. **Charts:** speed-over-time with event markers; elevation profile; g-force sparkline.
6. **Event timeline:** chronological cards — kind icon, metrics, confidence treatment
   (solid vs "unconfirmed?" outline). Tap → Event Detail.
7. **Footer actions:** Share card, Export data, "Save to Health", Delete.
Degradation badges (04 §7) appear as a dismissible banner at top ("Partial data: motion gap
04:12–04:58, recovered").

## 6. Event detail

Snippet visualization: 6 s accel/gyro trace with phase shading (pop/flight/land), metric
readouts with uncertainty bands, map micro-context. Actions: **Confirm** ✓, **Reclassify**
(family sheet), **Delete**. Confirmed events show a check; this is deliberately satisfying —
it is also our labeled-data flywheel (03 §8), and the sheet says so ("labels improve
detection — stays on your phone unless you opt in to share").

## 7. History / Spots / You

- **History:** week strip + calendar heat, session list (mini-map thumbnails), monthly
  aggregates. DailyAggregate-backed, instant.
- **Spots:** map + list of clustered spots (FR-47), per-spot PRs and session count; rename;
  merge two spots (long-press).
- **You:** PR wall (global + filter by spot), streaks, totals; Settings entry.

## 8. Permission-denial & degradation matrix (must implement exactly)

| Denied/unavailable | Behavior |
|---|---|
| Motion & Fitness | Hard gate for sessions: explainer screen with Settings deep-link (app is motion-first; no session without it) |
| Location | Sessions run **inertial-only**: no route/speed/spots/stance (stance needs course); banner explains; summary shows what's missing |
| Location "While Using" but Precise off | Route on, spots off, stance off; banner |
| HealthKit | Feature simply hidden after one declined card |
| Notifications | Bail check-in and PR notifications silently skipped |
| Altimeter unavailable | Elevation card hidden |

## 9. Settings

Session defaults (pocket, stance, auto-pause timing), Units (metric/imperial, default by
locale), Health sync, iCloud sync (off default, 05 §7), Data (storage used, keep-raw toggle,
export all, delete all), Landing sound toggle, Diagnostics (hidden 5-tap), About/licenses.

## 10. Empty/edge states

Every list and chart specifies an empty state in Figma-free textual form here: first-run
Sesh tab shows a "how it works" illustration; History empty shows "Your first sesh will live
here"; summary with zero events celebrates mileage instead ("No airs today — 8.4 km cruised")
— the app must never feel broken on a trickless cruise.
