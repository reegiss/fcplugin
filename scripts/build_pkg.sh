#!/usr/bin/env bash
# build_pkg.sh — Full distribution pipeline for AI Upscaler
#
# Usage:
#   ./scripts/build_pkg.sh [--version 1.1] [--skip-notarize] [--skip-dmg]
#
# Required env vars (or Xcode/keychain-stored profile):
#   DEVELOPER_ID_APP        "Developer ID Application: Name (TEAMID)"
#   DEVELOPER_ID_INSTALLER  "Developer ID Installer: Name (TEAMID)"
#   NOTARYTOOL_PROFILE      Keychain profile name (xcrun notarytool store-credentials)
#                           OR set APPLE_ID + APP_PASSWORD + TEAM_ID
#
# Output:
#   dist/
#     AIUpscaler-<version>.pkg     Signed + notarized component package
#     AIUpscaler-<version>.dmg     Distributable disk image

set -euo pipefail

# ── Configuration ────────────────────────────────────────────────────────────

PRODUCT_NAME="AI Upscaler"
BUNDLE_ID="info.regismelo.aiupscaler"
VERSION="${VERSION:-1.1}"
SCHEME="Wrapper Application"
PROJECT="AIUpscaler/AIUpscaler.xcodeproj"
APP_NAME="AIUpscaler.app"             # Xcode output name
INSTALL_APP_NAME="AIUpscaler.app"     # Public install name

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PKG_SCRIPTS="$REPO_ROOT/scripts/pkg/scripts"
PKG_RESOURCES="$REPO_ROOT/scripts/pkg/Resources"
DISTRIBUTION_XML="$REPO_ROOT/scripts/pkg/Distribution.xml"
MOTION_TEMPLATE="$REPO_ROOT/templates/AI Upscaler.moef"

BUILD_DIR="$REPO_ROOT/.build_pkg"
PAYLOAD_ROOT="$BUILD_DIR/payload"
DIST_DIR="$REPO_ROOT/dist"

SKIP_NOTARIZE=false
SKIP_DMG=false
SKIP_PKG_SIGN=false   # set true to build unsigned pkg (local testing only)

# ── Argument parsing ─────────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
    case $1 in
        --version)    VERSION="$2"; shift 2 ;;
        --skip-notarize) SKIP_NOTARIZE=true; shift ;;
        --skip-dmg)       SKIP_DMG=true; shift ;;
        --skip-pkg-sign)  SKIP_PKG_SIGN=true; shift ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

PKG_OUTPUT="$DIST_DIR/AIUpscaler-${VERSION}.pkg"
DMG_OUTPUT="$DIST_DIR/AIUpscaler-${VERSION}.dmg"

# ── Helpers ──────────────────────────────────────────────────────────────────

log()  { echo "▶ $*"; }
ok()   { echo "  ✓ $*"; }
err()  { echo "✗ ERROR: $*" >&2; exit 1; }

require_env() {
    [[ -n "${!1:-}" ]] || err "Missing required env var: $1"
}

# ── Preflight ────────────────────────────────────────────────────────────────

log "Preflight checks"

[[ -f "$DISTRIBUTION_XML" ]]   || err "Missing Distribution.xml — run from repo root"
[[ -f "$MOTION_TEMPLATE" ]]    || err "Missing $MOTION_TEMPLATE — copy .moef into templates/ first"
[[ -d "$PKG_SCRIPTS" ]]        || err "Missing scripts/pkg/scripts/"
[[ -d "$PKG_RESOURCES" ]]      || err "Missing scripts/pkg/Resources/"

require_env DEVELOPER_ID_APP
[[ "$SKIP_PKG_SIGN" == false ]] && require_env DEVELOPER_ID_INSTALLER

if [[ "$SKIP_NOTARIZE" == false ]]; then
    if [[ -z "${NOTARYTOOL_PROFILE:-}" ]]; then
        require_env APPLE_ID
        require_env APP_PASSWORD
        require_env TEAM_ID
    fi
fi

ok "All inputs present"

# ── Step 1: Release build ────────────────────────────────────────────────────

log "Step 1/8 — Release build (arm64)"

xcodebuild build \
    -scheme "$SCHEME" \
    -project "$PROJECT" \
    -destination 'platform=macOS,arch=arm64' \
    -configuration Release \
    ARCHS=arm64 \
    | xcpretty --quiet 2>/dev/null || xcodebuild build \
        -scheme "$SCHEME" \
        -project "$PROJECT" \
        -destination 'platform=macOS,arch=arm64' \
        -configuration Release \
        ARCHS=arm64

# Locate the built .app
BUILT_APP=$(find ~/Library/Developer/Xcode/DerivedData/AIUpscaler-*/Build/Products/Release \
    -name "$APP_NAME" -type d 2>/dev/null | sort | tail -1)

[[ -n "$BUILT_APP" ]] || err "Could not locate $APP_NAME in DerivedData"
ok "Built: $BUILT_APP"

# ── Step 2: Verify signing ───────────────────────────────────────────────────

log "Step 2/8 — Verify code signature"

codesign --verify --deep --strict --verbose=0 "$BUILT_APP" \
    || err "Code signature invalid — check DEVELOPER_ID_APP"
spctl --assess --type exec --verbose=0 "$BUILT_APP" \
    || err "Gatekeeper check failed — is the Developer ID certificate trusted?"

ok "Signature valid: $(codesign -dvv "$BUILT_APP" 2>&1 | grep 'TeamIdentifier' | head -1)"

# ── Step 3: Assemble PKG payload ─────────────────────────────────────────────

log "Step 3/8 — Assemble payload"

rm -rf "$BUILD_DIR"
mkdir -p "$PAYLOAD_ROOT/Library/Plug-Ins/FxPlug"
mkdir -p "$PAYLOAD_ROOT/Library/Application Support/$PRODUCT_NAME"
mkdir -p "$DIST_DIR"

# Install .app (rename to public name, strip internal V2)
cp -R "$BUILT_APP" "$PAYLOAD_ROOT/Library/Plug-Ins/FxPlug/$INSTALL_APP_NAME"

# Install Motion template to a system path; postinstall will copy to ~/Movies/
cp "$MOTION_TEMPLATE" "$PAYLOAD_ROOT/Library/Application Support/$PRODUCT_NAME/AI Upscaler.moef"

# Set correct permissions (755 dirs, 644 files, 755 executables)
find "$PAYLOAD_ROOT" -type d -exec chmod 755 {} \;
find "$PAYLOAD_ROOT" -type f -exec chmod 644 {} \;
find "$PAYLOAD_ROOT" -name "*.app" -prune -o -name "*.xpc" -prune -o -perm +111 -print \
    -exec chmod 755 {} \; 2>/dev/null || true
find "$PAYLOAD_ROOT" -path "*/MacOS/*" -type f -exec chmod 755 {} \;

ok "Payload assembled at $PAYLOAD_ROOT"

# ── Step 4: Build component PKG ──────────────────────────────────────────────

log "Step 4/8 — pkgbuild (component package)"

COMPONENT_PKG="$BUILD_DIR/AIUpscaler.pkg"

PKGBUILD_ARGS=(
    --root "$PAYLOAD_ROOT"
    --identifier "$BUNDLE_ID"
    --version "$VERSION"
    --scripts "$PKG_SCRIPTS"
    --install-location "/"
)
[[ "$SKIP_PKG_SIGN" == false ]] && PKGBUILD_ARGS+=(--sign "$DEVELOPER_ID_INSTALLER")

pkgbuild "${PKGBUILD_ARGS[@]}" "$COMPONENT_PKG"

ok "Component package: $COMPONENT_PKG"

# ── Step 5: productbuild (distribution package) ──────────────────────────────

log "Step 5/8 — productbuild (distribution installer)"

PRODUCTBUILD_ARGS=(
    --distribution "$DISTRIBUTION_XML"
    --resources "$PKG_RESOURCES"
    --package-path "$BUILD_DIR"
)
[[ "$SKIP_PKG_SIGN" == false ]] && PRODUCTBUILD_ARGS+=(--sign "$DEVELOPER_ID_INSTALLER")

productbuild "${PRODUCTBUILD_ARGS[@]}" "$PKG_OUTPUT"

ok "Distribution package: $PKG_OUTPUT"

# ── Step 6: Notarize ─────────────────────────────────────────────────────────

if [[ "$SKIP_NOTARIZE" == true ]]; then
    log "Step 6/8 — Notarization SKIPPED (--skip-notarize)"
else
    log "Step 6/8 — Notarize (this takes 1–5 minutes)"

    if [[ -n "${NOTARYTOOL_PROFILE:-}" ]]; then
        xcrun notarytool submit "$PKG_OUTPUT" \
            --keychain-profile "$NOTARYTOOL_PROFILE" \
            --wait \
            --timeout 600
    else
        xcrun notarytool submit "$PKG_OUTPUT" \
            --apple-id "$APPLE_ID" \
            --password "$APP_PASSWORD" \
            --team-id "$TEAM_ID" \
            --wait \
            --timeout 600
    fi

    ok "Notarization complete"

    log "Step 7/8 — Staple notarization ticket"
    xcrun stapler staple "$PKG_OUTPUT"
    ok "Ticket stapled"
fi

# ── Step 7: Verify final PKG ─────────────────────────────────────────────────

log "Verifying final package"
pkgutil --check-signature "$PKG_OUTPUT" | grep -E "Status|Certificate" || true

# ── Step 8: Create DMG ───────────────────────────────────────────────────────

if [[ "$SKIP_DMG" == true ]]; then
    log "Step 8/8 — DMG creation SKIPPED (--skip-dmg)"
else
    log "Step 8/8 — Create distributable DMG"

    DMG_STAGING="$BUILD_DIR/dmg_staging"
    mkdir -p "$DMG_STAGING"
    cp "$PKG_OUTPUT" "$DMG_STAGING/"

    # Optionally copy README/release notes
    [[ -f "$REPO_ROOT/scripts/pkg/Resources/readme.rtf" ]] \
        && cp "$REPO_ROOT/scripts/pkg/Resources/readme.rtf" "$DMG_STAGING/ReadMe.rtf"

    rm -f "$DMG_OUTPUT"
    hdiutil create \
        -volname "$PRODUCT_NAME $VERSION" \
        -srcfolder "$DMG_STAGING" \
        -ov \
        -format UDZO \
        -imagekey zlib-level=9 \
        "$DMG_OUTPUT"

    ok "DMG: $DMG_OUTPUT"
fi

# ── Summary ──────────────────────────────────────────────────────────────────

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Build complete — $PRODUCT_NAME $VERSION"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  PKG: $PKG_OUTPUT"
[[ "$SKIP_DMG" == false ]] && echo "  DMG: $DMG_OUTPUT"
echo ""
echo "  Next:"
echo "    • Test the installer on a clean machine"
echo "    • Verify PlugInKit: pluginkit -m -i info.regismelo.AIUpscaler.XPCService"
echo "    • Open FCP and confirm effect appears under Effects > AI Upscaler"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
