#!/bin/zsh
set -euo pipefail

fail() {
  print -u2 "FAIL: $1"
  exit 1
}

[[ $# -eq 2 ]] || fail "usage: accept_runtime.sh PID PACKAGE_DIR"
pid="$1"
package_dir="$2"

/bin/ps -p "$pid" -o pid=,comm= | /usr/bin/grep -q QuietRecorder || fail "QuietRecorder process is not running"
app_info="$(/usr/bin/lsappinfo info -only ApplicationType -pid "$pid")"
print "$app_info"
print "$app_info" | /usr/bin/grep -q 'ApplicationType.*Foreground' && fail "application is a Dock foreground application"
/usr/bin/swift "$package_dir/Acceptance/accept_runtime_visibility.swift" "$pid"

if /usr/bin/grep -R -n -E 'NSStatusItem|statusItemWithLength|NSStatusBar[.]system' "$package_dir/Sources"; then
  fail "source creates or references a menu-bar status item"
fi

print "PASS: Dock foreground icon absent"
print "PASS: menu-bar item implementation absent"
