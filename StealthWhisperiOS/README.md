# Stealth Whisper — iOS + watchOS

1. Regenerate the Xcode project after any `project.yml` change:
   `xcodegen generate` (run from this folder).
2. Open `StealthWhisper.xcodeproj` in Xcode.
3. Select the `StealthWhisper` project in the navigator, then each target
   (`StealthWhisper`, `StealthWhisperWatch`) → **Signing & Capabilities**.
4. Sign in with your Apple ID: Xcode → Settings → Accounts → add account.
5. Pick your Team in the dropdown for both targets (leave Bundle
   Identifier as-is unless you changed it in `project.yml`).
6. Plug in your iPhone (and pair your Apple Watch to it), select it as
   the run destination, and press Run — the watch app installs
   automatically alongside the iOS app.
7. For TestFlight: Product → Archive → Distribute App → TestFlight &
   App Store, using the same signed-in Apple ID/team.
8. Simulator builds don't need a team:
   `xcodebuild -scheme StealthWhisper -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO`.
9. "Server mode" (Settings sheet, off by default) copies recordings to
   the legacy iCloud container for the Mac-mini pipeline (adds
   diarization + summary); on-device transcription via WhisperCore
   always runs regardless of this toggle, and is transcript-only for now.
10. First transcription on a fresh install downloads the selected
    Whisper model (see Settings → Whisper Model) — needs a network
    connection once, then works fully offline.
11. History syncs across iPhone/Watch/Mac via iCloud Documents (not
    CloudKit), one JSON file per entry under
    `iCloud.com.stealth.whisper/Documents/History/`. Requires iCloud
    Drive to be signed in and enabled on-device; falls back to a local
    folder otherwise (Settings shows "History sync: On/Off"). The Mac
    app must adopt the same schema for its own entries to show up here.
12. Dictation keyboard (`StealthWhisperKeyboard` target): enable via
    Settings → General → Keyboard → Keyboards → Add New Keyboard →
    Stealth Whisper, then Full Access. iOS does not expose the microphone
    to custom keyboard extensions. Open Stealth Whisper and enable
    **Keyboard Session**, then return to any text field and select the
    Stealth Whisper keyboard. The voice-only keyboard starts and stops the
    containing app's background recorder through the private
    `group.com.stealth.whisper` App Group. On iOS 26, short English dictation
    uses Apple's private on-device SpeechAnalyzer model and inserts directly
    at the active cursor; the Mac mini is only an automatic fallback and the
    clipboard is not used.
    The orange microphone indicator remains visible while the session is
    enabled. Standby buffers are discarded and only active dictation is
    written to an audio file.
