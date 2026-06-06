# Design Spec: FCP Plugin Loading & Local Registration

**Date:** 2026-06-05  
**Status:** Approved  
**Topic:** Resolving FxPlug 4 visibility issues in Final Cut Pro (Local Development)

## 1. Problem Statement
The current build of the AI Upscaler plugin is not being discovered or loaded by Final Cut Pro, despite the core logic and tests being functional. This is due to the strict security and sandbox requirements of macOS and FxPlug 4, which require specific bundle placement, metadata alignment, and system registration.

## 2. Architecture & Sandbox Integration

### 2.1 Target Directory
To satisfy the Final Cut Pro sandbox, the plugin must be installed in the host's specific "ProPlug" container rather than global library folders.

*   **Path:** `~/Library/Containers/com.apple.FinalCutApp/Data/Library/Application Support/Plug-ins/ProPlug`
*   **Method:** Installation must use the `ditto` utility to preserve mandatory code signing attributes and extended metadata.

### 2.2 Bundle Structure (App-Wrapped Plugin)
The plugin follows the FxPlug 4 "Out-of-Process" model:
*   **Wrapper App:** `AIUpscaler.app` (The container)
*   **XPC Service:** `AIUpscaler.app/Contents/PlugIns/AIUpscaler XPC Service.pluginkit` (The actual logic)

## 3. Component Metadata (Manifests)

### 3.1 XPC Service Info.plist
Critical keys required for host discovery:
*   **NSExtension:**
    - `NSExtensionPointIdentifier`: `com.apple.fxplug`
    - `NSExtensionAttributes`: Contains the principal class mapping.
*   **ProPlugPlugInList:** Maps the Plugin UUID to the principal class `AIUpscalerPlugIn`.
*   **Protocol:** Must explicitly state `FxTileableEffect`.

### 3.2 Entitlements & Security
*   **Sandbox:** Both the Wrapper App and XPC Service must have `com.apple.security.app-sandbox` enabled.
*   **Inheritance:** The XPC Service must include `com.apple.security.inherit` to allow the FCP process to manage its lifecycle.

## 4. Manual Registration & Validation Flow

The following sequence of operations will be used to verify the Milestone 1 success:

1.  **Surgical Cleanup:** Remove any stale registrations of the plugin from the `pluginkit` database.
2.  **Ad-hoc Signing:** Apply deep, forced ad-hoc signatures (`codesign -s -`) to ensure the macOS gatekeeper accepts the XPC communication locally.
3.  **Registration:** Force-add the `.app` bundle to the system's extension database using `pluginkit -a`.
4.  **Verification:** Query the database using `pluginkit -mAv` to confirm the plugin is "on-disk" and "valid".

## 5. Success Criteria
*   **Visibility:** "AI Upscaler" appears in the Final Cut Pro Effects Browser under the "AI Upscaler" category.
*   **Instantiation:** Applying the effect triggers the launch of the `AIUpscaler XPC Service` process.
*   **Inspector:** The "Scale", "Engine", and "Status" parameters are visible and interactive in the FCP inspector.

## 6. Testing Strategy (E2E)
*   **Host Smoke Test:** Launch Final Cut Pro, apply the effect to a 1080p clip, and verify if the `Status` parameter updates to "● AI Active" or "● Fast Active".
*   **Process Monitoring:** Use `pgrep -la "AIUpscaler"` to confirm the out-of-process XPC service is alive.
