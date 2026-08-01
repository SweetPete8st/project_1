# 05 — Data Model, Storage & Formats

## 1. Units & conventions (project law)

- SI internally everywhere: meters, m/s, m/s², seconds, radians. **g** (9.80665 m/s²) only
  at UI formatting and in the raw accel stream (Core Motion native unit — converted at
  capture boundary; stored as m/s²… no: stored native g as float32 with unit recorded in the
  chunk header; DetectionKit consumes g for accel streams by contract).
- Angles stored radians, displayed degrees. Yaw positive counterclockwise (right-hand,
  z-up), wrapped (−π, π].
- Coordinate frames: `device` (Core Motion axes), `world` (xMagneticNorthZVertical),
  `travel` (x = travel bearing, y = left, z = up). Every vector field name carries its frame
  suffix (`aWorld`, `aTravel`) — a mislabeled frame is the classic IMU bug; naming is the
  guardrail.
- Timestamps: `sensorTime: Double` (seconds since boot) on frames; wall-clock via piecewise
  anchors (02 §6). SwiftData entities store `Date` derived at write time.
- IDs: UUIDv7 everywhere (sortable).

## 2. SwiftData entities

```swift
@Model Session {
  id: UUID; startedAt: Date; endedAt: Date?
  state: SessionState            // saved / savedRecovered / discarded
  pocket: Pocket                 // FL/FR/BL/BR
  declaredStance: Stance         // regular / goofy
  calibration: CalibrationRecord // q_cal, g_cal, quality, re-baseline boundaries
  activeDuration, idleDuration: TimeInterval
  distance: Double; topSpeed: Double; topSpeedValidated: Bool
  stanceRegular, stanceSwitch, stanceIndeterminate: TimeInterval
  ascent, descent: Double
  pushCount: Int; pushCadenceMean: Double?
  frameDropRatio: Double; degradations: [DegradationFlag]
  deviceCapabilities: DeviceCapabilitiesSnapshot  // measured accel clip, models, OS
  tuningVersion: String; appVersion: String
  spot: Spot?                    // relationship
  events: [Event]                // relationship, cascade delete
  chunkManifest: [ChunkRef]      // binary file references + integrity hashes
}

@Model Event {
  id: UUID; session: Session
  kind: EventKind          // airborne, drop, impact, decel, powerslide, push?, bail, rotationOnly
  tStart, tEnd: Double     // sensorTime
  confidence: Double
  metrics: EventMetrics    // Codable payload, kind-specific (see §5)
  userLabel: UserLabel?    // confirm / reclassify(family) / deleted — never mutates detection
  snippetRef: ChunkRef?    // ±3 s two-stream excerpt (FR-38)
  detectorVersion: String; mlModelVersion: String?
}

@Model StanceInterval { session; tStart; tEnd; stance: StanceClass; meanSigma: Double }
@Model Spot { id; name; center: CLLocationCoordinate2D-codable; radius; sessionCount; prCache }
@Model PersonalRecord { metric: PRMetric; value: Double; sessionID; eventID?; spotID?; setAt }
@Model DailyAggregate { day; sessions; activeTime; distance; ollieCount; … } // precomputed for History
```

## 3. Frame types (ShredCore, used by CaptureKit → DetectionKit)

```swift
struct MotionFrame  { sensorTime; userAccel: SIMD3<Float>; gravity: SIMD3<Float>
                      rotationRate: SIMD3<Float>; attitude: simd_quatf }   // 100 Hz
struct RawAccelFrame{ sensorTime; accel: SIMD3<Float> }                     // 100 Hz, g units
struct LocationFix  { sensorTime; lat; lon; hAcc; altitude; vAcc
                      speed; speedAcc; course; courseAcc; flagged: Bool }   // ~1 Hz
struct BaroFrame    { sensorTime; relAltitude: Float; pressure: Float }     // ~1–10 Hz
enum  StreamSource  { iphone, watch(reserved), fixture }                    // 02 §3
```

## 4. Binary telemetry chunk format (`.shredchunk`)

Append-only, one file per (session, stream, 60 s window). Little-endian.

```
Header (64 B): magic "SHRD" | version u16 | streamKind u8 | source u8
               sampleRateNominal f32 | unit u8 | frameSize u16 | frameCount u32
               sensorTimeFirst f64 | wallAnchor f64 | reserved | crc32(header)
Frames: fixed-size packed records; sensorTime stored as u32 delta-µs from previous frame
        (handles jitter, 71 min max delta — fine under 60 s windows)
Footer (16 B): frameCount u32 (redundant) | crc32(payload) | magic "DRHS"
```

- Writer: `TelemetryStore.ChunkWriter` (actor) batches 5 s, `fwrite` to a temp name, atomic
  rename on 60 s close. A torn final chunk after a crash is recovered up to the last valid
  frame (footer missing → scan-forward validation).
- Compaction (NFR-3): after 30 days, continuous-stream chunks are deleted; Event snippets
  (their own small chunks) and all SwiftData entities are kept forever. User setting
  "Keep raw data" disables expiry per-session or globally.
- Integrity: chunk crc32s live in `Session.chunkManifest`; History surfaces a "data damaged"
  badge on mismatch rather than crashing or silently skipping.

Budget check (02 §7): ~26 MB/h raw → 60 s device-motion chunk ≈ 340 KB. Thousands of small
files are fine on APFS; directory layout `Telemetry/<sessionID>/<stream>/<index>.shredchunk`.

## 5. EventMetrics payloads (Codable, versioned by `detectorVersion`)

- `airborne`: { airtime, airtimeUncertainty, estHeight, landingPeakG, landingClipped,
  rotationDeg, rotationBucket, direction(fs/bs)?, family }
- `drop`: airborne fields + { baroDropHeight? }
- `impact`: { peakG, clipped, jerkPeak, context: EventID? }
- `decel`: { deltaV, peakDecel, duration }
- `powerslide`: decel fields + { slideAngleDeg, yawPeakRate }
- `bail`: { severityScore, tumble: Bool, stillnessAfter: TimeInterval }
- `rotationOnly`: { rotationDeg, window }

## 6. Export formats (FR-55)

- **GPX 1.1** for route (with speed extension), one file/session.
- **events.json**: full Event + StanceInterval dump, schema-versioned (`shred.events.v1`).
- **Raw**: zip of `.shredchunk` files + a `manifest.json` describing the format (this section
  is the normative reference; keep `docs/formats/shredchunk.md` generated from it in M3).
- Export is share-sheet based; no server.

## 7. iCloud sync (optional, off by default)

CloudKit private database mirroring SwiftData entities only (never chunk files at v1 —
size). `Session.chunkManifest` marks chunks `localOnly`. Conflict policy: last-writer-wins
per field except userLabel (union). Sync toggle lives in Settings with clear copy (07 §3).

## 8. Migration policy

SwiftData schema versions from day one (`SchemaV1`); every M-milestone that touches entities
adds a migration stage + a fixture-store migration test (08 §6). Chunk format version bumps
require a reader for N−1 forever (readers are cheap; data is user property).
