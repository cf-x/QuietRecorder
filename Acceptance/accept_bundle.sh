#!/bin/zsh
set -euo pipefail

fail() {
  print -u2 "FAIL: $1"
  exit 1
}

[[ $# -eq 2 ]] || fail "usage: accept_bundle.sh APP_PATH PACKAGE_DIR"
app_path="$1"
package_dir="$2"
plist="$app_path/Contents/Info.plist"
executable="$app_path/Contents/MacOS/QuietRecorder"

[[ -d "$app_path" ]] || fail "application bundle is missing"
[[ -f "$plist" ]] || fail "Info.plist is missing"
[[ -x "$executable" ]] || fail "application executable is missing or not executable"

[[ "$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$plist")" == "com.fangchenfang.QuietRecorder" ]] || fail "unexpected bundle identifier"
[[ "$(/usr/bin/plutil -extract CFBundlePackageType raw -o - "$plist")" == "APPL" ]] || fail "CFBundlePackageType must be APPL"
[[ "$(/usr/bin/plutil -extract LSMinimumSystemVersion raw -o - "$plist")" == "15.0" ]] || fail "minimum macOS version must be 15.0"
[[ "$(/usr/bin/plutil -extract LSUIElement raw -o - "$plist")" == "true" ]] || fail "LSUIElement must be true"
[[ -n "$(/usr/bin/plutil -extract NSScreenCaptureUsageDescription raw -o - "$plist")" ]] || fail "screen recording purpose is missing"
[[ -n "$(/usr/bin/plutil -extract NSMicrophoneUsageDescription raw -o - "$plist")" ]] || fail "microphone purpose is missing"

/usr/bin/codesign --verify --deep --strict --verbose=2 "$app_path"
signature="$((/usr/bin/codesign -dv --verbose=2 "$app_path") 2>&1)"
print "$signature" | /usr/bin/grep -q "Identifier=com.fangchenfang.QuietRecorder" || fail "signature identifier is wrong"

self_test_output="$("$executable" --self-test)"
[[ "$self_test_output" == *"SELF_TEST_OK"* ]] || fail "signed executable self-test did not launch cleanly"

dependency_json="$(cd "$package_dir" && /usr/bin/swift package show-dependencies --format json)"
print -rn -- "$dependency_json" | /usr/bin/swift -e '
import Foundation
let data = FileHandle.standardInput.readDataToEndOfFile()
guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let dependencies = root["dependencies"] as? [Any], dependencies.isEmpty else {
    FileHandle.standardError.write(Data("FAIL: Swift package has third-party dependencies\n".utf8))
    exit(1)
}
'

third_party_count=0
while IFS= read -r library; do
  [[ -z "$library" ]] && continue
  case "$library" in
    /System/Library/*|/usr/lib/*|@rpath/libswift*) ;;
    *)
      print -u2 "Unexpected dynamic library: $library"
      third_party_count=$((third_party_count + 1))
      ;;
  esac
done < <(/usr/bin/otool -L "$executable" | /usr/bin/tail -n +2 | /usr/bin/awk '{print $1}')
[[ "$third_party_count" -eq 0 ]] || fail "third-party dynamic dependency count is not zero"

if /usr/bin/grep -R -n -E 'NSStatusItem|statusItemWithLength|NSStatusBar[.]system' "$package_dir/Sources"; then
  fail "source creates or references a menu-bar status item"
fi

print "PASS: bundle structure"
print "PASS: ad-hoc signature and executable launch"
print "PASS: privacy descriptions and LSUIElement=true"
print "PASS: Swift package dependencies=0, third-party dynamic libraries=0"
print "PASS: no NSStatusItem source reference"
