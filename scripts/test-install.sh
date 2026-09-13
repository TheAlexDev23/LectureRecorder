#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/lecture-recorder-install-test.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT
mkdir "$TEST_ROOT/Applications"
./scripts/install-app.sh "$PWD/build/Lecture Recorder.app" "$TEST_ROOT/Applications"
./scripts/install-app.sh "$PWD/build/Lecture Recorder.app" "$TEST_ROOT/Applications"
INSTALLED="$TEST_ROOT/Applications/Lecture Recorder.app"
codesign --verify --deep --strict "$INSTALLED"
ditto "$PWD/build/Lecture Recorder.app" "$TEST_ROOT/Broken.app"
printf 'tampered' >> "$TEST_ROOT/Broken.app/Contents/MacOS/LectureRecorder"
if ./scripts/install-app.sh "$TEST_ROOT/Broken.app" "$TEST_ROOT/Applications" > "$TEST_ROOT/rejected.log" 2>&1; then
    printf 'FAIL: installed a bundle with an invalid signature\n' >&2
    exit 1
fi
codesign --verify --deep --strict "$INSTALLED"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier unrelated.app' "$INSTALLED/Contents/Info.plist"
if ./scripts/install-app.sh "$PWD/build/Lecture Recorder.app" "$TEST_ROOT/Applications" > "$TEST_ROOT/rejected.log" 2>&1; then
    printf 'FAIL: replaced an unrelated app\n' >&2
    exit 1
fi
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INSTALLED/Contents/Info.plist")" == 'unrelated.app' ]]
printf 'Installer checks passed: install, replace, reject damaged bundle, preserve unrelated app.\n'
