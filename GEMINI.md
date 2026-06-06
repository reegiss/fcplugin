# AI Upscaler for Final Cut Pro & Motion — Project Context

This document provides architectural overview, development workflows, and engineering mandates for the AI Upscaler project.

## Project Overview

AI Upscaler is a production-grade **Final Cut Pro / Motion video effect plugin** built with **Apple FxPlug 4**. It performs on-device AI video upscaling using RealESRGAN models, with zero network dependencies.

- **Primary Goal:** High-quality local upscaling (2×, 4×) accelerated by Apple Silicon.
- **Architecture:** Out-of-process XPC bundle (`.pluginkit`) packaged inside a wrapper application (`.app`).
- **Core Pipeline:** Tiled processing (512×512 tiles with 16px overlap) to handle high-resolution frames (4K+) within GPU memory constraints.

## Technology Stack

- **Language:** Swift 5.9+ (Swift-only implementation; FxPlug types via ObjC bridging header).
- **APIs:** FxPlug 4 SDK (v4.3.4), Core ML (RealESRGAN), Metal (Blit & MPS).
- **Models:** RealESRGAN x2plus and x4plus (compiled `.mlmodelc` format).
- **Build System:** Xcode 16 / `xcodebuild`.

## Key Commands

### Build & Test
```bash
# Build tests
xcodebuild build -scheme AIUpscalerTests -project AIUpscaler/AIUpscaler.xcodeproj -destination 'platform=macOS'

# Run unit and integration tests
xcodebuild test -scheme AIUpscalerTests -project AIUpscaler/AIUpscaler.xcodeproj -destination 'platform=macOS'
```

### Model Management
```bash
# Generate .mlpackage from PyTorch (requires python3.11 + coremltools + torch)
python3.11 scripts/convert_realesrgan.py

# Compile .mlpackage to .mlmodelc (required for runtime)
xcrun coremlc compile AIUpscaler/AIUpscaler/Resources/realesrgan_2x.mlpackage AIUpscaler/AIUpscaler/Resources/
xcrun coremlc compile AIUpscaler/AIUpscaler/Resources/realesrgan_4x.mlpackage AIUpscaler/AIUpscaler/Resources/
```

### Local Installation for FCP (Manual Testing)
```bash
# Copy built app to FCP's plugin container
INSTALL_DIR=~/Library/Containers/com.apple.FinalCutApp/Data/Library/Application\ Support/Plug-ins/ProPlug
ditto AIUpscaler/build/Release/AIUpscaler.app "$INSTALL_DIR/AIUpscaler.app"

# Verify registration
pluginkit -mAv | grep -i upscaler
```

## Architectural Mandates

### FxPlug Lifecycle & Threading
- **No `import FxPlug`:** FxPlug types are provided via `XPC Service-Bridging-Header.h`. Ignore SourceKit "Cannot find type" errors; verify via `xcodebuild`.
- **Render Thread Safety:** `renderDestinationImage` is called by the host (FCP/Motion). Ensure all engine access and state updates are thread-safe.
- **Deterministic Rendering:** The plugin must produce bit-identical results for the same frame/parameters to avoid flickering during FCP playback/scrub.
- **Out-of-Process:** The plugin runs in an XPC service. Do not rely on `Bundle.main`; use `Bundle(for: SomeClass.self)` to locate resources.

### GPU & Memory Management
- **Metal Resource Pooling:** Use `MetalDeviceCache` for `MTLDevice` and `MTLCommandQueue` to avoid expensive recreation.
- **Tiling:** Large frames MUST be processed in tiles using `TileProcessor` to prevent GPU timeouts and excessive memory pressure.
- **Pixel Normalization:** CoreML models expect float32 RGB in `[0, 1]`. Handle BGRA texture conversion and normalization carefully in `CoreMLUpscaler`.

### Error Handling & Fallback
- **Silent Failures Forbidden:** Use `UpscalerError` to signal failures.
- **Graceful Fallback:** If AI (CoreML) fails (warmup error or runtime crash), automatically fall back to `MPSUpscaler` (Lanczos) and update the "Status" parameter to inform the user.

## Development Conventions

- **File Organization:**
  - `Engine/`: Upscaling logic (CoreML, MPS).
  - `Tiling/`: Frame splitting and stitching.
  - `Plugin/`: FxPlug entry points and host API glue.
  - `Resources/`: Compiled ML models and Metal shaders.
- **Testing:** Every new engine feature or tiling change must have a corresponding test in `AIUpscalerTests`.
- **Documentation:** Refer to `docs/distribution.md` for signing, notarization, and PKG creation details.

## Known Constraints
- **Model Size:** `.mlmodelc` files are large (~33MB) and excluded from Git. They must be generated locally.
- **Host Validation:** Always smoke test in Final Cut Pro after architectural changes, as the host environment (sandboxing, XPC latency) differs from unit tests.
