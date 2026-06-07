# AI Processing Evidence Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prove the CoreML engine is running by (1) writing a structured JSON log per frame in the XPC plugin, and (2) adding a test that saves 4 PNGs to `/tmp/aiupscaler_evidence/` — input, AI output, MPS output, and an amplified diff — asserting the two outputs differ.

**Architecture:** Two independent changes. Part 1 modifies `AIUpscalerPlugIn.swift` to replace the existing plain-text log with JSON that includes engine label, scale, input dimensions, inference time, and fallback flag. Part 2 adds `CoreMLEvidenceTests.swift` which generates a synthetic checkerboard texture, runs both engines, reads pixel data via blit to a shared texture, computes the pixel diff on CPU, and saves everything as PNGs.

**Tech Stack:** Swift 5.9, Metal, CoreML, MetalPerformanceShaders, Swift Testing framework (`import Testing`), CoreGraphics for PNG export, Foundation for JSON serialization.

---

## File Map

| Action | Path |
|--------|------|
| Modify | `AIUpscaler/AIUpscaler/Plugin/AIUpscalerPlugIn.swift` |
| Create | `AIUpscaler/AIUpscalerTests/CoreMLEvidenceTests.swift` |

---

### Task 1: Structured JSON Log in the XPC Plugin

**Files:**
- Modify: `AIUpscaler/AIUpscaler/Plugin/AIUpscalerPlugIn.swift`

- [ ] **Step 1: Add `fallbackError` capture variable and timing**

Open `AIUpscaler/AIUpscaler/Plugin/AIUpscalerPlugIn.swift`. Find `renderDestinationImage`. Replace the section from the existing log block through the end of the `processor.process()` calls (lines 101–158 in the current file) with the version below. The key changes are: (a) `fallbackError: String?` captures the error message in both catch blocks, (b) `inferenceStart` is measured before both process() calls, (c) the old `srcBounds=...` log block is removed, (d) `appendLogEntry` is called after the result is known.

Replace everything from `guard let sourceImage = sourceImages.first` through `updateStatus(engineMode:...)` (keep `updateStatus` — only replace what's between the guard and it):

```swift
        guard let sourceImage = sourceImages.first else { return }

        let scaleFactor: ScaleFactor = state.scaleFactor == 0 ? .x2 : .x4
        let deviceCache = MetalDeviceCache.shared

        guard let device = deviceCache.device(forRegistryID: sourceImage.deviceRegistryID),
              let commandQueue = deviceCache.commandQueue(forRegistryID: sourceImage.deviceRegistryID)
        else { throw UpscalerError.metalDeviceUnavailable }
        defer { deviceCache.returnCommandQueue(commandQueue, forRegistryID: sourceImage.deviceRegistryID) }

        guard let sourceTexture = sourceImage.metalTexture(for: device),
              let destTexture   = destinationImage.metalTexture(for: device)
        else { throw UpscalerError.metalDeviceUnavailable }

        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw UpscalerError.metalDeviceUnavailable
        }

        var usedFallback = false
        var fallbackError: String?
        let activeEngine: any UpscalerEngine

        if state.engineMode == 0 {
            do {
                activeEngine = try resolvedEngine(scale: scaleFactor, engineMode: 0, device: device)
            } catch {
                logger.error("CoreML warmup failed: \(error.localizedDescription, privacy: .public)")
                activeEngine = try resolvedEngine(scale: scaleFactor, engineMode: 1, device: device)
                usedFallback = true
                fallbackError = error.localizedDescription
            }
        } else {
            activeEngine = try resolvedEngine(scale: scaleFactor, engineMode: 1, device: device)
        }

        let processor = TileProcessor(device: device)
        let result: MTLTexture
        let inferenceStart = Date()

        if state.engineMode == 0 && !usedFallback {
            do {
                result = try processor.process(input: sourceTexture, scaleFactor: scaleFactor,
                                               engine: activeEngine, commandBuffer: commandBuffer)
            } catch {
                logger.error("CoreML render failed: \(error.localizedDescription, privacy: .public)")
                let mpsEngine = try resolvedEngine(scale: scaleFactor, engineMode: 1, device: device)
                result = try processor.process(input: sourceTexture, scaleFactor: scaleFactor,
                                               engine: mpsEngine, commandBuffer: commandBuffer)
                usedFallback = true
                fallbackError = error.localizedDescription
            }
        } else {
            result = try processor.process(input: sourceTexture, scaleFactor: scaleFactor,
                                           engine: activeEngine, commandBuffer: commandBuffer)
        }

        let inferenceMs = Int(Date().timeIntervalSince(inferenceStart) * 1000)

        let engineLabel: String
        if state.engineMode == 0 && !usedFallback { engineLabel = "CoreML" }
        else if state.engineMode == 1             { engineLabel = "MPS" }
        else                                      { engineLabel = "MPS_fallback" }

        appendLogEntry(engine: engineLabel, scale: scaleFactor.rawValue,
                       inputW: sourceTexture.width, inputH: sourceTexture.height,
                       inferenceMs: inferenceMs, ok: !usedFallback, error: fallbackError)

        // result is source×scaleFactor; destTexture may differ — scale to fit.
        if result.width == destTexture.width && result.height == destTexture.height {
            guard let blit = commandBuffer.makeBlitCommandEncoder() else {
                throw UpscalerError.metalDeviceUnavailable
            }
            blit.copy(from: result, to: destTexture)
            blit.endEncoding()
        } else {
            // AI upscaled intermediate → Lanczos downsample to destination size.
            // Net effect: AI-enhanced quality at the same output dimensions.
            MPSImageLanczosScale(device: device)
                .encode(commandBuffer: commandBuffer,
                        sourceTexture: result,
                        destinationTexture: destTexture)
        }

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
```

- [ ] **Step 2: Add `appendLogEntry` helper method**

At the bottom of `UpscalerEffect`, after the closing brace of `resolvedEngine`, add:

```swift
    private func appendLogEntry(engine: String, scale: Int, inputW: Int, inputH: Int,
                                inferenceMs: Int, ok: Bool, error: String?) {
        var dict: [String: Any] = [
            "ts": Int(Date().timeIntervalSince1970),
            "engine": engine,
            "scale": scale,
            "inputW": inputW,
            "inputH": inputH,
            "inferenceMs": inferenceMs,
            "ok": ok
        ]
        if let error { dict["error"] = error }
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let line = String(data: data, encoding: .utf8)
        else { return }
        let entry = (line + "\n").data(using: .utf8)!
        let url = URL(fileURLWithPath: "/tmp/aiupscaler_debug.txt")
        if FileManager.default.fileExists(atPath: url.path),
           let fh = try? FileHandle(forWritingTo: url) {
            fh.seekToEndOfFile(); fh.write(entry); try? fh.close()
        } else {
            try? entry.write(to: url)
        }
    }
```

- [ ] **Step 3: Verify it builds**

```bash
xcodebuild build \
  -scheme "Wrapper Application" \
  -project AIUpscaler/AIUpscaler.xcodeproj \
  -destination 'platform=macOS,arch=arm64' \
  -configuration Release \
  ARCHS=arm64 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add AIUpscaler/AIUpscaler/Plugin/AIUpscalerPlugIn.swift
git commit -m "feat: replace plain log with structured JSON log per frame (engine, inferenceMs, ok)"
```

---

### Task 2: CoreMLEvidenceTests — diff visual test

**Files:**
- Create: `AIUpscaler/AIUpscalerTests/CoreMLEvidenceTests.swift`

- [ ] **Step 1: Create the test file**

Create `AIUpscaler/AIUpscalerTests/CoreMLEvidenceTests.swift` with the full content below. This is all one file — read it in full before editing.

```swift
import Testing
import Metal
import CoreML
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import AIUpscaler

@Suite struct CoreMLEvidenceTests {

    var device: MTLDevice { MTLCreateSystemDefaultDevice()! }

    // Generates a synthetic 512×512 checkerboard texture, processes it with both engines,
    // saves 4 PNGs to /tmp/aiupscaler_evidence/, and asserts the AI output differs from MPS.
    @Test func aiProducesDistinctOutput() async throws {
        let device = device
        guard let queue = device.makeCommandQueue() else {
            Issue.record("Could not create MTLCommandQueue")
            return
        }

        // 1. Synthetic 512×512 BGRA checkerboard (8×8 px blocks)
        let inputTex = try makeCheckerboard(device: device, size: 512)

        // 2a. CoreML 2× (cpuAndGPU avoids ANE sandbox crash in tests)
        let coremlEngine = CoreMLUpscaler(scaleFactor: .x2, device: device, computeUnits: .cpuAndGPU)
        try await coremlEngine.warmup()
        let processor = TileProcessor(device: device)

        let cbAI = try #require(queue.makeCommandBuffer())
        let outputAI = try processor.process(input: inputTex, scaleFactor: .x2,
                                             engine: coremlEngine, commandBuffer: cbAI)
        cbAI.commit(); cbAI.waitUntilCompleted()

        // 2b. MPS Lanczos 2×
        let mpsEngine = MPSUpscaler(scaleFactor: .x2, device: device)
        let cbMPS = try #require(queue.makeCommandBuffer())
        let outputMPS = try processor.process(input: inputTex, scaleFactor: .x2,
                                              engine: mpsEngine, commandBuffer: cbMPS)
        cbMPS.commit(); cbMPS.waitUntilCompleted()

        // 3. Save PNGs
        let dir = URL(fileURLWithPath: "/tmp/aiupscaler_evidence")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        try savePNG(texture: inputTex,   device: device, queue: queue,
                    to: dir.appendingPathComponent("input.png"))
        try savePNG(texture: outputAI,   device: device, queue: queue,
                    to: dir.appendingPathComponent("output_ai.png"))
        try savePNG(texture: outputMPS,  device: device, queue: queue,
                    to: dir.appendingPathComponent("output_fast.png"))

        // 4. Compute diff (CPU), save diff_amplified.png
        let aiPixels  = try readPixels(from: outputAI,  device: device, queue: queue)
        let mpsPixels = try readPixels(from: outputMPS, device: device, queue: queue)
        let (diffPixels, diffSum) = amplifiedDiff(a: aiPixels, b: mpsPixels, factor: 5)

        let diffTex = try pixelsToTexture(pixels: diffPixels, width: outputAI.width,
                                          height: outputAI.height, device: device)
        try savePNG(texture: diffTex, device: device, queue: queue,
                    to: dir.appendingPathComponent("diff_amplified.png"))

        print("Evidence saved to /tmp/aiupscaler_evidence/")
        print("diff sum: \(diffSum) — \(diffSum > 0 ? "CoreML running ✓" : "IDENTICAL — possible fallback ✗")")

        // 5. Assert
        #expect(diffSum > 0,
            "CoreML output is identical to MPS — AI model may have fallen back to Lanczos")
    }

    // MARK: - Helpers

    private func makeCheckerboard(device: MTLDevice, size: Int) throws -> MTLTexture {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: size, height: size, mipmapped: false)
        desc.storageMode = .shared
        desc.usage = [.shaderRead, .shaderWrite]
        guard let tex = device.makeTexture(descriptor: desc) else {
            throw Err("makeCheckerboard: device.makeTexture returned nil")
        }
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        let block = 8
        for y in 0..<size {
            for x in 0..<size {
                let v: UInt8 = ((x / block + y / block) % 2 == 0) ? 255 : 0
                let i = (y * size + x) * 4
                pixels[i] = v; pixels[i+1] = v; pixels[i+2] = v; pixels[i+3] = 255
            }
        }
        tex.replace(region: MTLRegionMake2D(0, 0, size, size),
                    mipmapLevel: 0, withBytes: pixels, bytesPerRow: size * 4)
        return tex
    }

    // Blits `source` to a .shared texture so getBytes() can read it on CPU.
    private func readPixels(from source: MTLTexture, device: MTLDevice,
                            queue: MTLCommandQueue) throws -> [UInt8] {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: source.width, height: source.height, mipmapped: false)
        desc.storageMode = .shared
        guard let readable = device.makeTexture(descriptor: desc) else {
            throw Err("readPixels: device.makeTexture returned nil")
        }
        guard let cb = queue.makeCommandBuffer(),
              let blit = cb.makeBlitCommandEncoder() else {
            throw Err("readPixels: could not create command buffer or blit encoder")
        }
        blit.copy(from: source, to: readable)
        blit.endEncoding(); cb.commit(); cb.waitUntilCompleted()

        let count = source.width * source.height * 4
        var pixels = [UInt8](repeating: 0, count: count)
        readable.getBytes(&pixels, bytesPerRow: source.width * 4,
                          from: MTLRegionMake2D(0, 0, source.width, source.height),
                          mipmapLevel: 0)
        return pixels
    }

    // Returns (diffPixels, sum-of-all-channel-differences).
    // diff pixel = clamp(|a - b| * factor, 0, 255) per B/G/R channel; alpha = 255.
    private func amplifiedDiff(a: [UInt8], b: [UInt8], factor: Int) -> ([UInt8], Int) {
        var out = [UInt8](repeating: 0, count: a.count)
        var sum = 0
        for i in stride(from: 0, to: a.count, by: 4) {
            for c in 0..<3 {
                let d = abs(Int(a[i+c]) - Int(b[i+c]))
                sum += d
                out[i+c] = UInt8(min(d * factor, 255))
            }
            out[i+3] = 255
        }
        return (out, sum)
    }

    // Creates a .shared MTLTexture from a flat BGRA pixel array.
    private func pixelsToTexture(pixels: [UInt8], width: Int, height: Int,
                                 device: MTLDevice) throws -> MTLTexture {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        desc.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: desc) else {
            throw Err("pixelsToTexture: device.makeTexture returned nil")
        }
        tex.replace(region: MTLRegionMake2D(0, 0, width, height),
                    mipmapLevel: 0, withBytes: pixels, bytesPerRow: width * 4)
        return tex
    }

    // Reads pixels from `texture` (via blit if needed), builds a CGImage, writes PNG.
    private func savePNG(texture: MTLTexture, device: MTLDevice,
                         queue: MTLCommandQueue, to url: URL) throws {
        let pixels = try readPixels(from: texture, device: device, queue: queue)
        let w = texture.width, h = texture.height

        // BGRA → CGImage: declare as BGRA with premultiplied alpha so CoreGraphics maps correctly.
        let bitmapInfo = CGBitmapInfo(rawValue:
            CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        let data = Data(pixels)
        guard let provider = CGDataProvider(data: data as CFData),
              let cgImage = CGImage(width: w, height: h,
                                    bitsPerComponent: 8, bitsPerPixel: 32,
                                    bytesPerRow: w * 4,
                                    space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: bitmapInfo,
                                    provider: provider,
                                    decode: nil, shouldInterpolate: false,
                                    intent: .defaultIntent)
        else { throw Err("savePNG: CGImage creation failed") }

        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw Err("savePNG: CGImageDestination creation failed for \(url.lastPathComponent)") }
        CGImageDestinationAddImage(dest, cgImage, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw Err("savePNG: CGImageDestinationFinalize failed for \(url.lastPathComponent)")
        }
    }

    private struct Err: Error, CustomStringConvertible {
        let description: String
        init(_ msg: String) { description = msg }
    }
}
```

- [ ] **Step 2: Run the evidence test**

```bash
xcodebuild test -scheme AIUpscalerTests \
  -project AIUpscaler/AIUpscaler.xcodeproj \
  -destination 'platform=macOS' \
  -only-testing:AIUpscalerTests/CoreMLEvidenceTests 2>&1 | grep -E "passed|failed|diff sum|evidence|error:"
```

Expected output (success):
```
Evidence saved to /tmp/aiupscaler_evidence/
diff sum: NNNNNN — CoreML running ✓
Test Suite 'CoreMLEvidenceTests' passed
```

Expected output (failure — CoreML not running):
```
diff sum: 0 — IDENTICAL — possible fallback ✗
CoreMLEvidenceTests.aiProducesDistinctOutput — CoreML output is identical to MPS
Test Suite 'CoreMLEvidenceTests' failed
```

- [ ] **Step 3: Open evidence folder and inspect images**

```bash
open /tmp/aiupscaler_evidence/
```

In Finder/Preview, verify:
- `input.png` — black and white checkerboard 512×512
- `output_ai.png` — 1024×1024 checkerboard processed by CoreML (may show sharpening/haloing)
- `output_fast.png` — 1024×1024 checkerboard processed by Lanczos (smooth bilinear look)
- `diff_amplified.png` — **must not be all-black** if CoreML is running; should show amplified pixel differences along edges

- [ ] **Step 4: Run all tests to check no regressions**

```bash
xcodebuild test -scheme AIUpscalerTests \
  -project AIUpscaler/AIUpscaler.xcodeproj \
  -destination 'platform=macOS' 2>&1 | grep -E "passed|failed|error:"
```

Expected: all suites pass.

- [ ] **Step 5: Commit**

```bash
git add AIUpscaler/AIUpscalerTests/CoreMLEvidenceTests.swift
git commit -m "test: add CoreMLEvidenceTests — save diff PNGs proving AI output differs from MPS"
```

---

## Verifying in FCP (after rebuilding and reinstalling)

After Task 1 is complete:

```bash
# Rebuild and reinstall
xcodebuild build \
  -scheme "Wrapper Application" \
  -project AIUpscaler/AIUpscaler.xcodeproj \
  -destination 'platform=macOS,arch=arm64' \
  -configuration Release ARCHS=arm64

PLUGIN=$(find ~/Library/Developer/Xcode/DerivedData/AIUpscaler-*/Build/Products/Release \
  -name "AIUpscaler.app" -type d 2>/dev/null | head -1)
rm -rf ~/Library/Plug-Ins/FxPlug/AIUpscaler.app
cp -R "$PLUGIN" ~/Library/Plug-Ins/FxPlug/
/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister \
  -f -R -trusted ~/Library/Plug-Ins/FxPlug/AIUpscaler.app
pkill -x AIUpscaler 2>/dev/null; sleep 1
open ~/Library/Plug-Ins/FxPlug/AIUpscaler.app

# After applying the effect in FCP:
rm -f /tmp/aiupscaler_debug.txt
# (apply effect to a clip, scrub a few frames)
cat /tmp/aiupscaler_debug.txt | python3 -m json.tool
```

Expected entry for CoreML running:
```json
{
  "ts": 1749200000,
  "engine": "CoreML",
  "scale": 2,
  "inputW": 1280,
  "inputH": 720,
  "inferenceMs": 312,
  "ok": true
}
```

If `inferenceMs < 30` with `engine = "CoreML"`, there is a silent fallback — investigate model loading.
