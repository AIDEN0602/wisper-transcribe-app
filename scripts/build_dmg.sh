#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────
#  build_dmg.sh  –  Wrap ClassTranscribe.app into a DMG
# ─────────────────────────────────────────────────────────────────
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/dist/ClassTranscribe.app"
STAGING="$ROOT/dist_dmg"
OUT="$ROOT/dist/ClassTranscribe.dmg"

if [[ ! -d "$APP" ]]; then
  echo "❌  App not found: $APP"
  echo "    Run scripts/build_app.sh first."
  exit 1
fi

echo "==> Preparing DMG staging folder…"
rm -rf "$STAGING"
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

echo "==> Creating DMG…"
rm -f "$OUT"
hdiutil create \
  -volname "ClassTranscribe" \
  -srcfolder "$STAGING" \
  -ov \
  -format UDZO \
  "$OUT"

rm -rf "$STAGING"
echo ""
echo "✅  DMG_BUILT=$OUT"
