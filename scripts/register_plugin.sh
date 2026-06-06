#!/bin/bash

# Configuration
PLUGIN_NAME="AIUpscaler"
SANDBOX_DIR="$HOME/Library/Containers/com.apple.FinalCutApp/Data/Library/Application Support/Plug-ins/ProPlug"
PROJECT_DIR="AIUpscaler"
BUILD_DIR="$PROJECT_DIR/build/Release"
APP_NAME="AIUpscaler.app"
PLUGIN_KIT="AIUpscaler XPC Service.pluginkit"

echo "--- Starting Plugin Registration ---"

# Ensure build exists
if [ ! -d "$BUILD_DIR" ]; then
    echo "Error: Build directory $BUILD_DIR not found. Please build the project first."
    exit 1
fi

# 1. Cleanup
echo "Cleaning up existing registration..."
# Try to unregister by path if it exists
if [ -d "$SANDBOX_DIR/$PLUGIN_KIT" ]; then
    pluginkit -r "$SANDBOX_DIR/$PLUGIN_KIT" 2>/dev/null
fi
rm -rf "$SANDBOX_DIR/$PLUGIN_KIT"
rm -rf "$SANDBOX_DIR/$APP_NAME"

# 2. Deploy
echo "Deploying to sandbox..."
mkdir -p "$SANDBOX_DIR"
ditto "$BUILD_DIR/$PLUGIN_KIT" "$SANDBOX_DIR/$PLUGIN_KIT"
ditto "$BUILD_DIR/$APP_NAME" "$SANDBOX_DIR/$APP_NAME"

# 3. Codesign
echo "Codesigning (ad-hoc)..."
# Ad-hoc sign (-s -) the inner pluginkit bundle and then the wrapper .app
codesign -s - --force --deep "$SANDBOX_DIR/$PLUGIN_KIT"
codesign -s - --force --deep "$SANDBOX_DIR/$APP_NAME"

# 4. Register
echo "Registering plugin..."
pluginkit -a "$SANDBOX_DIR/$PLUGIN_KIT"

# 5. Verify
echo "Verifying registration..."
pluginkit -mAv | grep -i "$PLUGIN_NAME"

echo "--- Done ---"
