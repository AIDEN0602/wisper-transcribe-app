# ClassTranscribe — Quick Start Guide

> Free AI transcription app for Mac · Made by Minje Seo (NYU)

---

## Install & Launch

1. Open **ClassTranscribe.dmg**
2. Drag the app into **Applications**
3. First time only: **Right-click** the app → **Open** → click **Open**

> macOS shows a warning for apps outside the App Store. This is normal — just click Open once and it won't ask again.

---

## Basic Usage

1. Open the app
2. Click **+ Add files** (or drag your audio/video file in)
3. Set the **Language** your recording is in
4. Click **▶ Start Transcribe**
5. Your transcript (`.txt`) is saved to `~/Desktop/transcripts/`

**Supported formats:** `.m4a .mp3 .wav .mp4 .mov .mkv .flac .ogg` and more

---

## 🔒 Privacy & Security

**Everything runs 100% locally on your Mac.**

- Your audio files are never uploaded anywhere
- No account or login required
- Works without internet (after first model download)
- API keys (if used for translation) are kept in memory only — never saved to disk

---

## ⬇ First-Time Setup: Download a Model

The app needs a one-time model download before it can transcribe.

1. In the app, find the **"Install model"** section
2. Select a model from the dropdown (see table below)
3. Click **⬇ Download** — wait for it to finish
4. You're ready to transcribe

### Which model should I use?

| Model | Download Size | Speed | Accuracy |
|-------|:---:|:---:|:---:|
| tiny | 75 MB | ⚡⚡⚡ | ★★☆☆☆ |
| base | 145 MB | ⚡⚡⚡ | ★★★☆☆ |
| **small** ⭐ | 465 MB | ⚡⚡ | ★★★★☆ |
| medium | 1.5 GB | ⚡ | ★★★★☆ |
| large-v3 | 3 GB | 🐢 | ★★★★★ |

**→ Start with `small`.** It's fast, accurate, and handles most lecture recordings well.

Use `medium` or `large-v3` only if `small` misses words too often — they're much slower.

To switch models: download a new one from the app, then select it from the **Model** dropdown before transcribing.

---

## 🌐 Translation (Optional)

Translation is **off by default.**

To turn it on:
1. Set **Translation** → `Enabled`
2. Choose **From** and **To** language
3. Pick a translation **Engine**
4. (If needed) paste your **API Key**

### Translation Engine Comparison

| Engine | Cost | API Key | Quality | Notes |
|--------|:---:|:---:|:---:|---|
| **Google** | Free | ❌ Not needed | ★★★☆☆ | May slow down on long files |
| **DeepL** ⭐ | Free (500k chars/mo) | ✅ Free key | ★★★★☆ | Best free option, no credit card |
| OpenAI | Paid | ✅ Paid key | ★★★★★ | Most natural phrasing |
| Claude | Paid | ✅ Paid key | ★★★★★ | Great for academic text |
| Gemini | Free tier | ✅ Free key | ★★★★☆ | Google account required |

**→ Recommended: DeepL** — free, reliable, no credit card needed.

### How to get a free DeepL key

1. Go to [deepl.com/pro-api](https://www.deepl.com/pro-api)
2. Click **Sign up for free** (no credit card)
3. Confirm your email → log in
4. Go to **Account → Authentication Key** → Copy
5. Paste into the **API Key** field in ClassTranscribe

Free plan: 500,000 characters/month — more than enough for class use.
