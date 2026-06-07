# AI Processing Evidence — Design Spec

**Date:** 2026-06-07  
**Status:** Approved

## Problem

The AI Upscaler plugin runs inside an FCP XPC service. There is no visible confirmation that the CoreML engine is actually executing — the output looks similar to the MPS/Lanczos fallback, making it impossible to tell from the FCP timeline alone whether the AI model is processing frames or silently falling back.

Two mechanisms are needed:
1. A structured per-frame log in the XPC service to confirm engine, timing, and success/failure during FCP use.
2. A standalone test that produces visual diff images proving CoreML output differs from MPS output.

---

## Design

### Part 1 — Structured Per-Frame Log in the XPC Service

**File:** `AIUpscaler/AIUpscaler/Plugin/AIUpscalerPlugIn.swift`

Replace the current `srcBounds=...` log line in `renderDestinationImage` with a JSON-per-line entry written to `/tmp/aiupscaler_debug.txt`.

#### Log format (one JSON object per line)

```json
{"ts":1749123456,"engine":"CoreML","scale":2,"inputW":1280,"inputH":720,"inferenceMs":312,"ok":true}
{"ts":1749123457,"engine":"MPS_fallback","scale":2,"inputW":386,"inputH":288,"inferenceMs":11,"ok":false,"error":"realesrgan_2x.mlmodelc not found in bundle"}
```

#### Fields

| Field | Type | Description |
|-------|------|-------------|
| `ts` | Int | Unix timestamp (seconds) |
| `engine` | String | `"CoreML"`, `"MPS"` (user-selected Fast), or `"MPS_fallback"` (CoreML selected but failed) |
| `scale` | Int | 2 or 4 |
| `inputW`, `inputH` | Int | Source texture dimensions in pixels |
| `inferenceMs` | Int | Wall-clock time of `processor.process()` in milliseconds |
| `ok` | Bool | `true` if the user-selected engine ran; `false` if fell back to MPS |
| `error` | String | Present only when `ok=false`; contains the thrown error description |

#### Key diagnostic signal

CoreML inference on 512×512 tiles takes 200–400ms per frame. MPS Lanczos takes <20ms. If `engine="CoreML"` but `inferenceMs < 30`, the log reveals a silent fallback that the status parameter may have missed.

#### Implementation sketch

```swift
// In renderDestinationImage, replace existing log block:
let inferenceStart = Date()
let result = try processor.process(...)
let inferenceMs = Int(Date().timeIntervalSince(inferenceStart) * 1000)

let engineLabel: String
if state.engineMode == 0 && !usedFallback { engineLabel = "CoreML" }
else if state.engineMode == 1 { engineLabel = "MPS" }
else { engineLabel = "MPS_fallback" }

var entry: [String: Any] = [
    "ts": Int(Date().timeIntervalSince1970),
    "engine": engineLabel,
    "scale": scaleFactor.rawValue,
    "inputW": sourceTexture.width,
    "inputH": sourceTexture.height,
    "inferenceMs": inferenceMs,
    "ok": !usedFallback
]
if usedFallback, let err = lastFallbackError {
    entry["error"] = err.localizedDescription
}
// Append JSON line to /tmp/aiupscaler_debug.txt
```

---

### Part 2 — `CoreMLEvidenceTests` Test Suite

**New file:** `AIUpscaler/AIUpscalerTests/CoreMLEvidenceTests.swift`

A single test `testAIProducesDistinctOutput` that:

1. **Generates a synthetic 512×512 `MTLTexture`** via a Metal compute shader — a gradient with sharp edges and fine detail (checkerboard + ramp). No external image file required.

2. **Processes with both engines:**
   - `CoreMLUpscaler(scaleFactor: .x2, computeUnits: .cpuAndGPU)` → `output_ai` (1024×1024)
   - `MPSUpscaler(scaleFactor: .x2)` → `output_mps` (1024×1024)

3. **Saves 4 PNGs to `/tmp/aiupscaler_evidence/`:**
   - `input.png` — 512×512 synthetic input
   - `output_ai.png` — CoreML result
   - `output_fast.png` — MPS/Lanczos result
   - `diff_amplified.png` — `|output_ai − output_mps| × 5` per channel, saved as RGB image

4. **Asserts that outputs differ:**
   ```swift
   let diffSum = computePixelDiffSum(output_ai, output_mps)
   XCTAssertGreaterThan(diffSum, 0,
       "CoreML output is identical to MPS — AI model may have fallen back to Lanczos")
   ```
   Prints: `✓ diff sum: 2847392 — CoreML is running and producing distinct output`

#### Output directory

`/tmp/aiupscaler_evidence/` — created by the test if absent. Files are overwritten on each run.

#### Diff image encoding

Each pixel in `diff_amplified.png`:
- `R = clamp(|ai.R − mps.R| × 5, 0, 1)`
- `G = clamp(|ai.G − mps.G| × 5, 0, 1)`
- `B = clamp(|ai.B − mps.B| × 5, 0, 1)`

A fully black diff means the outputs are identical (AI fell back). Any visible color proves CoreML is transforming pixels differently from MPS.

#### Helper: texture → PNG

Uses `CIImage(mtlTexture:)` → `CIContext.writePNGRepresentation(of:to:format:colorSpace:)`. This is already available in the test target (no new dependencies).

---

## Files Changed

| File | Change |
|------|--------|
| `AIUpscaler/AIUpscaler/Plugin/AIUpscalerPlugIn.swift` | Replace `srcBounds` log with structured JSON log; record `inferenceMs` and `ok` |
| `AIUpscaler/AIUpscalerTests/CoreMLEvidenceTests.swift` | New file — `testAIProducesDistinctOutput` |

---

## Testing This Design

```bash
# Run the evidence test
xcodebuild test -scheme AIUpscalerTests \
  -project AIUpscaler/AIUpscaler.xcodeproj \
  -destination 'platform=macOS'

# Inspect outputs
open /tmp/aiupscaler_evidence/

# Check XPC log after using the plugin in FCP
cat /tmp/aiupscaler_debug.txt | python3 -m json.tool
```

Expected on success:
- `diff_amplified.png` has visible colored pixels (non-black) → CoreML is running
- `aiupscaler_debug.txt` shows `"engine":"CoreML"` with `inferenceMs` > 100

Expected on failure (model not loading):
- `diff_amplified.png` is all black → test fails with assertion message
- `aiupscaler_debug.txt` shows `"engine":"MPS_fallback"` with `"ok":false`
