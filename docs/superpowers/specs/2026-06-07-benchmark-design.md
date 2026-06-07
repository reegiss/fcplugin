# Benchmark — CoreML GPU vs MPS Design

**Goal:** Standalone CLI benchmark that compares CoreML GPU (zero-copy pipeline) vs MPS (Lanczos fallback) latency across five resolutions and two scale factors, producing a formatted table for internal performance analysis.

**Architecture:** Shell script compiles Metal shader + Swift engine sources into a self-contained binary. No new Xcode target. No external dependencies.

**Tech Stack:** Swift 5.9+, Metal, CoreML, MetalPerformanceShaders, swiftc CLI, xcrun metal/metallib

---

## Files

| File | Action | Purpose |
|------|--------|---------|
| `scripts/benchmark.swift` | Create | Benchmark logic — timing loop, table output |
| `scripts/run_benchmark.sh` | Create | Compilation + execution driver |

No existing files are modified.

---

## Compilation Flow (`run_benchmark.sh`)

1. Compile `AIUpscaler/AIUpscaler/Shaders/TileUpscaler.metal` → `default.metallib` via `xcrun metal` + `xcrun metallib`
2. Compile with `swiftc -O` the following Swift sources + `benchmark.swift` → `./benchmark` binary:
   - `Engine/CoreMLUpscaler.swift`
   - `Engine/MPSUpscaler.swift`
   - `Engine/UpscalerEngine.swift`
   - `Error/UpscalerError.swift`
   - `Tiling/TileProcessor.swift`
3. Copy `default.metallib` next to the `./benchmark` binary (required for `device.makeDefaultLibrary()`)
4. Execute `./benchmark`

`AIUpscalerPlugIn.swift` and all FxPlug-dependent files are excluded — the engine layer has no FxPlug dependency.

---

## Benchmark Loop (`benchmark.swift`)

**Scenarios:** 10 combinations — 5 resolutions × 2 scale factors.

| Resolution | Dimensions | Scales |
|------------|-----------|--------|
| 480p | 854×480 | 2×, 4× |
| 540p | 960×540 | 2×, 4× |
| 720p | 1280×720 | 2×, 4× |
| 1080p | 1920×1080 | 2×, 4× |
| 4K | 3840×2160 | 2×, 4× |

**Engines:** `CoreMLUpscaler` (GPU zero-copy path via Metal compute shaders + ANE) and `MPSUpscaler` (Lanczos + sharpen).

**Per scenario:**
1. Create synthetic `MTLTexture` (`.bgra8Unorm`, filled with noise via `replace(region:)`)
2. Warm up engine once (discarded) — loads CoreML model, compiles Metal pipelines, initialises MPS filters
3. Run 5 timed iterations of `TileProcessor.process(input:scaleFactor:engine:commandBuffer:)` — includes tile extraction, inference, and GPU blend reconstruction
4. Record wall-clock time per iteration using `clock_gettime(CLOCK_MONOTONIC)`

**Metrics per scenario:** `avg ms`, `min ms`, `max ms` for each engine.

---

## Output Format

```
=== AIUpscaler Benchmark ===
Device: <GPU name> | Iterations: 5

Resolution    Scale   CoreML avg   CoreML min   MPS avg   MPS min   ratio
──────────────────────────────────────────────────────────────────────────
480p            2×        --ms         --ms       --ms      --ms     --×
...

ratio = CoreML avg / MPS avg  (>1 = CoreML mais lento: troca velocidade por qualidade AI)
```

Output is plain text to stdout — redirect to a file with `./scripts/run_benchmark.sh > results.txt` if needed.

---

## Error Handling

- If CoreML model files (`realesrgan_2x.mlmodelc`, `realesrgan_4x.mlmodelc`) are not found in `AIUpscaler/AIUpscaler/Resources/`, the benchmark prints an error and exits with code 1.
- If Metal shader compilation fails, `run_benchmark.sh` exits before running the benchmark.
- If `CoreMLUpscaler` cannot load its Metal pipelines at runtime, it falls back to the CPU path — the benchmark notes `[CPU fallback]` next to the CoreML result.

---

## Running

```bash
./scripts/run_benchmark.sh

# Save results to file
./scripts/run_benchmark.sh > benchmark_results.txt
```

Requires: macOS 13+, Xcode CLI tools, `.mlmodelc` model files present in `AIUpscaler/AIUpscaler/Resources/`.
