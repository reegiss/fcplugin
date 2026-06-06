# CLAUDE.md

This file provides implementation guidance for Claude Code when working in this repository.

## Mission

Build a production-grade **Final Cut Pro / Motion video effect plugin** using **Apple FxPlug 4** that performs **on-device AI video upscaling** with no network dependency.

Official reference:
- FxPlug documentation: https://developer.apple.com/documentation/professional-video-applications/fxplug

---

## Product Goal

Create a native effect that integrates into **Final Cut Pro** and **Motion**, allowing editors to upscale video locally on Apple hardware using AI acceleration.

Primary product goals:
- Native integration with Apple professional video apps
- On-device inference only
- Stable preview behavior in editing workflows
- Higher-quality final render path than preview path
- Commercially viable architecture for Apple silicon systems

Non-goals for v1:
- Cloud inference
- Windows support
- Full temporal multi-frame super-resolution
- 8K-first positioning
- Overpromising real-time performance on all hardware

---

## Project Status

**Plugin confirmed working inside Final Cut Pro.** Core pipeline is validated end-to-end.

What is done:
- Xcode project scaffolded at `AIUpscaler/AIUpscaler.xcodeproj`
- `UpscalerEffect` implementing `FxTileableEffect` (plugin entry point)
- `CoreMLUpscaler` — RealESRGAN inference via `MLMultiArray`
- `MPSUpscaler` — Lanczos fallback via `MPSImageLanczosScale` + sharpen
- `TileProcessor` — 512×512 tiles with 16px overlap, Metal blit stitching
- `MetalDeviceCache` — thread-safe MTLDevice + command queue pool
- RealESRGAN x2plus and x4plus models converted to `.mlmodelc`
- 3 FCP inspector parameters: Scale (2×/4×), Engine (AI/Fast), Status (read-only)
- 14 unit/integration tests, all passing
- Motion template at `~/Movies/Motion Templates.localized/Effects.localized/AI Upscaler.localized/AI Upscaler.moef`
- Plugin confirmed visible and loadable in Final Cut Pro Creator Studio 12.2 on macOS 26

What is NOT done:
- No benchmark report
- No preview vs. final render path differentiation
- Thread-safety of `engines` dictionary (known issue, low priority)

---

## Build & Install (Complete Procedure)

> Guia completo de distribuição (signing, notarização, PKG/DMG): `docs/distribution.md`

### 1. Build

```bash
# Build with real Developer ID certificate (REQUIRED — see signing constraints below)
xcodebuild build \
  -scheme "Wrapper Application" \
  -project AIUpscaler/AIUpscaler.xcodeproj \
  -destination 'platform=macOS,arch=arm64' \
  -configuration Release \
  ARCHS=arm64
```

**Do NOT use `CODE_SIGN_IDENTITY="-"` (ad-hoc).** On macOS 26, ad-hoc signing causes a DYLD crash at XPC launch because `PluginManager.framework` and `FxPlug.framework` have a different team ID than the XPC binary. All components must share the same team ID.

### 2. Install

```bash
PLUGIN=$(find ~/Library/Developer/Xcode/DerivedData/AIUpscaler-*/Build/Products/Release \
  -name "AIUpscalerV2.app" -type d 2>/dev/null | head -1)

rm -rf ~/Library/Plug-Ins/FxPlug/AIUpscalerV2.app
cp -R "$PLUGIN" ~/Library/Plug-Ins/FxPlug/

# Register with LaunchServices (required for PlugInKit discovery)
/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister \
  -f -R -trusted ~/Library/Plug-Ins/FxPlug/AIUpscalerV2.app

# Launch the wrapper app ONCE to trigger PlugInKit registration
pkill -x AIUpscalerV2 2>/dev/null; sleep 1
open ~/Library/Plug-Ins/FxPlug/AIUpscalerV2.app
```

### 3. Verify PlugInKit registration

```bash
pluginkit -m -i "info.regismelo.AIUpscalerV2.XPCService"
# Expected output:  info.regismelo.AIUpscalerV2.XPCService(1.1)
```

### 4. Use in Final Cut Pro

**FxPlug plugins do NOT appear directly in FCP's Effects browser.** They must be wrapped in a Motion template (`.moef` file). The template is at:

```
~/Movies/Motion Templates.localized/Effects.localized/AI Upscaler.localized/AI Upscaler.moef
```

This file references the plugin by its UUID (`C1D48F7E-1867-42C3-9C89-9329EA2E1E9D`) and publishes Scale and Engine parameters. Restart FCP after installing the template; the effect appears in the Effects browser under **AI Upscaler**.

### Run tests

```bash
xcodebuild test -scheme AIUpscalerTests \
  -project AIUpscaler/AIUpscaler.xcodeproj \
  -destination 'platform=macOS'
```

---

## Confirmed Technology Stack

- **Language:** Swift 5.9+ (no Obj-C source files; FxPlug is exposed via ObjC bridging header)
- **Plugin API:** FxPlug 4 SDK v4.3.4, macOS 13+ deployment target
- **FxPlug entry point:** `FxTileableEffect` protocol
- **Parameter APIs:** `FxParameterCreationAPI_v5`, `FxParameterRetrievalAPI_v6`, `FxParameterSettingAPI_v5`
- **AI/ML:** Core ML — `MLModel.load(contentsOf:)` async, `MLMultiArray` float32 input/output
- **GPU:** Metal blit commands for tile extraction/stitching; `MPSImageLanczosScale` for fallback
- **Models:** RealESRGAN x2plus and x4plus (`.mlmodelc` compiled format, ~33MB each)
- **Build system:** Xcode 16, `PBXFileSystemSynchronizedRootGroup`

---

## FxPlug Architecture — Confirmed Facts

FxPlug plugins are **out-of-process XPC bundles** packaged inside a wrapper application.

Plugin structure:
- Wrapper Application target — hosts the XPC service, bundles models as resources
- XPC Service target — runs `UpscalerEffect` (the actual `FxTileableEffect` implementation)
- AIUpscalerTests target — unit/integration tests import `AIUpscaler` module (Wrapper Application)

### Code Signing — Critical Constraints (macOS 26)

On macOS 26 (Tahoe), DYLD enforces that all dylibs loaded into a process share the same Team ID as the process. This means:

- **All components must be signed with the same Developer ID certificate** — the XPC binary, `FxPlug.framework`, and `PluginManager.framework` inside the bundle.
- The build phase scripts in `project.pbxproj` that copy and sign the FxPlug frameworks use `${EXPANDED_CODE_SIGN_IDENTITY}` (not hard-coded `"-"`), so they inherit the certificate from the Xcode project settings.
- `ENABLE_HARDENED_RUNTIME = YES` for all targets (must match the pre-built frameworks which also have the runtime flag).
- `ENABLE_APP_SANDBOX` is disabled for the XPC service — FxPlug XPC services are not App Extensions and must not be sandboxed.

### Info.plist — Critical Fields (XPC Service)

```xml
<!-- PlugInKit section — makes the XPC discoverable by macOS -->
<key>PlugInKit</key>
<dict>
    <key>Protocol</key>
    <string>PROXPCProtocol</string>          <!-- must be exactly this -->
    <key>PrincipalClass</key>
    <string>FxPrincipal</string>
    <key>Attributes</key>
    <dict>
        <key>com.apple.protocol</key>
        <string>FxPlug</string>
        <key>com.apple.version</key>
        <string>1.1</string>
    </dict>
</dict>

<!-- ProPlugPlugInList — protocolNames MUST be FxFilter or FxGenerator -->
<!-- NOT FxTileableEffect, even though the class implements FxTileableEffect -->
<!-- FCP uses this to categorize the effect type -->
<key>protocolNames</key>
<array>
    <string>FxFilter</string>
</array>
```

### PlugInKit Registration — How It Works

FCP uses macOS `PlugInKit` to discover plugins, NOT by directly scanning `~/Library/Plug-Ins/FxPlug/`. The discovery flow is:

1. Copy `.app` bundle to `~/Library/Plug-Ins/FxPlug/`
2. Run `lsregister -f -R -trusted <app>` to notify LaunchServices
3. **Launch the wrapper `.app` once** — this triggers PlugInKit to scan and index the XPC service bundle
4. FCP queries PlugInKit on launch and receives the plugin

Skipping step 3 means the plugin is never indexed and FCP never sees it. `pluginkit -mAv` will NOT list `PROXPCProtocol` plugins — this is normal. Use `pluginkit -m -i <bundleID>` to verify.

### Motion Template — Required for FCP

**FxPlug plugins appear in Motion's filter library but NOT directly in FCP's Effects browser.** To use in FCP, a Motion template (`.moef`) must wrap the plugin:

- Location: `~/Movies/Motion Templates.localized/Effects.localized/<Name>.localized/<Name>.moef`
- The `.moef` is plain XML referencing the plugin by its `pluginUUID` (from `ProPlugPlugInList` in Info.plist)
- Parameters to expose to FCP editors are declared in `<publishSettings>`
- Template source: `~/Movies/Motion Templates.localized/Effects.localized/AI Upscaler.localized/AI Upscaler.moef`

Key fields in the `.moef` filter element:
```xml
<filter name="AI Upscaler"
        factoryID="6"
        pluginUUID="C1D48F7E-1867-42C3-9C89-9329EA2E1E9D"
        pluginVersion="1"
        pluginName="AIUpscalerPlugIn"
        pluginDynamicParams="0">
```

### Other Key Facts

- **No `import FxPlug` in Swift** — FxPlug types come exclusively from the ObjC bridging header (`XPC Service-Bridging-Header.h`). SourceKit will show false-positive "Cannot find type" errors — ignore them, use `xcodebuild build` to verify.
- **`FxRect` fields are `Int32`**, not `Double`.
- **`pluginState()` → `renderDestinationImage()` data flow:** pack a `StateData` struct into `NSData` in `pluginState()`, unpack with `decodeState()` in the render method.
- **`PBXFileSystemSynchronizedRootGroup`** (Xcode 16) auto-compiles Swift files but does NOT auto-copy `.mlmodelc` directories. Added explicitly in `project.pbxproj` under all three `PBXResourcesBuildPhase` sections.
- **`Bundle(for: CoreMLUpscaler.self)`** — use instead of `Bundle.main` in tests.
- **CoreML compute units in tests:** use `MLComputeUnits.cpuAndGPU` (not `.all`) to avoid ANE crashes in the sandboxed test process. Production code uses `.all`.
- **`RegisterProExtension`** (FCP internal helper) crashes on macOS 26.5.1 due to `@rpath` security policy. This affects only the new "Pro Extensions" API — traditional FxPlug loading is unaffected.

---

## Upscaling Pipeline

1. `UpscalerEffect.renderDestinationImage()` receives `FxImageTile` source/destination
2. Reads `StateData` (scaleFactor, engineMode) from `pluginState` blob
3. Gets `MTLDevice` + command queue from `MetalDeviceCache`
4. Gets `MTLTexture` handles from `FxImageTile.metalTexture(for:)`
5. `resolvedEngine()` lazy-inits and warms up the selected engine (sync via `DispatchSemaphore`)
6. `TileProcessor.process()` splits source into 512×512 tiles (16px overlap), calls engine per tile, blits results into stitched output texture
7. Blits stitched result onto destination texture
8. `updateStatus()` writes to FCP inspector Status parameter via `FxParameterSettingAPI_v5`

CoreML inference path:
- Input: BGRA `MTLTexture` → float32 `MLMultiArray` [1, 3, H, W], values in [0, 1]
- Model: RealESRGAN x2plus (pixel_unshuffle(2) → scale=4 RRDBNet, net 2×) or x4plus (scale=4 RRDBNet)
- Output: float32 `MLMultiArray` [1, 3, H×scale, W×scale] → BGRA `MTLTexture`, values clamped to [0, 1]
- Model input is fixed 512×512; tile processor ensures this

Fallback path (CoreML fails):
- `resolvedEngine()` throws on warmup failure → render falls back to `MPSUpscaler`
- `processor.process()` throws mid-inference → falls back to `MPSUpscaler` for that frame
- Status string updated to `"⚠ AI unavailable – using Fast"` in both cases

---

## Inspector Parameters

| ID | Name | Type | Values | Default |
|----|------|------|--------|---------|
| 1 | Scale | Popup | "2×" (0), "4×" (1) | 0 |
| 2 | Engine | Popup | "AI – Best Quality" (0), "Fast – Lanczos" (1) | 0 |
| 3 | Status | String (disabled) | "● AI Active" / "● Fast Active" / "⚠ AI unavailable – using Fast" | "● AI Active" |

---

## Test Suite

14 tests in 6 suites, all in `AIUpscaler/AIUpscalerTests/`:

| Suite | Tests |
|-------|-------|
| `AIUpscalerTests` | placeholder example |
| `CoreMLUpscalerTests` | warmup 2x, warmup 4x, outputDimensions 2x (uses `.cpuAndGPU`) |
| `MPSUpscalerTests` | outputDimensions 2x, outputDimensions 4x |
| `PipelineIntegrationTests` | full pipeline MPS 2x (1920×1080→3840×2160), MPS 4x (960×540→3840×2160) |
| `TileCalculatorTests` | singleTile, tileCount, interiorTile, reconstructedSize |
| `UpscalerErrorTests` | allCasesHaveDescription, modelLoadFailedEmbeds |

---

## Source Tree

```
AIUpscaler/
  AIUpscaler/
    Engine/
      UpscalerEngine.swift       — protocol: scaleFactor, upscale(), warmup()
      CoreMLUpscaler.swift       — RealESRGAN via MLMultiArray
      MPSUpscaler.swift          — Lanczos + sharpen via MPS
    Error/
      UpscalerError.swift        — modelLoadFailed, metalDeviceUnavailable, tileSizeMismatch, renderTimeout
    Tiling/
      TileProcessor.swift        — calculateTiles() (pure/static), process() (Metal)
    Plugin/
      AIUpscalerPlugIn.swift     — UpscalerEffect: FxTileableEffect implementation
      MetalDeviceCache.swift     — thread-safe MTLDevice + command queue pool
      main.swift                 — XPC service entry point
      XPC Service-Bridging-Header.h
    Resources/
      realesrgan_2x.mlmodelc     — compiled CoreML model (not in git, ~33MB)
      realesrgan_4x.mlmodelc     — compiled CoreML model (not in git, ~33MB)
    Wrapper Application/
      AppDelegate.swift
  AIUpscalerTests/
    CoreMLUpscalerTests.swift
    MPSUpscalerTests.swift
    PipelineIntegrationTests.swift
    TileCalculatorTests.swift
    UpscalerErrorTests.swift
scripts/
  convert_realesrgan.py          — converts PyTorch weights to .mlpackage (Python 3.11)
docs/superpowers/
  specs/                         — brainstorming design docs
  plans/                         — implementation plans
~/Movies/Motion Templates.localized/Effects.localized/
  AI Upscaler.localized/
    AI Upscaler.moef             — Motion template that makes the plugin available in FCP
```

---

## Known Issues & Future Work

- **Thread safety:** `engines: [String: UpscalerEngine]` dictionary in `UpscalerEffect` has no lock — concurrent renders for different (scale, engine) combos could race. Fix: `NSLock` or actor.
- **Status from render thread:** `FxParameterSettingAPI_v5` is called inside `renderDestinationImage()`. FxPlug behavior here is best-effort; the call is non-blocking over XPC.
- **No preview vs. final render differentiation:** both paths use the same engine. The `quality` parameter in `pluginState()` is currently ignored.
- **Models not in git:** `.mlmodelc` files are large binary assets (~33MB each) and excluded from version control. Run `convert_realesrgan.py` then `xcrun coremlc compile` to regenerate.
- **Motion template not versioned:** `AI Upscaler.moef` lives in `~/Movies/` (outside the repo). Should be copied into the repo and documented in the install script for reproducible setup.

---

## Coding Rules

- Keep rendering code deterministic
- No `import FxPlug` in Swift files — FxPlug types come exclusively from the ObjC bridging header
- Use `xcodebuild build` (not SourceKit) to verify compilation; SourceKit reports false positives for FxPlug types
- Avoid hidden global state
- Prefer explicit resource ownership
- Isolate ML inference from host API glue code
- `Bundle(for: SomeClass.self)` not `Bundle.main` when locating resources in tests or non-app contexts
- Comment only where FxPlug lifecycle or host behavior is non-obvious

---

## Performance Constraints

Every implementation decision must be evaluated against:
- Latency per frame (render thread blocks until complete)
- Peak unified memory usage (no swap on Apple Silicon)
- Render determinism (FCP re-renders on scrub)
- Tile boundary artifact rate

Before expanding features, establish benchmark tables for:
- 1080p 2× / 4× — Draft / Final
- 4K 2× / 4× — Draft / Final
- M1 / M2 / M3 target devices
