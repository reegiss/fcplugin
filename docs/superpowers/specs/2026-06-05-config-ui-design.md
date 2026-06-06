# Configuration UI Implementation Design

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Expose Scale (2×/4×) and Engine (AI/Fast) as user-configurable parameters in the FCP inspector, with a read-only Status field that updates when the AI engine falls back to MPS.

**Architecture:** Modify `AIUpscalerPlugIn.swift` to declare three parameters via `FxParameterCreationAPI_v5`, read them in `pluginState()`, and select the correct engine at render time. Fallback from CoreML to MPS is caught in the render path and reflected in the Status string via `FxParameterSettingAPI_v5`.

**Tech Stack:** FxPlug 4 (`FxParameterCreationAPI_v5`, `FxParameterSettingAPI_v5`, `FxParameterRetrievalAPI_v6`), Swift, CoreML, Metal Performance Shaders, `os_log`

---

## Parameters

| ID | Constant | Name displayed | Type | Items | Default |
|----|----------|---------------|------|-------|---------|
| 1 | `kParamScale` | "Scale" | Popup | "2×" (0), "4×" (1) | 0 (2×) |
| 2 | `kParamEngine` | "Engine" | Popup | "AI – Best Quality" (0), "Fast – Lanczos" (1) | 0 (AI) |
| 3 | `kParamStatus` | "Status" | String | n/a | "● AI Active" |

`kParamStatus` is declared with `kFxParameterFlag_DISABLED` so it appears read-only in the FCP inspector. It is not included in `StateData` because it has no effect on rendering.

## StateData

```swift
private struct StateData {
    var scaleFactor: Int32   // 0 = 2×, 1 = 4×
    var engineMode:  Int32   // 0 = AI (CoreML), 1 = Fast (MPS)
}
```

## Engine Cache

`UpscalerEffect` holds `private var engines: [String: any UpscalerEngine] = [:]`. The key is `"\(engineMode)-\(scaleRaw)"`, yielding up to four cached instances (2 engines × 2 scales).

On the first call for a given key, the engine is created and warmed up synchronously using a `DispatchSemaphore` that blocks the calling thread until the async `warmup()` completes. This blocking occurs at most once per (engine, scale) combination per plugin instance lifetime.

## Fallback Strategy

In `renderDestinationImage()`, if the selected engine is CoreML and it throws (warmup failure or inference error):

1. Create (or reuse cached) `MPSUpscaler` for the same `ScaleFactor`.
2. Retry render with the MPS engine.
3. Call `FxParameterSettingAPI_v5.setStringParameterValue("⚠ AI unavailable – using Fast", toParameter: kParamStatus)`.
4. Log via `os_log(.error, "CoreML engine failed: %{public}@", error.localizedDescription)`.

When AI is selected and working normally, the Status string reads `"● AI Active"`. When Fast is selected intentionally by the user, it reads `"● Fast Active"`. The Status string is updated from `renderDestinationImage()` on any state change (engine switch or recovery).

## Status String Values

| Situation | Status string |
|-----------|--------------|
| Engine = AI, working | `"● AI Active"` |
| Engine = Fast (user choice) | `"● Fast Active"` |
| Engine = AI, fallback triggered | `"⚠ AI unavailable – using Fast"` |

## Files

- **Modify:** `AIUpscaler/AIUpscaler/Plugin/AIUpscalerPlugIn.swift`
  - `addParameters()`: add `kParamStatus` string parameter; fix engine popup order (AI=0, Fast=1) and default (0=AI); fix scale default (0=2×).
  - `pluginState()`: read `kParamScale` and `kParamEngine` into `StateData`.
  - `renderDestinationImage()`: implement fallback block + status string update.
  - `resolvedEngine()`: replace fire-and-forget `Task` with `DispatchSemaphore` sync warmup; surface errors instead of swallowing them.

No other files change. `CoreMLUpscaler`, `MPSUpscaler`, `UpscalerEngine`, `TileProcessor`, and all test files are untouched.

## Error Handling

- CoreML warmup failure (model not found, OOM, ANE unavailable): caught in `resolvedEngine()`, propagated to render, triggers fallback.
- CoreML inference failure (mid-render crash): caught in `renderDestinationImage()`, triggers fallback.
- MPS fallback failure: propagated as `UpscalerError`, FCP shows its standard effect-error indicator.
- `FxParameterSettingAPI_v5` call failure: ignored (status display is best-effort; render result is unaffected).

## Testing

Existing `CoreMLUpscalerTests`, `MPSUpscalerTests`, `PipelineIntegrationTests`, `TileCalculatorTests`, and `UpscalerErrorTests` are unaffected.

New unit tests in `AIUpscalerPlugInTests.swift` (if the host can be mocked) are out of scope — `UpscalerEffect` requires a live `PROAPIAccessing` instance which is only available inside FCP/Motion. Manual verification: install the built `.fxplug` to `~/Library/Plug-Ins/FxPlug/`, apply the effect in FCP, confirm both popups appear with correct defaults, confirm Status updates on engine switch.
