#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
scratch_dir="$project_dir/.build/spm"
app_bundle="$project_dir/.build/app/QuietRecorder.app"

cd "$project_dir"
/usr/bin/swift build --configuration release --scratch-path "$scratch_dir"

/bin/rm -rf "$app_bundle"
/bin/mkdir -p "$app_bundle/Contents/MacOS" "$app_bundle/Contents/Resources"
/usr/bin/ditto "$scratch_dir/release/QuietRecorder" "$app_bundle/Contents/MacOS/QuietRecorder"
/usr/bin/ditto "$project_dir/Resources/Info.plist" "$app_bundle/Contents/Info.plist"
/usr/bin/plutil -lint "$app_bundle/Contents/Info.plist"
/usr/bin/codesign --force --sign - --identifier com.fangchenfang.QuietRecorder \
  --requirements '=designated => identifier "com.fangchenfang.QuietRecorder"' "$app_bundle"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$app_bundle"
print "$app_bundle"
