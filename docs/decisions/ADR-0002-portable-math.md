# ADR-0002: Portable quaternion + DSP (no simd_quatf, no Accelerate)

**Status:** accepted · **Deviates from:** 03 (Foundation+Accelerate allowance)

`simd_quatf` and Accelerate are Apple-only; DetectionKit must compile and test on Linux
(NFR-8 — the implementing environment has no Mac). ShredCore ships a portable `Quaternion`
(stdlib `SIMD3<Float>` for vectors, which IS cross-platform) and DetectionKit hand-rolls
biquads/rings. At 100 Hz × a handful of filters this is microseconds per second of data;
Accelerate would be an optimization without a problem.

Also fixed here: SHRED's acceleration sign convention (userAccel kinematic, gravity toward
earth, raw = user − gravity) with the Core Motion conversion done once in CaptureKit —
see SynthKit/SessionSynthesizer.swift header and CaptureKit/CoreMotionCapture.swift.
