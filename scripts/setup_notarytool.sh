#!/usr/bin/env bash
# setup_notarytool.sh — Store notarization credentials in keychain (run once)
#
# After running this script, use NOTARYTOOL_PROFILE=AIUpscaler in build_pkg.sh.
# Credentials are stored securely in your login keychain, never in env vars.
#
# Requirements:
#   - Apple Developer account with App Store Connect access
#   - App-specific password from appleid.apple.com (not your main account password)
#   - Team ID from developer.apple.com/account (10-char string, e.g. ABC1234567)

set -euo pipefail

PROFILE_NAME="AIUpscaler"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Notarytool credentials setup"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "You will be prompted for:"
echo "  • Apple ID (your developer email)"
echo "  • App-specific password (from appleid.apple.com > App-Specific Passwords)"
echo "  • Team ID (from developer.apple.com/account, 10 chars)"
echo ""

xcrun notarytool store-credentials "$PROFILE_NAME" \
    --apple-id "" \
    --team-id ""

echo ""
echo "✓ Credentials stored as profile: $PROFILE_NAME"
echo ""
echo "To use in build_pkg.sh:"
echo "  NOTARYTOOL_PROFILE=$PROFILE_NAME ./scripts/build_pkg.sh"
