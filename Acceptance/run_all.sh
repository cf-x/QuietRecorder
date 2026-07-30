#!/bin/zsh
set -euo pipefail

[[ $# -eq 4 ]] || {
  print -u2 "usage: run_all.sh APP_PATH PACKAGE_DIR PID RECORDING.mp4"
  exit 2
}

script_dir="${0:A:h}"
"$script_dir/accept_bundle.sh" "$1" "$2"
"$script_dir/accept_runtime.sh" "$3" "$2"
/usr/bin/swift "$script_dir/accept_recording.swift" "$4"
print "PASS: all frozen acceptance checks"
