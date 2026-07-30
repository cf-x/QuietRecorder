#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
cd "$project_dir"
/usr/bin/shasum -a 256 -c Acceptance/SHA256SUMS
Scripts/build-app.sh
Acceptance/accept_bundle.sh .build/app/QuietRecorder.app "$project_dir"
/usr/bin/swiftc -typecheck Acceptance/accept_runtime_visibility.swift
/usr/bin/swiftc -typecheck Acceptance/accept_recording.swift
print "PASS: frozen acceptance integrity, release build, bundle checks, and inspector typechecks"
