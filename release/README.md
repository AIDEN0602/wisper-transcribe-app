# 🎙️ ClassTranscribe — Free AI Lecture Transcriber for Mac

**Transcribe your class recordings to text — 100% free, runs offline on your Mac.**

> Made by Minje Seo · NYU

---

## ✨ What it does

- Drop any audio or video file → get a **text transcript with timestamps** in seconds
- Works **completely offline** — your files never leave your computer
- Optional **translation** into English, Korean, Chinese, Spanish, Japanese, French, German, Russian
- Supports: `.m4a .mp3 .wav .mp4 .mov .mkv .flac .ogg` and more

---

## 📥 Installation (Mac only)

1. **Download** `ClassTranscribe.dmg` (this file, in the same folder)
2. **Open** the `.dmg` file → drag **ClassTranscribe** into your `/Applications` folder
3. **First launch:** Right-click the app → **Open** → click **Open** again
   *(macOS will warn you it's from an unidentified developer — this is normal for free apps. Just click Open.)*

---

## 🚀 How to Use

### Step 1 — Download a transcription model (one-time setup)

The app needs an AI model downloaded before it can transcribe. You only do this once.

1. Open the app
2. In the **"Install model"** dropdown, choose `small` *(recommended — 465 MB, great accuracy)*
3. Click **⬇ Download** and wait for it to finish
4. You're ready!

| Model | Size | Speed | Accuracy |
|-------|------|-------|----------|
| tiny | 75 MB | ⚡⚡⚡ | Basic |
| base | 145 MB | ⚡⚡⚡ | OK |
| **small** ⭐ | 465 MB | ⚡⚡ | **Great (recommended)** |
| medium | 1.5 GB | ⚡ | Excellent |
| large-v3 | 3 GB | 🐢 | Best |

### Step 2 — Transcribe a file

1. Drag your recording into the app (or click **+ Add files**)
2. Set the **language** your recording is in (e.g., *English*)
3. Click **▶ Start Transcribe**
4. Done! Your `.txt` transcript is saved to `~/Desktop/transcripts/`

---

## 🌐 Translation (optional)

By default, translation is **off**. To enable it:

1. Set **Translation** → `Enabled`
2. Choose **From** (source language) and **To** (target language)
3. Pick a **translation engine** (see below)

### Which engine should I use?

| Engine | Cost | Needs API Key? | Notes |
|--------|------|----------------|-------|
| **Google** | Free | ❌ No key | May hit rate limits with long files |
| **DeepL** ⭐ | Free (500k chars/mo) | ✅ Free key (no credit card!) | Best free option |
| OpenAI | Paid | ✅ Key from platform.openai.com | |
| Claude | Paid | ✅ Key from console.anthropic.com | |
| Gemini | Free tier | ✅ Key from aistudio.google.com | |

> **Recommendation:** Use **DeepL** — the free plan gives you 500,000 characters/month, which is way more than enough for class use. No credit card needed.

---

## 🔑 How to get a free DeepL API key (5 minutes, no credit card)

DeepL gives you 500,000 free characters per month — plenty for any student.

1. Go to **[www.deepl.com/pro-api](https://www.deepl.com/pro-api)**
2. Click **"Sign up for free"**
3. Enter your **email** and create a **password** (you can use your school email)
4. Check your email and **confirm your account**
5. Log in → go to **Account** → **Authentication Key**
6. Click **Copy** next to your key
7. In ClassTranscribe, paste the key into the **API Key** field
8. Set Engine to **DeepL** and you're good to go!

> 💡 If you see "API key" greyed out, make sure Translation is set to **Enabled** first.

---

## 📄 What the output looks like

Your transcript file (`~/Desktop/transcripts/filename.txt`) will look like this:

```
# ClassTranscribe Transcript
# File:        lecture_01.mp4
# Created:     2026-03-06T14:23:10
# Language:    English
# Translation: Disabled

[00:00:00 - 00:00:04]  Welcome to today's lecture on machine learning.
[00:00:04 - 00:00:09]  We'll be covering neural networks and how they learn from data.
[00:00:09 - 00:00:15]  Please make sure to take notes — there will be a quiz next week.
```

With translation enabled (e.g., English → Korean):
```
[00:00:00 - 00:00:04]  Welcome to today's lecture on machine learning.
  → [Korean]  오늘 머신러닝 강의에 오신 것을 환영합니다.
```

---

## ❓ Troubleshooting

**"App is damaged" or "Can't be opened"**
→ Right-click the app → **Open** → click Open. You only need to do this once.

**"Model not installed"**
→ Use the *Install model* section in the app to download a model first.

**Translation not working with Google engine**
→ Google's free translator has rate limits. Switch to **DeepL** (free key, no credit card needed).

**Transcription is very slow**
→ Use `tiny` or `base` model instead of `small`. Smaller = faster.

**Output file not found**
→ Check `~/Desktop/transcripts/` folder. Or change the output folder in the app.

---

## 💬 Questions?

Contact Minje Seo at **ms15059@nyu.edu**

---

*ClassTranscribe uses [faster-whisper](https://github.com/SYSTRAN/faster-whisper) (OpenAI Whisper) locally. Your audio never leaves your computer.*
