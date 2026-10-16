#!/bin/zsh
# Prints the CHANGELOG.md section for a version (without its heading), for release notes.
# Usage: scripts/release-notes.sh 1.2.0   → exits 1 if CHANGELOG.md has no "## [1.2.0]" section.
set -euo pipefail
ROOT="${0:A:h:h}"
VERSION="${1:?Pass a version, e.g. 1.2.0}"
awk -v version="$VERSION" '
  /^## \[/ {
    if (found) exit
    if (index($0, "## [" version "]") == 1) { found = 1; next }
  }
  found { print }
  END { if (!found) exit 1 }
' "$ROOT/CHANGELOG.md" | sed -e '/./,$!d'
