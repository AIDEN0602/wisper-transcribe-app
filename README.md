# Whisper Apps

Native Apple clients for on-device speech transcription, replacing the
Mac-mini server pipelines (`wisper`, `subwhisper`) so the server can
eventually be turned off.

## Packages

| Path | What | Builds on Mac mini (CLT)? |
| --- | --- | --- |
| `WhisperCore/` | Shared Swift package: WhisperKit wrapper, model management, transcript formatting | ✅ `swift build` |
| `StealthWhisperMac/` | macOS app (window + menu bar): ⌥⌘R → record → on-device transcribe → clipboard, history, shared with the other devices | ❌ needs Xcode (sandbox + iCloud entitlements require signing) |
| `StealthWhisperiOS/` | iPhone + Watch apps (and the dictation keyboard) | ❌ needs Xcode |
| `StealthWhisperWeb/` | Private Cloudflare Worker upload site for the first user | ✅ Node.js + Wrangler |
| `SisterWhisperWeb/` | Independently configured Cloudflare Worker upload site for another user | ✅ Node.js + Wrangler |

Both Xcode projects are generated from `project.yml` by xcodegen, installed
at `~/.local/xcodegen/bin/xcodegen` (no Homebrew on these machines):

```sh
cd StealthWhisperMac && ~/.local/xcodegen/bin/xcodegen generate
xcodebuild -project StealthWhisperMac.xcodeproj -scheme StealthWhisperMac \
  -configuration Release -destination 'platform=macOS' \
  -derivedDataPath build-mac -allowProvisioningUpdates build
```

Generate and build the iPhone, keyboard, and Watch targets:

```sh
cd StealthWhisperiOS
~/.local/xcodegen/bin/xcodegen generate
xcodebuild -project StealthWhisper.xcodeproj -scheme StealthWhisper \
  -configuration Debug -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build
```

Signing for a real iPhone, Apple Watch, TestFlight, and the iCloud container
requires an Apple Developer team. Set the team in `project.yml`, regenerate the
project, and then use Xcode or `xcodebuild -allowProvisioningUpdates`.

## Private web transcription

The two Worker folders contain the same privacy-oriented upload service with
separate names, secrets, and KV databases. Audio is processed in memory and is
not written to KV. Completed transcripts are AES-GCM encrypted and expire from
KV after 24 hours. The authenticated page can copy or download a transcript and
can optionally deliver it through Telegram.

See [`docs/WEB_DEPLOYMENT.md`](docs/WEB_DEPLOYMENT.md) for the complete setup,
deployment, cloning, iPhone Shortcut, and verification instructions.

## How the three apps share history

One entry per transcript, `Documents/History/<uuid>.json`, written to the
iCloud container `iCloud.com.stealth.whisper` when it is available and to a
local folder when it is not. Two things make that actually work, and both
were missing:

- **`com.apple.developer.ubiquity-container-identifiers`.** Without it
  `url(forUbiquityContainerIdentifier:)` returns nil no matter what the
  other iCloud entitlements say. Every target needs it.
- **The Mac mini as the path that always works.** It already stores every
  finished job; `ServerHistorySync` imports them (`GET /jobs`, then
  `GET /download/<job>/full_transcript.txt`) keyed by a job-derived UUID, so
  importing repeatedly never duplicates. The Mac uploads its own recordings
  there as `mac_*.m4a` for the phone and watch to pick up.

## WhisperCore

```sh
cd WhisperCore
swift build
swift run whispercore-cli check                      # smoke tests (no XCTest under CLT)
swift run whispercore-cli transcribe file.m4a --model tiny
```

- Models download on first use from HuggingFace `argmaxinc/whisperkit-coreml`
  into `~/Library/Application Support/WhisperApps/Models/`.
- `WhisperTranscriber` is an actor: `prepare()` (download + load), then
  `transcribe(url, language:)` → `Transcript`.
- `TranscriptFormatter` renders plain text, `[MM:SS - MM:SS]` lines
  (matching the existing server output format), and SRT.
- XCTest targets exist but only run on a machine with full Xcode.

## Compatibility contracts with the existing pipelines

- iCloud container (upload fallback): `iCloud.com.stealth.whisper`, files land
  in `Documents/` as `.m4a`; the Mac watches
  `~/Library/Mobile Documents/iCloud~com~stealth~whisper/Documents/`.
- Server upload fallback: `POST /upload` (multipart field `audio`, form fields
  `diarize`, `express`) on the wisper Flask server, port 8080.
- Transcript line format: `[MM:SS - MM:SS] text` (speaker-labelled variants
  add `SPEAKER_XX:`).
