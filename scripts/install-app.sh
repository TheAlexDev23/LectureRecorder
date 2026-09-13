#!/bin/bash
# Stage and verify before replacing the installed app. Never terminate a running app.
set -euo pipefail
cd "$(dirname "$0")/.."
SOURCE_APP="${1:-$PWD/build/Lecture Recorder.app}"
APPLICATIONS_DIR="${2:-/Applications}"
TARGET_APP="$APPLICATIONS_DIR/Lecture Recorder.app"
EXPECTED_ID="local.alex.LectureRecorder"

bundle_id() {
    /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$1/Contents/Info.plist"
}
if [[ ! -d "$SOURCE_APP" ]] || [[ "$(bundle_id "$SOURCE_APP")" != "$EXPECTED_ID" ]]; then
    printf 'Not a Lecture Recorder app bundle: %s\n' "$SOURCE_APP" >&2
    exit 1
fi
if [[ ! -d "$APPLICATIONS_DIR" || ! -w "$APPLICATIONS_DIR" ]]; then
    printf 'Cannot write to %s. Choose a writable Applications directory.\n' "$APPLICATIONS_DIR" >&2
    exit 1
fi
if [[ -L "$TARGET_APP" ]]; then
    printf 'Refusing to replace a symbolic link: %s\n' "$TARGET_APP" >&2
    exit 1
fi
if [[ -e "$TARGET_APP" ]] && [[ "$(bundle_id "$TARGET_APP")" != "$EXPECTED_ID" ]]; then
    printf 'Refusing to replace an unrelated app: %s\n' "$TARGET_APP" >&2
    exit 1
fi
STAGING_DIR="$(mktemp -d "$APPLICATIONS_DIR/.lecture-recorder-install.XXXXXX")"
STAGED_APP="$STAGING_DIR/Lecture Recorder.app"
BACKUP_APP="$STAGING_DIR/Previous.app"
cleanup() {
    local status=$?
    if [[ -e "$BACKUP_APP" && ! -e "$TARGET_APP" ]]; then
        if ! mv "$BACKUP_APP" "$TARGET_APP"; then
            printf 'Restore the previous app manually from %s\n' "$BACKUP_APP" >&2
            exit 1
        fi
    fi
    rm -rf "$STAGING_DIR"
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
/usr/bin/ditto "$SOURCE_APP" "$STAGED_APP"
/usr/bin/codesign --verify --deep --strict "$STAGED_APP"
if [[ -e "$TARGET_APP" ]]; then mv "$TARGET_APP" "$BACKUP_APP"; fi
mv "$STAGED_APP" "$TARGET_APP"
printf 'Installed: %s\nReopen the app when convenient to use the update.\n' "$TARGET_APP"
