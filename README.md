# Stealth Whisper

Private speech-to-text apps for Mac, iPhone, Apple Watch, and the iOS keyboard.
Record on any supported device, transcribe locally with WhisperKit, copy the
result, and keep one shared history through iCloud. A separate Cloudflare
Worker is included for browser and iPhone Shortcut uploads.

## What is included

| Component | Purpose |
| --- | --- |
| `StealthWhisperMac/` | macOS window and menu bar app with global recording shortcut, local transcription, clipboard copy, audio playback, and history |
| `StealthWhisperiOS/` | iPhone recorder, on-device transcription, history, settings, Watch companion, and voice keyboard extension |
| `StealthWhisperiOS/StealthWhisperWatch/` | Wrist recording with a durable transfer queue to the paired iPhone and shared-history access |
| `StealthWhisperiOS/StealthWhisperKeyboard/` | Voice-first keyboard surface that inserts the latest dictation at the active cursor |
| `WhisperCore/` | Shared Swift package around WhisperKit, model management, transcript formatting, and SRT output |
| `StealthWhisperWeb/` | Password-protected Cloudflare Worker transcription website |
| `SisterWhisperWeb/` | A second isolated Worker configuration for a separate user |

## Install the apps

### Mac

**[Download Stealth Whisper 0.3.0 for Mac](https://github.com/AIDEN0602/wisper-transcribe-app/releases/download/v0.3.0/Stealth-Whisper-0.3.0.dmg)**

The app is signed with a Developer ID certificate and notarized by Apple.
Open the DMG, drag **Stealth Whisper** to **Applications**, and launch it.
The first-run guide will:

1. start the one-time Whisper model download,
2. let you use local-only mode or enter a private server URL, and
3. explain microphone permission and the `⌥⌘R` recording shortcut.

The initial model download can take several minutes. Recording and local
transcription work after the model status changes to ready.

### iPhone and Apple Watch

Build 10 was uploaded to TestFlight on September 17, 2026. Install
[Apple TestFlight](https://apps.apple.com/app/testflight/id899247664) on the
iPhone, sign in with an invited Apple ID, and install or update **Stealth
Whisper** from the TestFlight app. The paired Watch app is included in the same
build and can be enabled from the iPhone Watch app.

TestFlight does not provide a universal download URL for an internal testing
group. The Apple ID must first be added as an internal tester in App Store
Connect. A future public TestFlight link can be added after Apple approves an
external beta group.

## How it works

```text
Mac microphone ───────────────┐
                              ├─> WhisperKit on device ─> transcript + history
iPhone microphone ────────────┤
                              │
Apple Watch ─> paired iPhone ─┘

iOS voice keyboard ─> containing iPhone app ─> insert at active cursor

Browser / iPhone Shortcut ─> Cloudflare Worker AI ─> encrypted 24-hour history
```

- Mac and iPhone transcription work locally after the selected model has been
  downloaded once.
- Watch audio is queued with WatchConnectivity and handed to the paired iPhone.
  Pending files survive relaunch and are removed only after a confirmed handoff.
- Mac, iPhone, and Watch read the same iCloud Documents history when the signed
  apps have access to `iCloud.com.stealth.whisper`.
- Server mode remains an optional fallback for the existing Mac mini workflow.
- The web service is independent from the native app pipeline.

## Requirements

- macOS 14 or newer for the Mac app
- iOS 17 or newer for the iPhone app and keyboard
- watchOS 10 or newer for the Watch app
- Xcode 26 or a compatible recent Xcode release
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)
- An Apple Developer team for physical-device signing, iCloud, App Groups, and
  TestFlight
- Node.js 20 or newer and a Cloudflare account for the optional website

## Build the Mac app

The Xcode project is generated from `project.yml`. Change
`DEVELOPMENT_TEAM` and bundle identifiers there before generating the project;
changes made only in Xcode can be overwritten the next time XcodeGen runs.

```sh
cd StealthWhisperMac
xcodegen generate
xcodebuild \
  -project StealthWhisperMac.xcodeproj \
  -scheme StealthWhisperMac \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath build-mac \
  -allowProvisioningUpdates \
  build
```

The default global recording shortcut is `⌥⌘R`.

To create the signed, Apple-notarized release DMG with the Xcode account on the
Mac:

```sh
StealthWhisperMac/scripts/build_release_dmg.sh 0.3.0 3
```

The result is written to
`StealthWhisperMac/build/Stealth-Whisper-0.3.0.dmg`.

## Build the iPhone, Watch, and keyboard apps

```sh
cd StealthWhisperiOS
xcodegen generate
open StealthWhisper.xcodeproj
```

In Xcode, select your Apple Developer team for the iPhone, Watch, and keyboard
targets. Connect an unlocked iPhone with its paired Watch, select the iPhone as
the run destination, and run the `StealthWhisper` scheme. The Watch app and
keyboard extension are embedded in the iPhone app.

For a signing-free simulator build:

```sh
xcodebuild \
  -project StealthWhisper.xcodeproj \
  -scheme StealthWhisper \
  -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

### Enable the voice keyboard

1. Install and open Stealth Whisper on the iPhone.
2. Go to **Settings → General → Keyboard → Keyboards → Add New Keyboard**.
3. Add **Stealth Whisper** and enable **Full Access**.
4. In the Stealth Whisper app, enable **Keyboard Session**.
5. Return to a text field, switch to the Stealth Whisper keyboard, and use the
   microphone button. The transcript is inserted directly at the cursor.

iOS does not give custom keyboard extensions direct microphone access. The
keyboard therefore coordinates with the containing app through the shared App
Group while the keyboard session is enabled.

## Build and test the shared core

```sh
cd WhisperCore
swift build
swift test
swift run whispercore-cli check
swift run whispercore-cli transcribe recording.m4a --model tiny
```

Whisper models download from `argmaxinc/whisperkit-coreml` on first use and are
stored under `~/Library/Application Support/WhisperApps/Models/`.

## Create the private web service

The included Cloudflare Worker accepts uploads from a password-protected page
or an iPhone Shortcut. Audio is processed in memory and is not written to KV.
Completed transcripts are AES-GCM encrypted and expire after 24 hours.

```sh
cd StealthWhisperWeb
npm install
npm test
npm run check
npx wrangler login
npm run deploy
```

Every deployment needs its own KV namespace, website password, session secret,
and Shortcut token. Do not commit any of those secret values.

Read the complete guide before deploying:
**[Cloudflare website and iPhone Shortcut setup](docs/WEB_DEPLOYMENT.md)**.

## Privacy notes

- Native on-device transcription does not require a paid transcription API.
- iCloud history requires the configured iCloud container and valid signing.
- The optional Mac mini fallback sends audio to the configured private server.
- Cloudflare web transcription sends audio to Workers AI for processing even
  though the application does not persist the original file.
- Telegram delivery is optional and places a transcript on Telegram's servers.
- Never commit Cloudflare secrets, Telegram bot tokens, Apple signing files, or
  private server credentials.

## Verification used for this repository

```sh
cd WhisperCore && swift build && swift test
cd StealthWhisperMac && xcodegen generate && xcodebuild -project StealthWhisperMac.xcodeproj -scheme StealthWhisperMac -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
cd StealthWhisperiOS && xcodegen generate && xcodebuild -project StealthWhisper.xcodeproj -scheme StealthWhisper -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
cd StealthWhisperWeb && npm test && npm run check && npx wrangler deploy --dry-run
```

These checks verify compilation and automated tests. Real microphone input,
Watch-to-iPhone transfer, keyboard insertion, iCloud sync, and TestFlight
installation still require physical-device testing with correctly signed apps.
