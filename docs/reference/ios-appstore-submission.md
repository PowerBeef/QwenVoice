# iOS App Store submission runbook

The end-to-end steps to ship **Vocello for iPhone** (`com.patricedery.vocello`) to TestFlight / the App Store. The app code, assets, privacy manifest, entitlements, the in-app privacy link, and a signed-archive CI lane are all in place (see the iOS readiness work). What remains is **credential-bound**: it needs the maintainer's Apple Developer account. This doc is the checklist for those steps.

Source-of-truth rule: if this disagrees with the code, the code wins.

This runbook is release-only. Commits, pushes, pull requests, merges, CI, archive, and TestFlight
packaging use deterministic verification and do not require a phone, models, or XCUITest evidence.
Physical-device UI results are optional explicit frontend QA artifacts.

**Verified on device (2026-06-13, iPhone 17 Pro):** the development build signs, installs, and runs
end-to-end. `scripts/ios_device.sh` now **auto-derives the signing team** from the keychain's Apple
Development certificate (no `QWENVOICE_DEVELOPMENT_TEAM` needed for local dev builds; it also falls back to
offline manual signing if no Apple ID is in Xcode). The development provisioning profile already carries
`increased-memory-limit`, and on-device generation is healthy — RTF ~1.8 warm, ~2.7 GB peak (well within the
8 GB-class iPhone budget), 0 memory trims, and audio-QC pass. Physical-device XCUITest can be run
independently when explicit frontend acceptance is requested; ordinary GitHub CI and archive
packaging are deterministic-only — see
[`testing-runbook.md`](testing-runbook.md); and the UI
holds with no clipping at the largest accessibility Dynamic Type size. **Still maintainer-only below:** the
**Distribution** cert + **App Store** provisioning profile (regenerated to carry `increased-memory-limit`) +
the ASC record/metadata/upload.

## 0. One-time account prerequisites

- [ ] Apple Developer Program membership active; latest Program License Agreement accepted.
- [ ] **iOS Distribution certificate** created (Developer portal → Certificates → Apple Distribution).
- [ ] App ID `com.patricedery.vocello` has **App Groups** + **Increased Memory Limit** capabilities enabled.
      The `increased-memory-limit` capability is self-serve (no Apple review). It MUST be on the App Store
      provisioning profile or the ~2.3 GB model load is Jetsam-killed on a signed build.
- [ ] **App Store provisioning profile** for `com.patricedery.vocello` (Distribution → App Store), regenerated
      after enabling the capabilities so it carries `increased-memory-limit` + the App Group.
- [ ] App record created in App Store Connect (bundle id `com.patricedery.vocello`, primary language, category).

## 1. Privacy + compliance (App Store Connect)

- [ ] **Privacy Policy URL** = `https://vocello.vercel.app/privacy` (hosted by this repo's website; the in-app
      Settings → About → Privacy Policy row links to the same URL).
- [ ] **App Privacy "nutrition label"**: declare **Data Not Collected**. Vocello collects/transmits nothing;
      mic audio + transcripts + generated audio stay on device; the only network egress is Hugging Face model
      downloads. This matches `Sources/PrivacyInfo.xcprivacy` (no tracking, no collected data types).
- [ ] **Encryption**: `ITSAppUsesNonExemptEncryption=false` is already in `Sources/iOS/Info.plist` → answer
      "No" to non-exempt encryption (only HTTPS + CryptoKit SHA-256 for download integrity).
- [ ] **Age rating** questionnaire (updated 2026 tiers): no UGC, no web access, no ads, no violence/mature
      themes, no data collection → expected **4+**. Answer honestly; the app is a local TTS tool.
- [ ] **Account deletion / Sign in with Apple**: N/A — there is no account and no third-party login.
- [ ] EU DSA trader status: complete if distributing in the EU.

## 2. App Review demo notes (paste into "App Review Information → Notes")

> Vocello generates speech entirely on-device. It ships with **no bundled model weights** to keep the app
> small; on first launch you install a voice model from Settings → Voice models (tap **Install** on
> "Custom Voice"; it downloads a ~2.3 GB 4-bit Speed model from Hugging Face over Wi-Fi, ~1–2 min). After the model
> shows **Active**, open Studio, type a short line, pick a built-in speaker, and tap Generate to hear on-device
> synthesis. Voice Design and Voice Cloning each install their own model the same way. No account or login is
> required. Voice Cloning can record a reference on-device or import WAV, MP3, AIFF, or M4A from Files;
> Microphone + Speech permissions are only requested for the in-app recording/transcription route.

No demo account is needed (no login). Note the model download requirement so the app is not judged
non-functional under Guideline 2.1.

## 3. Screenshots + metadata

- [ ] iPhone screenshots (6.9" and 6.5" required). Capture from the **device** for all
      surfaces (generation, model install, sheets). Studio (with a script + voice), Voice Design, Voice
      Cloning, Voices import/enrollment, History, and model-install Settings. Export named screenshots from a current
      `scripts/ui_test.sh ios smoke` result bundle.
- [ ] App name, subtitle (≤30 chars each), description, keywords (≤100), support URL (the GitHub repo or the
      website), marketing URL (`https://vocello.vercel.app`), copyright.

## 4. Build the signed IPA

Two paths produce the same App-Store-uploadable IPA.

### A. CI (recommended once secrets are set)

Add these repo **Secrets** (Settings → Secrets and variables → Actions):

| Secret | What |
| --- | --- |
| `IOS_DIST_CERT_P12` | base64 of the iOS Distribution `.p12` (`base64 -i dist.p12 \| pbcopy`) |
| `IOS_DIST_CERT_PASSWORD` | the `.p12` export password |
| `IOS_PROVISION_PROFILE` | base64 of the App Store `.mobileprovision` (must carry increased-memory-limit) |
| `QWENVOICE_DEVELOPMENT_TEAM` | the 10-char Apple team id |
| `ASC_API_KEY_ID` / `ASC_API_ISSUER_ID` / `ASC_API_KEY_P8` | App Store Connect API key (id, issuer, base64 of `.p8`) |

Then run the **Release** workflow from the Actions tab with `archive_ios = true` (and `upload_to_testflight = true`
to push straight to TestFlight). This job is gated to manual dispatch only, so it never affects the macOS DMG
release. The workflow archives `VocelloiOS`, asserts the
`increased-memory-limit` entitlement + the bundled catalog, exports via
`ExportOptions-appstore.plist`, uploads the IPA artifact, and (optionally) uploads to TestFlight.

### B. Local (Xcode-logged-in maintainer)

```sh
export QWENVOICE_DEVELOPMENT_TEAM=<your-team-id>
./scripts/regenerate_project.sh
scripts/ios_device.sh preflight
xcodebuild archive -scheme VocelloiOS -destination 'generic/platform=iOS' \
  -archivePath build/ios/Vocello.xcarchive -allowProvisioningUpdates
/usr/libexec/PlistBuddy -c "Add :teamID string $QWENVOICE_DEVELOPMENT_TEAM" ExportOptions-appstore.plist
xcodebuild -exportArchive -archivePath build/ios/Vocello.xcarchive \
  -exportOptionsPlist ExportOptions-appstore.plist -exportPath build/ios/export -allowProvisioningUpdates
```

Then verify (the full, metadata-driven check — author a `release_metadata.txt` capturing your on-device
validation per `scripts/verify_ios_release_archive.sh`'s usage):

```sh
./scripts/check_ios_catalog.sh
./scripts/verify_ios_release_archive.sh build/ios/Vocello.xcarchive build/ios/export release_metadata.txt
```

When frontend acceptance is explicitly requested, run `scripts/ui_test.sh ios smoke` and
`scripts/ui_test.sh ios benchmark` separately; their result bundles do not gate the archive.

Upload the IPA via Transporter or `xcrun altool --upload-app -f build/ios/export/Vocello.ipa -t ios \
  --apiKey <KEY_ID> --apiIssuer <ISSUER_ID>` (with `AuthKey_<KEY_ID>.p8` in `~/.appstoreconnect/private_keys/`).

## 5. Pre-flight (run before every submission)

The repo's standing iOS quality work covers the code side (audio-session lifecycle, accessibility, dismissible
onboarding, error/empty states, portrait lock, privacy link). Before submitting, additionally confirm on a real
device: launch + all 4 tabs; install a model; generate in each mode; import→enroll→clone; record→clone with mic/speech permission
**denial + recovery** via Settings → About → Open iOS Settings; cancel mid-generation; an incoming call mid-record
keeps the take; VoiceOver reads the primary controls; the largest Dynamic Type doesn't clip the composer.

## 6. Submit

App Store Connect → the version → attach the build → Submit for Review. For the first submission, the privacy
URL, age rating, and screenshots must all be set or submission is blocked.
