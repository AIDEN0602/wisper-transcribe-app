#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
version="${1:-0.3.0}"
build_number="${2:-3}"
build_root="$project_dir/build/release-$version-$build_number"
archive_path="$build_root/StealthWhisperMac.xcarchive"
export_path="$build_root/export"
notarized_export_path="$build_root/notarized-export"
stage_path="$build_root/dmg"
dmg_path="$project_dir/build/Stealth-Whisper-$version.dmg"
identity="Developer ID Application: Minje Seo (9H5KVJSU9S)"

mkdir -p "$build_root" "$export_path" "$notarized_export_path" "$stage_path"
find "$notarized_export_path" -mindepth 1 -delete
find "$stage_path" -mindepth 1 -delete

if [[ -x "$HOME/.local/xcodegen/bin/xcodegen" ]]; then
  xcodegen_bin="$HOME/.local/xcodegen/bin/xcodegen"
else
  xcodegen_bin="$(command -v xcodegen)"
fi

cd "$project_dir"
"$xcodegen_bin" generate

xcodebuild \
  -project StealthWhisperMac.xcodeproj \
  -scheme StealthWhisperMac \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath "$archive_path" \
  -allowProvisioningUpdates \
  archive

xcodebuild -exportArchive \
  -archivePath "$archive_path" \
  -exportOptionsPlist ExportOptions-DeveloperID.plist \
  -exportPath "$export_path" \
  -allowProvisioningUpdates

xcodebuild -exportArchive \
  -archivePath "$archive_path" \
  -exportOptionsPlist ExportOptions-Notarize.plist \
  -allowProvisioningUpdates

until xcodebuild -exportNotarizedApp \
  -archivePath "$archive_path" \
  -exportPath "$notarized_export_path"; do
  echo "Apple is still processing the notarization. Retrying in 30 seconds..."
  sleep 30
done

app_path="$notarized_export_path/Stealth Whisper.app"
codesign --verify --deep --strict --verbose=2 "$app_path"
spctl --assess --type execute --verbose=2 "$app_path"
xcrun stapler validate "$app_path"

ditto "$app_path" "$stage_path/Stealth Whisper.app"
ln -s /Applications "$stage_path/Applications" 2>/dev/null || true
hdiutil create \
  -volname "Stealth Whisper" \
  -srcfolder "$stage_path" \
  -format UDZO \
  -ov \
  "$dmg_path"
codesign --force --sign "$identity" --timestamp "$dmg_path"
codesign --verify --verbose=2 "$dmg_path"

echo "$dmg_path"
