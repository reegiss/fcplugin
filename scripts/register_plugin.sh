#!/bin/bash
set -e

APP_NAME="AIUpscaler"
XPC_NAME="AIUpscalerXPC"
BUNDLE_ID="info.regismelo.AIUpscaler"
XPC_ID="info.regismelo.AIUpscaler.XPCService"
DEST_DIR="/Applications"

echo "--- Starting Plugin Registration ---"

# Cleanup
echo "Cleaning up existing registration..."
pluginkit -r "$XPC_ID" || true

# Copy
echo "Deploying to $DEST_DIR..."
if [ -d "AIUpscaler/build/Release/$APP_NAME.app" ]; then
    rm -rf "$DEST_DIR/$APP_NAME.app" || echo "Note: Could not delete existing app."
    cp -R "AIUpscaler/build/Release/$APP_NAME.app" "$DEST_DIR/"
else
    echo "Error: $APP_NAME.app not found. Build first."
    exit 1
fi

APP_PATH="$DEST_DIR/$APP_NAME.app"
XPC_PATH="$APP_PATH/Contents/PlugIns/$XPC_NAME.pluginkit"

# Entitlements paths
XPC_ENT="AIUpscaler/AIUpscaler/Plugin/XPCService.entitlements"
APP_ENT="AIUpscaler/AIUpscaler/Wrapper Application/SandboxEntitlements.entitlements"

echo "Codesigning (ad-hoc) with entitlements..."

# 1. Sign Frameworks
find "$XPC_PATH" -name "*.framework" -type d | while read fw; do
    codesign --force --sign - --timestamp=none "$fw"
done

# 2. Sign XPC Binary
codesign --force --sign - --entitlements "$XPC_ENT" --timestamp=none "$XPC_PATH/Contents/MacOS/$XPC_NAME"

# 3. Sign XPC Bundle (the pluginkit)
codesign --force --sign - --entitlements "$XPC_ENT" --timestamp=none "$XPC_PATH"

# 4. Sign Wrapper App Binary
codesign --force --sign - --entitlements "$APP_ENT" --timestamp=none "$APP_PATH/Contents/MacOS/$APP_NAME"

# 5. Sign Wrapper App Bundle
codesign --force --sign - --entitlements "$APP_ENT" --timestamp=none "$APP_PATH"

echo "Registering plugin..."
/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister -f "$APP_PATH"
pluginkit -a "$XPC_PATH"
pluginkit -e use -i "$XPC_ID"

echo "Verifying registration..."
pluginkit -mAv | grep "$XPC_ID"

echo "--- Done ---"
