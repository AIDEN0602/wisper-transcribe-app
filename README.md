# ClassTranscribe

**Local speech-to-text for your class — no API key required for transcription.**

> Made by Minje Seo (ms15059@nyu.edu)

---

## What it does

- Drag & drop audio/video files → get `.txt` transcripts with timestamps
- Runs 100 % locally on your computer (Whisper AI, no internet needed for transcription)
- Optional translation into English, Korean, Chinese, Spanish, Russian, Japanese, French, German
- Supports macOS (DMG) and Windows (EXE)

---

## Quick Start

1. Open **ClassTranscribe**
2. **Install a model first** (only needed once):
   - In the app, pick `small` from the *Install model* dropdown → click **⬇ Download**
   - This downloads ~465 MB. Takes a few minutes on first run.
3. Drag your audio/video file onto the drop zone, or click **+ Add files**
4. Click **▶ Start Transcribe**
5. Find your `.txt` transcript in `~/Desktop/transcripts` (or your chosen folder)

---

## Supported file formats

`.m4a  .mp3  .wav  .flac  .ogg  .opus  .aac  .mp4  .mov  .mkv  .webm  .m4v`

---

## Models

| Model | Size | Speed | Quality |
|-------|------|-------|---------|
| tiny | 75 MB | ⚡⚡⚡ | ★★☆☆☆ |
| base | 145 MB | ⚡⚡⚡ | ★★★☆☆ |
| **small** ⭐ | 465 MB | ⚡⚡ | ★★★★☆ |
| medium | 1.5 GB | ⚡ | ★★★★☆ |
| large-v3 | 3 GB | 🐢 | ★★★★★ |

**Recommendation:** Start with `small`. Use `medium` or `large-v3` only if accuracy is critical and you have time.

---

## Translation (optional)

Translation is **disabled by default**.  
To enable: set *Translation* → **Enabled**, pick *From* and *To* languages.

### Engines

| Engine | Cost | API Key needed? |
|--------|------|-----------------|
| **Google (free)** | Free | ❌ No key needed |
| **DeepL** | Free tier (500k chars/month) | ✅ Free key — see below |
| **OpenAI** | Paid | ✅ Key from platform.openai.com |
| **Claude** | Paid | ✅ Key from console.anthropic.com |
| **Gemini** | Free tier available | ✅ Key from aistudio.google.com |

> **Tip:** Just paste any API key into the key field — the app auto-selects the matching engine.

---

### How to get a free DeepL API key (no credit card!)

1. Go to **[deepl.com/pro-api](https://www.deepl.com/pro-api)**
2. Click **"Sign up for free"**
3. Enter your email and create a password
4. Confirm your email
5. On the dashboard, click **"Authentication Key"** — copy your key
6. Paste it into ClassTranscribe under Translation → DeepL key field

Free plan: **500,000 characters / month** — more than enough for class use.

---

## Output format

Each transcript file looks like this:

```
# ClassTranscribe Transcript
# File:      lecture_01.mp4
# Created:   2026-03-06T14:23:10
# Detected:  English
# Translation: Disabled

[00:00:00 - 00:00:04]  Welcome to today's lecture on machine learning.
[00:00:04 - 00:00:09]  We'll be covering neural networks and how they learn from data.
```

With translation enabled:
```
[00:00:00 - 00:00:04]  Welcome to today's lecture.
  → [Korean]  오늘 강의에 오신 것을 환영합니다.
```

---

## Build from source

### macOS (DMG)

```bash
# Requires macOS + Python 3.10+
bash scripts/build_app.sh
bash scripts/build_dmg.sh
# Output: dist/ClassTranscribe.dmg
```

### Windows (EXE)

```bat
REM Run on a Windows machine with Python 3.10+ installed
scripts\build_exe.bat
REM Output: dist\ClassTranscribe\ClassTranscribe.exe
REM Distribute the entire dist\ClassTranscribe\ folder
```

---

## Troubleshooting

**macOS: "App is damaged" or "Can't be opened"**
→ Right-click the app → **Open** → confirm once. This bypasses Gatekeeper for unsigned apps.

**"Model not installed" error**
→ Use the *Install model* section in the app to download a model first.

**Translation not working with Google**
→ Google's free translator has rate limits. Switch to DeepL (free key) for reliable results.

**Windows: Missing DLL errors**
→ Install [Visual C++ Redistributable](https://aka.ms/vs/17/release/vc_redist.x64.exe) and retry.

**Very slow transcription**
→ Use a smaller model (tiny or base). Large models need a powerful CPU.

---

## Notes

- Transcription runs fully offline after model download
- API keys are stored in memory only — never saved to disk
- Unclear audio → `[inaudible]`
- Laughter → `[laughter]`
- macOS only: models stored in `~/Library/Application Support/ClassTranscribe/models/`
