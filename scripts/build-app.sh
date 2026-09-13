#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
APP="$PWD/build/Lecture Recorder.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/LectureRecorder "$APP/Contents/MacOS/LectureRecorder"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>LectureRecorder</string>
<key>CFBundleIdentifier</key><string>local.alex.LectureRecorder</string>
<key>CFBundleName</key><string>Lecture Recorder</string>
<key>CFBundleDisplayName</key><string>Lecture Recorder</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>15.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSMicrophoneUsageDescription</key><string>Record lecture audio for local transcription and your notes.</string>
<key>NSSpeechRecognitionUsageDescription</key><string>Transcribe your lecture recordings with Apple's on-device speech framework.</string>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
printf 'Built: %s\n' "$APP"
