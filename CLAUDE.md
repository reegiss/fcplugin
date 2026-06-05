# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a **Final Cut Pro / Motion plugin** built with Apple's FxPlug 4 API. The plugin provides **AI-powered video upscaling** running entirely on-device (no network calls), integrated directly into Final Cut Pro and Motion as a native effect.

Official API reference: https://developer.apple.com/documentation/professional-video-applications/fxplug

## Technology Stack

- **Language:** Swift + Objective-C/C++ (FxPlug requires Obj-C bridging for some APIs)
- **Plugin API:** FxPlug 4 (requires macOS 12+, Final Cut Pro 10.6.5+)
- **AI/ML:** Core ML for on-device inference; Vision framework for image processing
- **GPU:** Metal for custom render passes; MetalPerformanceShaders for ML acceleration
- **Build system:** Xcode project (`.xcodeproj`) with a plug-in bundle target

## FxPlug Architecture

FxPlug plugins are **out-of-process XPC bundles** (`.fxplug` package). Key protocol roles:

| Protocol | Purpose |
|---|---|
| `FxTileableEffect` | Frame-by-frame image processing (use this for upscaling) |
| `FxCustomParameterActionDelegate` | Custom UI parameter actions |
| `FxParameterCreationAPI` | Declares parameters (sliders, menus, checkboxes) |
| `FxParameterRetrievalAPI` | Reads parameter values at render time |

The host calls `renderDestination:sourceImages:destinationImage:pluginState:atTime:error:` for each frame. All rendering must happen inside this method using Metal command buffers.

## On-Device AI Upscaling

The upscaling pipeline:
1. Receive source `CVPixelBuffer` from FxPlug
2. Convert to `MTLTexture` via `CVMetalTextureCache`
3. Run Core ML model (e.g., ESRGAN or custom Super-Resolution model in `.mlpackage` format)
4. Write upscaled result to destination `MTLTexture`

Model considerations:
- Use `MLComputeUnits.all` to allow ANE (Neural Engine) + GPU execution
- Models should accept `CVPixelBuffer` or `MLMultiArray` input; prefer `CVPixelBuffer` to avoid copies
- Large frames must be tiled; tile size depends on model input dimensions

## Build & Run

> Project scaffolding not yet created. Once Xcode project exists:

```bash
# Build from command line
xcodebuild -scheme <PluginSchemeName> -configuration Debug build

# Install plugin for testing (symlink or copy to plug-ins folder)
cp -R build/Debug/<PluginName>.fxplug ~/Movies/FxPlug/

# Run tests
xcodebuild -scheme <PluginSchemeName> test
```

Plugin install paths (Final Cut Pro discovers plugins from):
- `~/Library/Plug-Ins/FxPlug/`
- `/Library/Plug-Ins/FxPlug/`

## Project Status

**Planning phase** — no source code yet. The readme captures the goal; implementation has not started. When scaffolding begins, use Xcode's "FxPlug" template (available after installing the FxPlug SDK from Apple Developer portal).
