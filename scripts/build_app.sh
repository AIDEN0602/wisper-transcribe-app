#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────
#  build_app.sh  –  Build ClassTranscribe.app for macOS
# ─────────────────────────────────────────────────────────────────
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "==> Setting up Python venv…"
PYTHON3=$(command -v python3.12 || command -v /opt/homebrew/bin/python3.12 || command -v python3)
"$PYTHON3" -m venv .venv
source .venv/bin/activate

echo "==> Installing dependencies…"
python -m pip install --upgrade pip
python -m pip install -r requirements.txt

echo "==> Generating app icon…"
python scripts/make_icon.py

echo "==> Downloading bundled model (small)…"
python scripts/download_model.py small

echo "==> Cleaning previous build…"
rm -rf build dist

echo "==> Running PyInstaller…"
pyinstaller \
  --noconfirm \
  --windowed \
  --name "ClassTranscribe" \
  --icon "assets/ClassTranscribe.icns" \
  --add-data "models:models" \
  --collect-all faster_whisper \
  --collect-all ctranslate2 \
  --collect-all av \
  --collect-all tkinterdnd2 \
  --collect-all huggingface_hub \
  --collect-all certifi \
  --hidden-import certifi \
  --hidden-import tkinterdnd2 \
  --hidden-import deep_translator \
  --hidden-import deepl \
  --hidden-import anthropic \
  --hidden-import google.generativeai \
  --hidden-import openai \
  src/app.py

echo "==> Self-signing app (no Developer ID required)…"
codesign --deep --force --sign - "dist/ClassTranscribe.app" || true

echo ""
echo "✅  APP_BUILT=$ROOT/dist/ClassTranscribe.app"
echo "   (If macOS blocks launch: right-click → Open)"
