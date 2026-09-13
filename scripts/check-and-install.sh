#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
printf 'Lecture Recorder: testing the working tree…\n'
swift test
./scripts/build-app.sh
./scripts/test-install.sh
./scripts/install-app.sh
