# ADR-0004: SkatePushAutoStart prototype integration

**Status:** accepted · **Full report:** docs/integration/auto-start.md

The supplied prototype's signal-processing core was sound; its architecture conflicted
with SHRED's. Disposition:

| Prototype file | Decision |
|---|---|
| `SkatePushDetector.swift` (processor half) | **Rewritten** as pure `DetectionKit/AutoStartDetector.swift` — algorithm preserved, two defects fixed (below) |
| `SkatePushDetector.swift` (CMMotionManager half) | **Discarded** — CaptureKit owns collection; arming uses `CoreMotionCapture(sampleRate: 50, armedMode: true)` |
| `SkateSessionController.swift` | **Discarded** — a second session manager; SessionEngine gained `.armed` state + automatic start path instead |
| `SkateBackgroundArmService.swift` | **Replaced** by `FeatureUI/AutoStartBackgroundService.swift` — same BGContinuedProcessingTask approach, state-driven instead of a 1 Hz polling loop |
| `SkatePushDemoView.swift` | **Discarded** — armed states render in SeshHomeView with the app design system |

Defects found in the prototype and fixed in the rewrite (both caught by tests):

1. **Jerk-at-peak bug:** the peak gate required `jerk ≥ 0.85 g/s` *at the local maximum*,
   where the smoothed derivative is ≈ 0 by definition — the prototype would rarely confirm
   on real signals. Fixed: jerk evidence is the max over the ~200 ms rising flank.
2. **Confidence under-scored gentle cruising** (an explicit product requirement): weights
   rebalanced toward cadence/dominance/count; gate 0.72 → 0.68. Negatives are rejected by
   the hard gates (they never accumulate candidates), verified across random orientations.
