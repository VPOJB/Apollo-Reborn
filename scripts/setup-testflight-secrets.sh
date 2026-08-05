#!/bin/bash
set -euo pipefail

# One-shot setup script: creates distribution certificate, App Store provisioning
# profile, and sets all required GitHub secrets for the TestFlight workflow
# (.github/workflows/testflight.yml).
#
# Run this ONCE after creating an App Store Connect API key.
#
# Prerequisites:
#   brew install fastlane gh
#   gh auth login
#   Xcode installed at /Applications/Xcode.app
#
# Usage:
#   ./scripts/setup-testflight-secrets.sh \
#     --api-key-path ~/Downloads/AuthKey_XXXXXXXXXX.p8 \
#     --key-id XXXXXXXXXX \
#     --issuer-id XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX
#
# Optional:
#   --apollo-ipa-url <url>      defaults to https://downloads.apolloreborn.app/apollobase.ipa
#   --github-repo <owner/repo>  defaults to VPOJB/Apollo-Reborn
#   --bundle-id <id>            defaults to ca.bowness.apollo
#   --team-id <id>              defaults to HW8AV68T8A
#
# NOTE: You must create the App Store Connect app record manually before
# triggering the TestFlight build:
#   https://appstoreconnect.apple.com → My Apps → + → New App
#   Bundle ID: ca.bowness.apollo

BUNDLE_ID="ca.bowness.apollo"
APP_NAME="Apollo Reborn"
TEAM_ID="HW8AV68T8A"
GITHUB_REPO="VPOJB/Apollo-Reborn"
APOLLO_IPA_URL="https://downloads.apolloreborn.app/apollobase.ipa"

API_KEY_PATH=""
KEY_ID=""
ISSUER_ID=""

usage() {
    grep '^#' "$0" | grep -v '#!/' | sed 's/^# //' | sed 's/^#//'
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --api-key-path) API_KEY_PATH="$2"; shift 2 ;;
        --key-id) KEY_ID="$2"; shift 2 ;;
        --issuer-id) ISSUER_ID="$2"; shift 2 ;;
        --apollo-ipa-url) APOLLO_IPA_URL="$2"; shift 2 ;;
        --github-repo) GITHUB_REPO="$2"; shift 2 ;;
        --bundle-id) BUNDLE_ID="$2"; shift 2 ;;
        --team-id) TEAM_ID="$2"; shift 2 ;;
        -h|--help) usage ;;
        *) echo "Unknown option: $1"; usage ;;
    esac
done

[[ -f "$API_KEY_PATH" ]] || { echo "Error: API key not found: $API_KEY_PATH"; exit 1; }
[[ -n "$KEY_ID" ]] || { echo "Error: --key-id is required"; exit 1; }
[[ -n "$ISSUER_ID" ]] || { echo "Error: --issuer-id is required"; exit 1; }

API_KEY_PATH="$(cd "$(dirname "$API_KEY_PATH")" && pwd)/$(basename "$API_KEY_PATH")"

command -v fastlane >/dev/null 2>&1 || { echo "Error: fastlane not found. Run: brew install fastlane"; exit 1; }
command -v gh >/dev/null 2>&1 || { echo "Error: gh not found. Run: brew install gh"; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "Error: gh not authenticated. Run: gh auth login"; exit 1; }
[[ -d /Applications/Xcode.app ]] || { echo "Error: Xcode not found at /Applications/Xcode.app"; exit 1; }

SETUP_DIR="$(mktemp -d)"
trap 'rm -rf "$SETUP_DIR"' EXIT

# Embed the .p8 key content inline (fastlane CLI requires "key" not "key_filepath")
API_KEY_CONTENT="$(cat "$API_KEY_PATH")"
python3 -c "
import json, sys
data = {
    'key_id': '$KEY_ID',
    'issuer_id': '$ISSUER_ID',
    'key': open('$API_KEY_PATH').read(),
    'duration': 1200,
    'in_house': False
}
print(json.dumps(data, indent=2))
" > "$SETUP_DIR/api_key.json"

# fastlane uses Xcode, so point it at the full Xcode installation
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

echo ""
echo "==> [1/3] Creating iOS Distribution certificate..."
fastlane cert \
    --team_id "$TEAM_ID" \
    --api_key_path "$SETUP_DIR/api_key.json" \
    --output_path "$SETUP_DIR" \
    2>&1 | grep -v "^$"

# fastlane cert outputs <cert_id>.cer and <cert_id>.p12 (the private key, PEM)
CERT_FILE=$(ls "$SETUP_DIR"/*.cer 2>/dev/null | head -1)
KEY_FILE=$(ls "$SETUP_DIR"/*.p12 2>/dev/null | head -1)

[[ -f "$CERT_FILE" ]] || { echo "Error: no .cer produced by fastlane cert"; exit 1; }
[[ -f "$KEY_FILE" ]] || { echo "Error: no .p12 produced by fastlane cert"; exit 1; }

# Build a proper PKCS12 from the cert (DER) and private key (PEM)
P12_PASS=$(openssl rand -hex 20)
openssl x509 -inform DER -in "$CERT_FILE" -out "$SETUP_DIR/cert.pem"
openssl pkcs12 -export \
    -inkey "$KEY_FILE" \
    -in "$SETUP_DIR/cert.pem" \
    -out "$SETUP_DIR/distribution.p12" \
    -passout "pass:$P12_PASS" \
    -name "Apple Distribution: $(openssl x509 -in "$SETUP_DIR/cert.pem" -noout -subject | sed -E 's/.*CN ?= ?([^,\/]+).*/\1/')"
echo "    Certificate exported as PKCS12"

echo ""
echo "==> [2/3] Creating App Store provisioning profile for $BUNDLE_ID..."
# Note: do NOT pass --app_store; App Store is the default when not using --adhoc/--development
fastlane sigh \
    --app_identifier "$BUNDLE_ID" \
    --team_id "$TEAM_ID" \
    --api_key_path "$SETUP_DIR/api_key.json" \
    --output_path "$SETUP_DIR" \
    --filename "distribution.mobileprovision" \
    2>&1 | grep -v "^$"

PROFILE_FILE="$SETUP_DIR/distribution.mobileprovision"
[[ -f "$PROFILE_FILE" ]] || {
    PROFILE_FILE=$(ls "$SETUP_DIR"/*.mobileprovision 2>/dev/null | head -1)
    [[ -n "$PROFILE_FILE" ]] || { echo "Error: no .mobileprovision produced"; exit 1; }
}
echo "    Profile: $PROFILE_FILE"

echo ""
echo "==> [3/3] Setting GitHub secrets on $GITHUB_REPO..."
KEYCHAIN_PASS=$(openssl rand -hex 32)

gh secret set APOLLO_IPA_URL \
    --body "$APOLLO_IPA_URL" --repo "$GITHUB_REPO"
echo "    ✓ APOLLO_IPA_URL"

gh secret set DISTRIBUTION_CERTIFICATE_P12 \
    --body "$(base64 -i "$SETUP_DIR/distribution.p12")" --repo "$GITHUB_REPO"
echo "    ✓ DISTRIBUTION_CERTIFICATE_P12"

gh secret set DISTRIBUTION_CERTIFICATE_PASSWORD \
    --body "$P12_PASS" --repo "$GITHUB_REPO"
echo "    ✓ DISTRIBUTION_CERTIFICATE_PASSWORD"

gh secret set PROVISIONING_PROFILE_BASE64 \
    --body "$(base64 -i "$PROFILE_FILE")" --repo "$GITHUB_REPO"
echo "    ✓ PROVISIONING_PROFILE_BASE64"

gh secret set KEYCHAIN_PASSWORD \
    --body "$KEYCHAIN_PASS" --repo "$GITHUB_REPO"
echo "    ✓ KEYCHAIN_PASSWORD"

gh secret set ASC_API_KEY_ID \
    --body "$KEY_ID" --repo "$GITHUB_REPO"
echo "    ✓ ASC_API_KEY_ID"

gh secret set ASC_API_ISSUER_ID \
    --body "$ISSUER_ID" --repo "$GITHUB_REPO"
echo "    ✓ ASC_API_ISSUER_ID"

gh secret set ASC_API_PRIVATE_KEY \
    --body "$(base64 -i "$API_KEY_PATH")" --repo "$GITHUB_REPO"
echo "    ✓ ASC_API_PRIVATE_KEY"

echo ""
echo "=========================================="
echo "  All secrets set. Almost ready to build."
echo "=========================================="
echo ""
echo "IMPORTANT — one manual step remains:"
echo "  Create the App Store Connect app record at:"
echo "  https://appstoreconnect.apple.com → My Apps → + → New App"
echo "  Bundle ID: $BUNDLE_ID"
echo ""
echo "Then trigger your first TestFlight build:"
echo "  gh workflow run testflight.yml --repo $GITHUB_REPO"
echo "  or: https://github.com/$GITHUB_REPO/actions/workflows/testflight.yml"
echo ""
