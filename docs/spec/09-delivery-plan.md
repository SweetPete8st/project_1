# 09 — Delivery Plan & Execution Guide

Audience: the implementing agent/session. This is your build order. Work milestone by
milestone; each has acceptance criteria (AC) that are verifiable **in a cloud environment
without an iPhone** except where explicitly marked ⚠️ HW (human/hardware gate — prepare the
artifact, a human runs it).

Ground rules:
- Follow the module boundaries in 04 §2 exactly; DetectionKit purity (Linux CI job) is
  non-negotiable from the first commit.
- Requirement IDs (01) go in test names and PR descriptions.
- Never weaken an accuracy target or threshold to make CI green; tuning changes go through
  the replay-harness metric diff (08 §3).
- All thresholds from 03 live in `DetectionTuning.json` from day one.

## M0 — Workspace scaffold (≈ small)

Xcode project + SPM packages skeleton (04 §2), CI (macOS build/test + Linux DetectionKit
job), swift-format/lint config, DesignSystem tokens, empty tab shell.
**AC:** CI green on both jobs; app boots to tab shell in simulator; strict concurrency on.

## M1 — Capture & storage core + fixture infrastructure (the foundation)

- ShredCore types (05 §1/§3), clock anchors, DeviceCapabilities.
- Chunk codec (05 §4) with property tests + torn-write recovery.
- CaptureKit adapters behind protocols (`MotionSource`, `LocationSource`, `BaroSource`) with
  `FakeCaptureKit` scripted implementations.
- `FixtureSynth` generator + first 20 synthetic fixtures (08 §2) covering: clean ollie ×
  airtimes {150…800 ms}, drop, 180/360, powerslide, walking, re-pocket, GPS dropout,
  clipped impact, magnetic anomaly.
- `shred-replay` harness executable (08 §3) — runs even though DetectionKit is still empty
  (emits empty timelines).
**AC:** codec round-trips arbitrary streams; replay harness runs the corpus end-to-end on
Linux CI; NFR-1 drop accounting implemented in the fake-driven pipeline test.

## M2 — Detection pipeline v1 (the heart)

Implement 03 in order: preprocessing (§1) → segmentation (§2) → airborne (§3) → impacts
(§4) → rotation (§5) → arbiter (§12), TDD against synthetic fixtures; golden timelines
reviewed into repo.
**AC:** synthetic-corpus metrics: airborne recall/precision ≥ 0.95/0.95 (synthetic is
clean; real-world targets in 08 §4 apply to the recorded corpus later), airtime MAE ≤ 15 ms
synthetic; replay of 3 h fixture < 60 s. ⚠️ HW: fixture-recorder debug build handed off +
field protocol v1 doc ready; measured accel clip recorded into DeviceCapabilities.

## M3 — Session engine, live UX, summary v1

SessionEngine state machine + checkpoint recovery (04 §5), TelemetryStore SwiftData layer,
calibration flow UI (06 §3), live screen + Live Activity, summary screen sections 1/2/6
(header, map, timeline), History list minimal. Background model wired (04 §6).
**AC:** scripted FakeCaptureKit session runs start→summary in simulator UI test; kill-mid-
session recovery test passes; permission-denial matrix rows implemented + UI-tested.
⚠️ HW: 3 h background survival + battery measurement scripts prepared.

## M4 — Full analytics: stance, speed/decel, route, elevation, pushes

Stance calibration math + interval classifier (03 §6), Kalman speed fusion + decel/
powerslide (03 §7), RouteKit (heat polyline, spots, geocode), elevation fusion (03 §11),
pushes (03 §9), bail detection (03 §10), summary sections 3/4/5, Spots + You tabs, PRs,
DailyAggregates, HealthBridge, export (FR-55).
**AC:** stance synthetic fixtures (all 4 pockets × both stances × both directions) ≥ 0.95
correct; speed fusion vs synthetic truth ≤ 2%; golden summary snapshots. ⚠️ HW: field
protocol round 2 → tune via replay metric diffs to hit 08 §4 on recorded corpus.

## M5 — ML trick-family re-ranker (feature-flagged)

Label flywheel already exists (FR-39 since M3). Build training pipeline (offline, from
contributed/internal snippets), Core ML model + on-device re-ranker integration behind
`ml_reranker` flag, Background Assets delivery, model-version stamping. Privacy opt-in
screen (07 §5) — endpoint spec written at this milestone.
**AC:** re-ranker improves recorded-corpus family precision without recall loss (replay
metric diff is the proof); flag-off build byte-identical behavior.

## M6 — Hardening & release

Share cards (FR-54), iCloud sync (05 §7), compaction BGTask, diagnostics screen, App Store
assets + privacy label (07 §7), paywall infra (00 §8, entitlement-gating only Pro features),
external TestFlight ring.
**AC:** 08 §4 gates met on ≥ 25 external recorded sessions ⚠️ HW; crash-free ≥ 99.8% over
beta; accessibility audit checklist; App Review notes drafted (background location
justification: continuous session tracking, user-initiated, visible Live Activity).

## Sequencing notes for the implementing session

- M1 before any detection work — fixtures are how you'll see anything at all in a cloud
  environment. Resist writing detectors against no data.
- Keep a running `docs/decisions/` ADR log for every deviation from this spec; deviations
  are allowed with recorded rationale, silent drift is not.
- When Apple docs conflict with this spec (APIs move), re-verify with current documentation
  and record an ADR — 02 was researched August 2026.
- Definition of done for every PR: tests named with FR/NFR ids, replay metrics attached if
  DetectionKit touched, no new strict-concurrency warnings, docs updated.

## Out-of-scope backlog (do not build, keep visible)

Apple Watch 800 Hz companion (02 §3), video overlay export, named flip-trick classes,
Android, social feed, remote config, auto-SOS.
