# 07 — Privacy & Security

Location + motion telemetry of a person's daily movement is among the most sensitive data an
app can hold. SHRED's stance: **local-first, no account, no third-party SDKs, no analytics.**
Privacy is a headline feature and marketing surface.

## 1. Data inventory & residency

| Data | Where it lives | Leaves device? |
|---|---|---|
| Raw motion/telemetry chunks | App container (Telemetry/) | Never (not even iCloud sync at v1) |
| Sessions/events/spots/PRs | SwiftData store | Only if user enables iCloud sync (private DB) |
| Health workout | HealthKit (Apple-managed) | Per user's Health settings |
| Reverse-geocode lookups | Apple CLGeocoder | Coordinates sent to Apple per platform norm; done only when a Spot is created, rate-limited, user-visible in copy |
| Event training snippets | Local; anonymized upload **only** with explicit opt-in (§5) | Opt-in only |

Device-level protections: app container default file protection
`NSFileProtectionCompleteUntilFirstUserAuthentication` (sessions write while locked —
Complete would break background writes), SwiftData store the same.

## 2. Permissions copy (usage strings, must ship verbatim-quality)

- Motion: "SHRED reads motion sensors to detect your ollies, airs, impacts, and stance.
  Motion data stays on your iPhone."
- Location: "Your route, speed, and spots come from GPS during sessions. Location is only
  used while a sesh is running and stays on your iPhone."
- Health: "Save your sessions as workouts so skating counts toward your rings."

## 3. iCloud sync (off by default)

Private CloudKit database, entities only (05 §7). Toggle copy states exactly what syncs and
that raw sensor files never do. Disabling sync offers "remove synced copies" (CloudKit zone
purge).

## 4. User data rights

- Export everything (FR-55): GPX + JSON + raw zip, per session and bulk.
- Delete: per-session, per-spot (removes attribution, not sessions), and "Delete all data"
  (container wipe + CloudKit zone purge + HealthKit samples offer).
- No dark patterns: deletion is one confirm, no retention nag.

## 5. ML training data (M5)

Default: labels/snippets stay local, used for on-device evaluation only. Optional
"Contribute anonymized clips" opt-in uploads *only* the ±3 s inertial snippet + label —
**never location, never timestamps beyond relative, never user/device IDs** (random
per-upload UUID). Uploads batch through a dumb HTTPS endpoint (spec'd at M5; not built
before). Opt-in screen shows an actual sample payload. Revocable; revocation stops future
uploads (already-contributed anonymous clips are non-linkable by design and copy says so).

## 6. Safety feature boundaries (FR-37)

Bail check-in is a **local notification only**. No automatic emergency calls, no SMS, no
location sharing to contacts at v1 — false-positive risk on a phone that reads 6 g on every
curb hop is too high for auto-SOS, and Apple's own crash detection already covers true
emergencies at the system level. The "You good?" notification offers a one-tap shortcut to
the Phone app with an emergency contact prefilled (user-configured, optional).

## 7. App Store privacy label (declare exactly)

- Data Not Collected — if iCloud sync and snippet contribution are both off (default build
  truthfully qualifies; CloudKit private DB is user's own storage).
- With opt-ins: "Health & Fitness / Location — Linked to user? No — Tracking? No."
- No ATT prompt (no tracking, ever). No third-party SDKs to audit — enforced by the
  zero-dependency rule (04 §1).

## 8. Security engineering

- No custom crypto; rely on platform (APFS encryption, CloudKit).
- Chunk integrity crc32 is corruption detection, not security; SwiftData store not
  additionally encrypted (platform protection suffices; document for review).
- URL scheme handlers validate session IDs (UUID parse) — no arbitrary path handling.
- Export zips built in scratch container dir, cleaned after share sheet completion.
- Threat model doc lite: the realistic adversary is (a) a person with the unlocked phone —
  out of scope beyond OS auth; (b) a curious partner with iCloud creds — mitigated by
  sync-off default; (c) us — mitigated by collecting nothing.
