# Field Validation Protocol (docs/spec/08 §5) — v1, ready for M2 hardware gate

⚠️ HW — requires a human with an iPhone. Prepare per session:

## Setup
- iPhone 14 Pro+ (record model), fixture-recorder debug build (Settings ▸ Diagnostics ▸
  Record fixture), phone camera on a tripod for ground truth, sync beep at start.
- Riders: ≥ 3 (mix regular/goofy). Pockets: all 4 positions across sessions.

## Scripted segments (each session, in order)
1. Calibration flow as prompted; then 30 s cruise.
2. 10 ollies on flat, ≥ 3 s apart.
3. 5 × 180 (mix FS/BS, call them out on camera).
4. Pushes-only lap (count aloud, target 15–20).
5. Powerslide set ×3, then plain footbrake ×2.
6. Walking interlude, 60 s, phone stays pocketed.
7. Re-pocket: move phone to a different pocket, keep skating 2 min.
8. Idle break ≥ 2 min.
9. Free skate ≥ 5 min.

## Auto-start rows (ADR-0004)
- Arm from the toggle, pocket phone, wait 10 s, push off normally — record time-to-confirm
  and backdate accuracy vs camera. Repeat ×5 per pocket, plus gentle-cruise and
  sprint-push variants.
- Negative controls while armed (10 min each): walk, jog, stairs, car ride (passenger),
  bus/bike if available, phone handling. ANY auto-start here is a logged false positive.

## Processing
1. Pull the `.shredfix` recordings; label events against video (`truth.json`).
2. `swift run shred-replay run <recorded-corpus> --report field.json`.
3. Compare against docs/spec/08 §4 targets; tune ONLY via DetectionTuning JSON + replay
   metric diffs in the PR.
4. Battery: full-charge 2 h session → %/h vs NFR-2. Background survival: 3 h locked
   session (FR-3). Kill test: force-quit mid-session, relaunch → recovered summary (FR-4).
