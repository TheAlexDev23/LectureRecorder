#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
EXISTING_HOOKS="$(git config --get core.hooksPath || true)"
if [[ -n "$EXISTING_HOOKS" && "$EXISTING_HOOKS" != '.githooks' ]]; then
    printf 'Existing hooksPath is %s; merge those hooks before replacing it.\n' "$EXISTING_HOOKS" >&2
    exit 1
fi
git config --local core.hooksPath .githooks
printf 'Enabled pre-commit tests, release build, and installation into /Applications.\n'
