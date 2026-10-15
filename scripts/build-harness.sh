#!/bin/zsh
# Compiles a throwaway command-line harness against the app's Core (+ given folders)
# so engine code can be exercised without building the whole app.
# Usage: scripts/build-harness.sh <main.swift> <output-binary> [MacCleaner/Features/X ...]
set -euo pipefail
ROOT="${0:A:h:h}"
MAIN="$1"; OUTPUT="$2"; shift 2
SDK="$(xcrun --show-sdk-path --sdk macosx)"
typeset -a FILES
FILES=(${(f)"$(find "$ROOT/MacCleaner/Core" "$ROOT/MacCleaner/DesignSystem" -name '*.swift')"})
for dir in "$@"; do FILES+=(${(f)"$(find "$ROOT/$dir" -name '*.swift')"}); done
xcrun swiftc -O -swift-version 6 -target arm64-apple-macos14.0 -sdk "$SDK" -module-name Harness \
  -parse-as-library -o "$OUTPUT" "$MAIN" "${FILES[@]}"
