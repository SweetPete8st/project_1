# ADR-0001: Single SPM package with multiple targets

**Status:** accepted · **Deviates from:** 04 §2 (separate local packages under `Packages/`)

One `Package.swift` at the repo root defines every module as a target. The spec's module
boundaries and dependency rules are enforced identically by the target dependency graph
(e.g. DetectionKit still cannot import CaptureKit), but a single `swift build && swift test`
covers the whole core on Linux and in Xcode. Multi-package layout added per-package builds
and cross-references without adding any enforcement the target graph doesn't already give.
