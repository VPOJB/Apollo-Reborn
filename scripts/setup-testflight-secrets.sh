#!/bin/bash
set -euo pipefail

# One-shot setup script: creates App ID, distribution certificate, App Store
# provisioning profile, and sets all required GitHub secrets for the TestFlight
# workflow (.github/workflows/testflight.yml).
#
# Run this ONCE after creating an App Store Connect API key.
#
# Usage:
#   ./scripts/setup-testflight-secrets.sh \
#     --api-key-path ~/Downloads/AuthKey_XXXXXXXXXX.p8 \
#     --key-id XXXXXXXXXX \
#     --issuer-id XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX
#
# Optional:
#   --apollo-ipa-url <url>   defaults to https://downloads.apolloreborn.app/apollobase.ipa
#   --github-repo <owner/repo>  defaults to VPOJB/Apollo-Reborn

BUNDLE_ID="ca.bowness.apollo"
APP_NAME="Apollo Reborn"
TEAM_ID="H7ZX98RQ9J"
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

SETUP_DIR="$(mktemp -d)"
trap 'rm -rf "$SETUP_DIR"' EXIT

# fastlane api_key JSON — accepted by produce/cert/sigh without Apple ID auth
cat > "$SETUP_DIR/api_key.json" << EOF
{
  "key_id": "$KEY_ID",
  "issuer_id": "$ISSUER_ID",
  "key_filepath": "$API_KEY_PATH",
  "duration": 1200,
  "in_house": false
}
EOF

echo ""
echo "==> [1/4] Creating App ID and App Store record for $BUNDLE_ID..."
fastlane produce \
    --app_identifier "$BUNDLE_ID" \
    --app_name "$APP_NAME" \
    --team_id "$TEAM_ID" \
    --api_key_path "$SETUP_DIR/api_key.json" \
    --skip_itc_upload false \
    2>&1 | grep -v "^$" || echo "    (App record may already exist — continuing)"

echo ""
echo "==> [2/4] Creating iOS Distribution certificate..."
fastlane cert \
    --team_id "$TEAM_ID" \
    --api_key_path "$SETUP_DIR/api_key.json" \
    --output_path "$SETUP_DIR" \
    2>&1 | grep -v "^$"

# Export the distribution identity (cert + private key) from the login keychain
# as a .p12 so CI can import it on each run.
DIST_IDENTITY=$(security find-identity -v -p codesigning ~/Library/Keychains/login.keychain-db 2>/dev/null \
    | grep "iPhone Distribution" | head -1 | sed -E 's/.*"(.+)"/\1/')

if [ -z "$DIST_IDENTITY" ]; then
    echo "Error: no iPhone Distribution identity found in login keychain after fastlane cert."
    echo "Try opening Xcode → Settings → Accounts and checking that your team ($TEAM_ID) is listed."
    exit 1
fi
echo "    Distribution identity: $DIST_IDENTITY"

P12_PASS=$(openssl rand -hex 20)
P12_FILE="$SETUP_DIR/distribution.p12"
security export \
    -k ~/Library/Keychains/login.keychain-db \
    -t identities \
    -f pkcs12 \
    -P "$P12_PASS" \
    -o "$P12_FILE" 2>&1 | grep -v "^$"

[[ -f "$P12_FILE" ]] || { echo "Error: .p12 export failed"; exit 1; }
echo "    Exported: $P12_FILE"

echo ""
echo "==> [3/4] Creating App Store provisioning profile for $BUNDLE_ID..."
fastlane sigh \
    --app_identifier "$BUNDLE_ID" \
    --team_id "$TEAM_ID" \
    --api_key_path "$SETUP_DIR/api_key.json" \
    --output_path "$SETUP_DIR" \
    --filename "distribution.mobileprovision" \
    --app_store \
    2>&1 | grep -v "^$"

PROFILE_FILE="$SETUP_DIR/distribution.mobileprovision"
[[ -f "$PROFILE_FILE" ]] || {
    # fastlane sigh sometimes names the file differently
    PROFILE_FILE=$(ls "$SETUP_DIR"/*.mobileprovision 2>/dev/null | head -1)
    [[ -n "$PROFILE_FILE" ]] || { echo "Error: no .mobileprovision produced"; exit 1; }
}
echo "    Profile: $PROFILE_FILE"

echo ""
echo "==> [4/4] Setting GitHub secrets on $GITHUB_REPO..."
KEYCHAIN_PASS=$(openssl rand -hex 32)

gh secret set APOLLO_IPA_URL \
    --body "$APOLLO_IPA_URL" --repo "$GITHUB_REPO"
echo "    ✓ APOLLO_IPA_URL"

gh secret set DISTRIBUTION_CERTIFICATE_P12 \
    --body "$(base64 -i "$P12_FILE")" --repo "$GITHUB_REPO"
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
echo "  All secrets set. You're ready to build."
echo "=========================================="
echo ""
echo "Trigger your first TestFlight build:"
echo "  https://github.com/$GITHUB_REPO/actions/workflows/testflight.yml"
echo ""
echo "Or run:"
echo "  gh workflow run testflight.yml --repo $GITHUB_REPO"
echo ""
