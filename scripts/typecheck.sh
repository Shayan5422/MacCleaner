#!/bin/zsh
# Type-checks the shared core plus the given folders with the same Swift settings
# as the Xcode project (Swift 6 language mode, macOS 14 deployment target).
# Usage: scripts/typecheck.sh [MacCleaner/Features/Uninstaller ...]
set -euo pipefail
ROOT="${0:A:h:h}"
SDK="$(xcrun --show-sdk-path --sdk macosx)"
typeset -a FILES
FILES=(${(f)"$(find "$ROOT/MacCleaner/Core" "$ROOT/MacCleaner/DesignSystem" -name '*.swift' 2>/dev/null)"})
for dir in "$@"; do
  FILES+=(${(f)"$(find "$ROOT/$dir" -name '*.swift')"})
done
xcrun swiftc -typecheck -swift-version 6 -target arm64-apple-macos14.0 -sdk "$SDK" \
  -module-name MacCleaner -parse-as-library "${FILES[@]}"
echo "Typecheck OK (${#FILES[@]} files)"
