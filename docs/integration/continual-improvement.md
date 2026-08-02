# Continual-Improvement Loop (rider-calibrated tracking)

The feature that grew out of the first three real sessions: SHRED gets tuned to how its
rider actually skates, using the rider's own post-session reports as ground truth.

## In the app (opt-in, off by default)
1. Settings ▸ **Help improve tracking** — flippable any time; nothing is ever sent
   automatically, in either state.
2. After a session (toggle on), the summary shows **"How'd the sesh actually go?"** —
   ollies attempted/landed, bails, a 1–5 "how accurate did it feel", and free-form notes
   ("lots of tic-tacs, dropped 3 curbs, last one was the best"). Saved locally on the
   SessionRecord.
3. **Send for calibration** — an explicit share of a `shred-calibration-report.v1` JSON
   (detection output + self-report + tuning version). Raw telemetry stays local unless the
   rider separately uses the full-data export (FR-55).

## In the toolchain
- Calibration reports pair with the session's raw recording to become labeled fixtures in
  `fixtures-real/` (see the three 2026-08-01 sessions: rider narration → truth.json).
- `shred-replay` scores every tuning change against the whole labeled corpus; CI replays it
  on every push, so improvements for one movement can't silently regress another.
- Threshold changes land in `DetectionTuning.json` — config, not code — and ship in the
  next build.

## Proven by the first three sessions
walking rejection, bail detection, kick-turn pivots, soft-landing ollie detection, attempt
grouping, and the landing thresholds were all (re)tuned from rider reports exactly like
this — recall on rider-confirmed ollie attempts went from 0% (first pocket session, before
real data) to 12/14 across the labeled corpus.
