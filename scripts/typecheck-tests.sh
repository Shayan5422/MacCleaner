#!/bin/zsh
# Type-checks test files against the app module (built from Core, DesignSystem and the
# given feature folders) without running Xcode.
# Usage: scripts/typecheck-tests.sh MacCleanerTests/Uninstaller MacCleaner/Features/Uninstaller [...]
set -euo pipefail
ROOT="${0:A:h:h}"
SDK="$(xcrun --show-sdk-path --sdk macosx)"
PLATFORM="$(xcrun --show-sdk-platform-path --sdk macosx)"
TESTDIR="$1"; shift
typeset -a FILES TESTS
FILES=(${(f)"$(find "$ROOT/MacCleaner/Core" "$ROOT/MacCleaner/DesignSystem" -name '*.swift')"})
for dir in "$@"; do FILES+=(${(f)"$(find "$ROOT/$dir" -name '*.swift')"}); done
TESTS=(${(f)"$(find "$ROOT/$TESTDIR" -name '*.swift')"})
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
xcrun swiftc -emit-module -enable-testing -swift-version 6 -target arm64-apple-macos14.0 -sdk "$SDK" \
  -module-name MacCleaner -parse-as-library -emit-module-path "$OUT/MacCleaner.swiftmodule" "${FILES[@]}" 2>&1 | grep -E "error" || true
xcrun swiftc -typecheck -swift-version 6 -target arm64-apple-macos14.0 -sdk "$SDK" -I "$OUT" \
  -F "$PLATFORM/Developer/Library/Frameworks" -I "$PLATFORM/Developer/usr/lib" \
  -plugin-path "$(xcode-select -p)/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/host/plugins/testing" -parse-as-library "${TESTS[@]}"
echo "Test typecheck OK (${#TESTS[@]} test files)"
