#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
built_app="$project_dir/.build/app/QuietRecorder.app"
installed_app="/Applications/QuietRecorder.app"

"$project_dir/Scripts/build-app.sh"
if /usr/bin/pgrep -x QuietRecorder >/dev/null; then
  /usr/bin/pkill -x QuietRecorder
  integer shutdown_deadline=$((SECONDS + 130))
  while /usr/bin/pgrep -x QuietRecorder >/dev/null; do
    if (( SECONDS >= shutdown_deadline )); then
      print -u2 "QuietRecorder did not finish safe shutdown within 130 seconds; installation aborted"
      exit 1
    fi
    /bin/sleep 0.25
  done
fi
/bin/rm -rf "$installed_app"
/usr/bin/ditto "$built_app" "$installed_app"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$installed_app"
print "$installed_app"
