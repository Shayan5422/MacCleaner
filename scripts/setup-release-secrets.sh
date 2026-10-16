#!/bin/zsh
# One-time setup of the repository secrets the GitHub release workflow needs
# (.github/workflows/release.yml). Run it yourself in Terminal: it asks for the files and
# passwords interactively, sends them straight to GitHub's encrypted secrets with the GitHub
# CLI, and never writes them anywhere else.
#
#   scripts/setup-release-secrets.sh                 # for Shayan5422/MacCleaner
#   scripts/setup-release-secrets.sh owner/repo
#
# You need:
#   1. Your "Developer ID Application" certificate with its private key, exported from
#      Keychain Access as a .p12 file (select the certificate › File › Export Items…).
#   2. Notarization credentials, either
#      a. an App Store Connect API key (.p8 file, key ID and issuer ID — App Store Connect ›
#         Users and Access › Integrations › App Store Connect API; the "Developer" role is enough), or
#      b. your Apple ID and an app-specific password (https://account.apple.com › Sign-In and Security).
set -euo pipefail

REPO="${1:-Shayan5422/MacCleaner}"
command -v gh >/dev/null || { echo "Install the GitHub CLI first: brew install gh" >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "Sign in to GitHub first: gh auth login" >&2; exit 1; }

set_secret() { # name, value from stdin
  gh secret set "$1" --repo "$REPO" >/dev/null
  echo "  ✓ $1"
}

echo "Setting up release secrets for $REPO"
echo
echo "1/3  Developer ID certificate"
read "p12_path?     Path to the exported .p12 file: "
p12_path="${p12_path/#\~/$HOME}"
[[ -f "$p12_path" ]] || { echo "No file at $p12_path" >&2; exit 1; }
read -s "p12_password?     Password of the .p12 file: "; echo
base64 -i "$p12_path" | set_secret DEVELOPER_ID_P12_BASE64
print -rn -- "$p12_password" | set_secret DEVELOPER_ID_P12_PASSWORD
unset p12_password

echo
echo "2/3  Notarization"
read "choice?     Use an App Store Connect API key (k) or your Apple ID (a)? [k/a] "
if [[ "$choice" == [aA]* ]]; then
  read "apple_id?     Apple ID (email): "
  read -s "app_password?     App-specific password: "; echo
  print -rn -- "$apple_id" | set_secret NOTARY_APPLE_ID
  print -rn -- "$app_password" | set_secret NOTARY_APP_PASSWORD
  unset app_password
else
  read "p8_path?     Path to AuthKey_XXXXXXXXXX.p8: "
  p8_path="${p8_path/#\~/$HOME}"
  [[ -f "$p8_path" ]] || { echo "No file at $p8_path" >&2; exit 1; }
  read "key_id?     Key ID: "
  read "issuer_id?     Issuer ID: "
  base64 -i "$p8_path" | set_secret NOTARY_API_KEY_P8_BASE64
  print -rn -- "$key_id" | set_secret NOTARY_API_KEY_ID
  print -rn -- "$issuer_id" | set_secret NOTARY_API_ISSUER_ID
fi

echo
echo "3/3  Team ID"
team_id="$(security find-identity -v -p codesigning | sed -n 's/.*Developer ID Application: .*(\([A-Z0-9]\{10\}\)).*/\1/p' | head -1)"
read "entered?     Developer Team ID [${team_id:-none found}]: "
team_id="${entered:-$team_id}"
[[ -n "$team_id" ]] || { echo "A Team ID is required" >&2; exit 1; }
gh variable set APPLE_TEAM_ID --body "$team_id" --repo "$REPO" >/dev/null
echo "  ✓ APPLE_TEAM_ID = $team_id"

echo
echo "Done. Push a tag (git tag v1.2.3 && git push origin v1.2.3) or run the Release workflow"
echo "from the Actions tab to build, notarize and publish."
