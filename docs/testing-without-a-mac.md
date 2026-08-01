# Getting SHRED on your iPhone with no Mac

The repo's CI Mac does everything: generates the Xcode project, signs with Apple's
cloud-managed certificates, and uploads to TestFlight. Your only job is a one-time setup —
every step below works from a phone browser (a desktop browser is comfier for step 4).

Prerequisite: an active Apple Developer Program membership ($99/yr).

## 1. Find your Team ID
developer.apple.com → Account → Membership details → **Team ID** (10 characters, like
`A1B2C3D4E5`). Save it.

## 2. Register the App ID
developer.apple.com → Account → Certificates, IDs & Profiles → **Identifiers** → **+** →
App IDs → App.
- Bundle ID (explicit): `com.YOURNAME.shred` — remember exactly what you pick.
- Capabilities: enable **HealthKit**. Save.

(No need to register the Live Activity extension ID — cloud signing creates
`com.YOURNAME.shred.ShredLiveActivity` automatically on first archive; if the archive step
complains, register that ID the same way with no extra capabilities.)

## 3. Create the app record
appstoreconnect.apple.com → **Apps** → **+** → New App.
- Platform iOS · Name: anything unique ("SHRED by <you>" is fine — changeable later)
- Bundle ID: pick the one from step 2 · SKU: `shred1` · Full access.

## 4. Create an App Store Connect API key
appstoreconnect.apple.com → Users and Access → **Integrations** → App Store Connect API →
Team Keys → **+**.
- Name: `github-ci` · Access: **App Manager**.
- Note the **Issuer ID** (top of page) and the key's **Key ID**.
- **Download the .p8 file — Apple only offers it once.** Open it in a text editor; you'll
  paste its full contents (including the BEGIN/END lines) as a secret.

## 5. Add GitHub secrets
github.com/SweetPete8st/project_1 → Settings → Secrets and variables → **Actions** →
New repository secret (×4):

| Secret name | Value |
|---|---|
| `APPLE_TEAM_ID` | from step 1 |
| `ASC_ISSUER_ID` | from step 4 |
| `ASC_KEY_ID` | from step 4 |
| `ASC_KEY_P8` | full text of the .p8 file |

Then Secrets and variables → Actions → **Variables** tab → New repository variable:
`BUNDLE_ID_PREFIX` = `com.YOURNAME` (everything before `.shred` in your bundle ID —
the project appends `.Shred`… see note below).

> **Bundle ID note:** the project names the app target `Shred`, so the final bundle ID is
> `<prefix>.Shred`. Register `com.YOURNAME.Shred` in steps 2–3 (capitalization matters on
> GitHub's side only, Apple treats it case-sensitively too — keep them identical).

## 6. Run it
GitHub → **Actions** tab → **TestFlight** workflow → **Run workflow** (branch: main).
~15 min later the build appears in App Store Connect; after Apple's processing (5–15 min)
it shows up in the **TestFlight app** on your iPhone (install it from the App Store, sign
in with the same Apple ID, add yourself as an internal tester under the app's TestFlight
tab the first time). Every later merge to `main` uploads a fresh build automatically.

## 7. The tuning loop (why this is enough to iterate)
- Detection thresholds live in `App/Shred/DetectionTuning.json` — a config change +
  merge = new build on your phone, no code edits.
- Skate with the app, note what it missed or invented, and describe it in a Claude
  session; the fixture corpus + replay harness reproduces and fixes it with measured
  before/after metrics. The full real-rider script is `docs/field-protocol.md`.

## Plan B (same-day, if TestFlight setup snags)
If you have a **Windows PC**: install AltServer (altstore.io), which sideloads a
CI-built unsigned IPA onto your iPhone using a free Apple ID over USB/WiFi (7-day
re-sign, 3-app limit). Ask Claude to add an `unsigned-ipa` artifact step to CI if you
want this route.

## Known limits of CI builds today
- CI Macs run Xcode 16.x → builds target iOS 18 APIs; the iOS-26-only auto-start
  *background continuation* compiles out (arming still works in foreground and re-arms
  on return — the app states this honestly). When GitHub's runners get Xcode 26, it
  lights up with zero code changes.
