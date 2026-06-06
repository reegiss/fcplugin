# FCP Plugin Loading & Registration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Resolve the issue where the AI Upscaler plugin is not visible in Final Cut Pro by auditing metadata and implementing a registration script.

**Architecture:** We will surgically fix the `Info.plist` and entitlements for the XPC Service to comply with FxPlug 4 standards, then implement a robust registration script that handles code signing and sandbox deployment.

**Tech Stack:** Bash, PlistBuddy, codesign, pluginkit.

---

### Task 1: Audit and Fix XPC Service Metadata

**Files:**
- Modify: `AIUpscaler/AIUpscaler/Plugin/Info.plist`
- Create: `AIUpscaler/AIUpscaler/Plugin/XPCService.entitlements`

- [ ] **Step 1: Update Info.plist for FxPlug 4 compliance**
Change `com.apple.protocol` to `com.apple.fxplug` and `protocolNames` to `FxTileableEffect`.

```bash
# Verify current state
cat AIUpscaler/AIUpscaler/Plugin/Info.plist
```

Apply changes:
```xml
<!-- In AIUpscaler/AIUpscaler/Plugin/Info.plist -->
<!-- Update com.apple.protocol -->
<key>com.apple.protocol</key>
<string>com.apple.fxplug</string>

<!-- Update protocolNames in ProPlugPlugInList -->
<key>protocolNames</key>
<array>
    <string>FxTileableEffect</string>
</array>
```

- [ ] **Step 2: Create XPCService.entitlements**
The XPC service needs `com.apple.security.inherit` to run inside the host's sandbox.

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.security.app-sandbox</key>
	<true/>
	<key>com.apple.security.inherit</key>
	<true/>
</dict>
</plist>
```

- [ ] **Step 3: Commit metadata changes**
```bash
git add AIUpscaler/AIUpscaler/Plugin/Info.plist AIUpscaler/AIUpscaler/Plugin/XPCService.entitlements
git commit -m "fix: align XPC service metadata with FxPlug 4 requirements"
```

### Task 2: Implement Registration Script

**Files:**
- Create: `scripts/register_plugin.sh`

- [ ] **Step 1: Write the registration script**
This script implements the manual flow from the design spec.

```bash
#!/bin/bash
set -e

APP_NAME="AIUpscaler.app"
BUILD_DIR="AIUpscaler/build/Release"
TARGET_DIR="$HOME/Library/Containers/com.apple.FinalCutApp/Data/Library/Application Support/Plug-ins/ProPlug"
XPC_BUNDLE_ID="info.regismelo.AIUpscaler.XPCService"

echo "--- 1. Cleaning up ---"
pluginkit -r "$TARGET_DIR/$APP_NAME" 2>/dev/null || true
rm -rf "$TARGET_DIR/$APP_NAME"
mkdir -p "$TARGET_DIR"

echo "--- 2. Deploying to Sandbox ---"
if [ ! -d "$BUILD_DIR/$APP_NAME" ]; then
    echo "Error: $APP_NAME not found in $BUILD_DIR. Please build in Xcode first."
    exit 1
fi
ditto "$BUILD_DIR/$APP_NAME" "$TARGET_DIR/$APP_NAME"

echo "--- 3. Code Signing (Ad-hoc) ---"
# Sign the inner plugin first, then the wrapper
codesign -s - --deep --force "$TARGET_DIR/$APP_NAME/Contents/PlugIns/AIUpscaler XPC Service.pluginkit"
codesign -s - --deep --force "$TARGET_DIR/$APP_NAME"

echo "--- 4. Registering with PlugInKit ---"
pluginkit -a "$TARGET_DIR/$APP_NAME"

echo "--- 5. Verifying ---"
RESULT=$(pluginkit -mAv | grep -i "AIUpscaler")
if [ -z "$RESULT" ]; then
    echo "FAILED: Plugin not found in pluginkit database."
    exit 1
else
    echo "SUCCESS: Plugin registered."
    echo "$RESULT"
fi

echo ""
echo "Now restart Final Cut Pro and look for 'AI Upscaler' in Video Effects."
```

- [ ] **Step 2: Make the script executable**
```bash
chmod +x scripts/register_plugin.sh
```

- [ ] **Step 3: Commit the script**
```bash
git add scripts/register_plugin.sh
git commit -m "feat: add plugin registration script for local development"
```

### Task 3: Execution and Validation

- [ ] **Step 1: Run the registration script**
```bash
./scripts/register_plugin.sh
```

- [ ] **Step 2: Verify registration via terminal**
```bash
pluginkit -mAv | grep -i upscaler
```
Expected: Output showing the plugin as registered and valid.

- [ ] **Step 3: Instructions for Manual Validation**
1. Open Final Cut Pro.
2. Open the Effects Browser (CMD+5).
3. Search for "AI Upscaler".
4. Apply it to a clip.
5. Check if `AIUpscaler XPC Service` appears in Activity Monitor.
