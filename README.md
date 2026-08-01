# SHRED — Skateboarding High-Rate Event Detection

**SHRED** is a production iOS application that turns an iPhone 17 riding in your pocket into a
full skateboarding telemetry rig: g-force, ollie/airtime detection, speed, deceleration and
powerslides, GPS route mapping, regular-vs-switch stance time (calibrated from the pocket the
phone was placed in), spin/rotation tracking, elevation, pushes, and session analytics.

No board-mounted hardware. No account required. Everything on-device by default.

## Repository layout

```
docs/spec/          Full production specification (start at 00-product-overview.md)
docs/spec/00-product-overview.md      Vision, personas, competitive landscape
docs/spec/01-requirements.md          Functional + non-functional requirements (FR/NFR ids)
docs/spec/02-sensor-platform.md       iPhone 17 sensor array, iOS API grounding, sampling plan
docs/spec/03-detection-algorithms.md  Signal pipeline: ollies, g-force, stance, rotation, decel
docs/spec/04-architecture.md          App architecture, modules, concurrency, background model
docs/spec/05-data-model.md            Schemas, binary telemetry format, units, coordinate frames
docs/spec/06-ux-spec.md               Screens, flows, Live Activity, calibration UX
docs/spec/07-privacy-security.md      Permissions, data handling, App Store privacy
docs/spec/08-testing-validation.md    Replay harness, fixtures, field validation protocol, CI
docs/spec/09-delivery-plan.md         Milestones + execution guide for the implementing session
```

## For the implementing session

Read `docs/spec/09-delivery-plan.md` first — it defines milestone order, acceptance criteria,
and how to develop and validate the detection pipeline **without physical hardware** using the
replay harness and recorded sensor fixtures. Requirements are referenced by ID (e.g. FR-12)
throughout; do not renumber them.
