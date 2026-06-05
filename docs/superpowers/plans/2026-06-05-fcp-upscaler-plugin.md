# FCP AI Upscaler Plugin — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a Final Cut Pro/Motion FxPlug 4 plugin that upscales video 2x or 4x using on-device AI, with a fast MPS path for preview and a CoreML (RealESRGAN) path for export.

**Architecture:** Three-layer bundle: `UpscalerEffect` (FxPlug integration) → `TileProcessor` (tile/stitch) → `UpscalerEngine` implementations (`MPSUpscaler` + `CoreMLUpscaler`). Each frame is split into 512×512 tiles with 16px overlap, processed independently, and stitched back using only the inner (non-overlap) region of each upscaled tile to avoid seam artifacts.

**Tech Stack:** Swift 6, FxPlug 4 SDK, MetalPerformanceShaders, Core ML, Swift Testing (Xcode 16+)

---

## File Map

```
AIUpscaler/                           ← Xcode project root
├── AIUpscaler.xcodeproj/
├── AIUpscaler/                       ← plugin bundle target sources
│   ├── Info.plist
│   ├── Error/
│   │   └── UpscalerError.swift
│   ├── Engine/
│   │   ├── UpscalerEngine.swift      ← protocol + ScaleFactor + TileRegion
│   │   ├── MPSUpscaler.swift
│   │   └── CoreMLUpscaler.swift
│   ├── Tiling/
│   │   └── TileProcessor.swift
│   └── Plugin/
│       └── UpscalerEffect.swift
├── AIUpscalerTests/                  ← Swift Testing target
│   ├── UpscalerErrorTests.swift
│   ├── TileCalculatorTests.swift
│   ├── MPSUpscalerTests.swift
│   ├── CoreMLUpscalerTests.swift
│   └── PipelineIntegrationTests.swift
└── scripts/
    └── convert_realesrgan.py         ← one-time model conversion
```

---

## Task 1: Xcode Project Setup

**Files:**
- Create: `AIUpscaler/AIUpscaler.xcodeproj`
- Create: `AIUpscaler/AIUpscaler/Info.plist`

> These steps are manual in Xcode — no automated test for project setup.

- [ ] **Step 1: Download FxPlug 4 SDK**

Go to https://developer.apple.com/downloads, search "FxPlug", download and install the `.dmg`. After install, the framework is at `/Library/Frameworks/FxPlug.framework`.

- [ ] **Step 2: Create Xcode project**

File → New Project → macOS → **Bundle**
- Product Name: `AIUpscaler`
- Bundle Extension: `fxplug`
- Language: Swift
- Team: your Apple Developer team

- [ ] **Step 3: Configure build settings**

In the `AIUpscaler` target Build Settings:
- `MACOSX_DEPLOYMENT_TARGET` = `13.0`
- `ARCHS` = `arm64` (remove x86_64)
- `SWIFT_VERSION` = `5.9` (or 6.0 if available)
- `PRODUCT_BUNDLE_IDENTIFIER` = `com.yourcompany.aiupscaler`

- [ ] **Step 4: Link FxPlug framework**

Target → General → Frameworks and Libraries → `+` → Add Other → find `/Library/Frameworks/FxPlug.framework`. Set to "Do Not Embed".

- [ ] **Step 5: Add Swift Testing test target**

File → New Target → **Unit Testing Bundle**
- Name: `AIUpscalerTests`
- Testing system: **Swift Testing**

In `AIUpscalerTests` target Build Settings, add `AIUpscaler` to `SWIFT_IMPORT_OBJC_FORWARD_DECLARATIONS` and set the host application to none.

- [ ] **Step 6: Create source group folders**

In the project navigator, create groups: `Error/`, `Engine/`, `Tiling/`, `Plugin/` inside the `AIUpscaler` group. Create `scripts/` folder in Finder at the project root.

- [ ] **Step 7: Verify the project builds**

```bash
xcodebuild -scheme AIUpscaler -configuration Debug build
```

Expected: `BUILD SUCCEEDED`

---

## Task 2: UpscalerError

**Files:**
- Create: `AIUpscaler/AIUpscaler/Error/UpscalerError.swift`
- Create: `AIUpscaler/AIUpscalerTests/UpscalerErrorTests.swift`

- [ ] **Step 1: Write the failing test**

Create `AIUpscaler/AIUpscalerTests/UpscalerErrorTests.swift`:

```swift
import Testing
import Foundation
@testable import AIUpscaler

@Suite struct UpscalerErrorTests {

    @Test func allCasesHaveNonNilDescription() {
        struct Dummy: Error {}
        let cases: [UpscalerError] = [
            .modelLoadFailed(underlying: Dummy()),
            .metalDeviceUnavailable,
            .tileSizeMismatch(expected: CGSize(width: 512, height: 512),
                              got: CGSize(width: 256, height: 256)),
            .renderTimeout,
        ]
        for error in cases {
            #expect(error.errorDescription != nil)
            #expect(error.errorDescription?.isEmpty == false)
        }
    }

    @Test func modelLoadFailedEmbeddsUnderlyingMessage() {
        struct Cause: LocalizedError {
            var errorDescription: String? { "disk full" }
        }
        let error = UpscalerError.modelLoadFailed(underlying: Cause())
        #expect(error.errorDescription?.contains("disk full") == true)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
xcodebuild test -scheme AIUpscalerTests -destination 'platform=macOS'
```

Expected: FAIL — `UpscalerError` not defined.

- [ ] **Step 3: Implement UpscalerError**

Create `AIUpscaler/AIUpscaler/Error/UpscalerError.swift`:

```swift
import Foundation

enum UpscalerError: Error {
    case modelLoadFailed(underlying: Error)
    case metalDeviceUnavailable
    case tileSizeMismatch(expected: CGSize, got: CGSize)
    case renderTimeout // threshold: 5000ms per frame
}

extension UpscalerError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .modelLoadFailed(let e):
            return "Model load failed: \(e.localizedDescription)"
        case .metalDeviceUnavailable:
            return "Metal device unavailable on this system"
        case .tileSizeMismatch(let expected, let got):
            return "Tile size mismatch: expected \(expected), got \(got)"
        case .renderTimeout:
            return "Render exceeded 5000ms timeout — frame passed through unmodified"
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
xcodebuild test -scheme AIUpscalerTests -destination 'platform=macOS'
```

Expected: PASS — 2 tests passed.

- [ ] **Step 5: Commit**

```bash
git add AIUpscaler/AIUpscaler/Error/UpscalerError.swift \
        AIUpscaler/AIUpscalerTests/UpscalerErrorTests.swift
git commit -m "feat: add UpscalerError with localized descriptions"
```

---

## Task 3: UpscalerEngine Protocol, ScaleFactor, and TileRegion

**Files:**
- Create: `AIUpscaler/AIUpscaler/Engine/UpscalerEngine.swift`

No dedicated test — these are pure type definitions consumed by Tasks 4–9.

- [ ] **Step 1: Create the file**

Create `AIUpscaler/AIUpscaler/Engine/UpscalerEngine.swift`:

```swift
import Metal
import CoreGraphics

enum ScaleFactor: Int, CaseIterable {
    case x2 = 2
    case x4 = 4
}

/// Describes one tile to extract from the input, upscale, and place into the output.
struct TileRegion {
    /// Region to extract from the input texture (includes overlap padding).
    let inputRect: CGRect
    /// Offset within the upscaled tile where non-overlap content starts.
    let upscaledInnerOrigin: CGPoint
    /// Size of the non-overlap content in the upscaled tile.
    let upscaledInnerSize: CGSize
    /// Top-left corner in the output texture where this tile's content is placed.
    let outputOrigin: CGPoint
}

protocol UpscalerEngine: AnyObject {
    var scaleFactor: ScaleFactor { get }
    /// Upscales `input` and encodes GPU work into `commandBuffer`.
    /// Returns a new MTLTexture with dimensions `input.width * scaleFactor x input.height * scaleFactor`.
    func upscale(input: MTLTexture, commandBuffer: MTLCommandBuffer) throws -> MTLTexture
    /// Pre-loads model weights / MPS filters so first-frame latency is minimal.
    func warmup() async throws
}
```

- [ ] **Step 2: Verify project still builds**

```bash
xcodebuild -scheme AIUpscaler -configuration Debug build
```

Expected: `BUILD SUCCEEDED`

- [ ] **Step 3: Commit**

```bash
git add AIUpscaler/AIUpscaler/Engine/UpscalerEngine.swift
git commit -m "feat: add UpscalerEngine protocol, ScaleFactor, TileRegion"
```

---

## Task 4: TileProcessor — Tile Calculation (Pure Logic)

**Files:**
- Create: `AIUpscaler/AIUpscaler/Tiling/TileProcessor.swift` (partial — pure functions only)
- Create: `AIUpscaler/AIUpscalerTests/TileCalculatorTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `AIUpscaler/AIUpscalerTests/TileCalculatorTests.swift`:

```swift
import Testing
import CoreGraphics
@testable import AIUpscaler

@Suite struct TileCalculatorTests {

    // Single tile: image smaller than tileSize on both axes
    @Test func singleTileForSmallImage() {
        let tiles = TileProcessor.calculateTiles(
            inputWidth: 400, inputHeight: 300,
            tileSize: 512, overlap: 16, scaleFactor: 2
        )
        #expect(tiles.count == 1)
        let t = tiles[0]
        #expect(t.inputRect == CGRect(x: 0, y: 0, width: 400, height: 300))
        #expect(t.upscaledInnerOrigin == .zero)
        #expect(t.upscaledInnerSize == CGSize(width: 800, height: 600))
        #expect(t.outputOrigin == .zero)
    }

    // 1920x1080 → 4 cols × 3 rows = 12 tiles at 2x
    @Test func tileCountFor1080pAt2x() {
        let tiles = TileProcessor.calculateTiles(
            inputWidth: 1920, inputHeight: 1080,
            tileSize: 512, overlap: 16, scaleFactor: 2
        )
        #expect(tiles.count == 12) // ceil(1920/512)=4, ceil(1080/512)=3
    }

    // Interior tile (col=1, row=1) has overlap on all four sides
    @Test func interiorTileHasOverlapOnAllSides() {
        let tiles = TileProcessor.calculateTiles(
            inputWidth: 1920, inputHeight: 1080,
            tileSize: 512, overlap: 16, scaleFactor: 2
        )
        // tile at index col=1, row=1 → index = row*4 + col = 5
        let t = tiles[5]
        // inputRect starts 16px before the tile origin
        #expect(t.inputRect.origin.x == 512 - 16)
        #expect(t.inputRect.origin.y == 512 - 16)
        // inner origin in upscaled tile = 16*2 = 32 on both axes
        #expect(t.upscaledInnerOrigin == CGPoint(x: 32, y: 32))
        // inner size = 512 * 2 = 1024 on both axes
        #expect(t.upscaledInnerSize == CGSize(width: 1024, height: 1024))
        // output placed at col*tileSize*scale, row*tileSize*scale
        #expect(t.outputOrigin == CGPoint(x: 1 * 512 * 2, y: 1 * 512 * 2))
    }

    // Reconstructed output dimensions equal input × scaleFactor
    @Test func reconstructedSizeIsCorrect() {
        let w = 1920, h = 1080, scale = 2
        let tiles = TileProcessor.calculateTiles(
            inputWidth: w, inputHeight: h,
            tileSize: 512, overlap: 16, scaleFactor: scale
        )
        let maxX = tiles.map { $0.outputOrigin.x + $0.upscaledInnerSize.width }.max()!
        let maxY = tiles.map { $0.outputOrigin.y + $0.upscaledInnerSize.height }.max()!
        #expect(Int(maxX) == w * scale)
        #expect(Int(maxY) == h * scale)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
xcodebuild test -scheme AIUpscalerTests -destination 'platform=macOS'
```

Expected: FAIL — `TileProcessor` not defined.

- [ ] **Step 3: Implement calculateTiles**

Create `AIUpscaler/AIUpscaler/Tiling/TileProcessor.swift`:

```swift
import Metal
import CoreGraphics

final class TileProcessor {

    static let defaultTileSize = 512
    static let defaultOverlap  = 16

    private let device: MTLDevice

    init(device: MTLDevice) {
        self.device = device
    }

    // MARK: - Pure tile geometry (no Metal — fully testable)

    static func calculateTiles(
        inputWidth: Int,
        inputHeight: Int,
        tileSize: Int = defaultTileSize,
        overlap: Int = defaultOverlap,
        scaleFactor: Int
    ) -> [TileRegion] {
        let colCount = max(1, Int(ceil(Double(inputWidth)  / Double(tileSize))))
        let rowCount = max(1, Int(ceil(Double(inputHeight) / Double(tileSize))))
        var regions: [TileRegion] = []
        regions.reserveCapacity(colCount * rowCount)

        for row in 0..<rowCount {
            for col in 0..<colCount {
                let leftOverlap   = col > 0              ? overlap : 0
                let topOverlap    = row > 0              ? overlap : 0
                let rightOverlap  = col < colCount - 1   ? overlap : 0
                let bottomOverlap = row < rowCount - 1   ? overlap : 0

                let colStart  = col * tileSize
                let rowStart  = row * tileSize
                let colTileW  = min(tileSize, inputWidth  - colStart)
                let rowTileH  = min(tileSize, inputHeight - rowStart)

                regions.append(TileRegion(
                    inputRect: CGRect(
                        x: colStart - leftOverlap,
                        y: rowStart - topOverlap,
                        width:  leftOverlap + colTileW + rightOverlap,
                        height: topOverlap  + rowTileH + bottomOverlap
                    ),
                    upscaledInnerOrigin: CGPoint(
                        x: leftOverlap * scaleFactor,
                        y: topOverlap  * scaleFactor
                    ),
                    upscaledInnerSize: CGSize(
                        width:  colTileW * scaleFactor,
                        height: rowTileH * scaleFactor
                    ),
                    outputOrigin: CGPoint(
                        x: colStart * scaleFactor,
                        y: rowStart * scaleFactor
                    )
                ))
            }
        }
        return regions
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
xcodebuild test -scheme AIUpscalerTests -destination 'platform=macOS'
```

Expected: PASS — 4 tests passed.

- [ ] **Step 5: Commit**

```bash
git add AIUpscaler/AIUpscaler/Tiling/TileProcessor.swift \
        AIUpscaler/AIUpscalerTests/TileCalculatorTests.swift
git commit -m "feat: add TileProcessor tile geometry with full test coverage"
```

---

## Task 5: TileProcessor — Metal Execution

**Files:**
- Modify: `AIUpscaler/AIUpscaler/Tiling/TileProcessor.swift` (add `process` method)

This adds the Metal blit operations that extract tiles, call the engine, and stitch output. Tested indirectly via MPSUpscaler integration test in Task 6.

- [ ] **Step 1: Add `process` method to TileProcessor**

Append the following to `TileProcessor.swift` inside the class body, after `calculateTiles`:

```swift
    // MARK: - Metal execution

    func process(
        input: MTLTexture,
        scaleFactor: ScaleFactor,
        engine: UpscalerEngine,
        commandBuffer: MTLCommandBuffer
    ) throws -> MTLTexture {
        let scale = scaleFactor.rawValue
        let outDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: input.pixelFormat,
            width:  input.width  * scale,
            height: input.height * scale,
            mipmapped: false
        )
        outDesc.usage = [.shaderRead, .shaderWrite]
        guard let output = device.makeTexture(descriptor: outDesc) else {
            throw UpscalerError.metalDeviceUnavailable
        }

        let tiles = TileProcessor.calculateTiles(
            inputWidth:  input.width,
            inputHeight: input.height,
            scaleFactor: scale
        )

        for region in tiles {
            let tileDesc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: input.pixelFormat,
                width:  Int(region.inputRect.width),
                height: Int(region.inputRect.height),
                mipmapped: false
            )
            tileDesc.usage = [.shaderRead, .shaderWrite]
            guard let tileTexture = device.makeTexture(descriptor: tileDesc) else {
                throw UpscalerError.metalDeviceUnavailable
            }

            // 1. Blit input region → tile texture
            let blit1 = commandBuffer.makeBlitCommandEncoder()!
            blit1.copy(
                from: input,
                sourceSlice: 0, sourceLevel: 0,
                sourceOrigin: MTLOrigin(x: Int(region.inputRect.origin.x),
                                        y: Int(region.inputRect.origin.y), z: 0),
                sourceSize:   MTLSize(width:  Int(region.inputRect.width),
                                      height: Int(region.inputRect.height), depth: 1),
                to: tileTexture,
                destinationSlice: 0, destinationLevel: 0,
                destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
            )
            blit1.endEncoding()

            // 2. Upscale tile via engine
            let upscaled = try engine.upscale(input: tileTexture, commandBuffer: commandBuffer)

            // 3. Blit inner (non-overlap) region of upscaled tile → output
            let blit2 = commandBuffer.makeBlitCommandEncoder()!
            blit2.copy(
                from: upscaled,
                sourceSlice: 0, sourceLevel: 0,
                sourceOrigin: MTLOrigin(x: Int(region.upscaledInnerOrigin.x),
                                        y: Int(region.upscaledInnerOrigin.y), z: 0),
                sourceSize:   MTLSize(width:  Int(region.upscaledInnerSize.width),
                                      height: Int(region.upscaledInnerSize.height), depth: 1),
                to: output,
                destinationSlice: 0, destinationLevel: 0,
                destinationOrigin: MTLOrigin(x: Int(region.outputOrigin.x),
                                             y: Int(region.outputOrigin.y), z: 0)
            )
            blit2.endEncoding()
        }

        return output
    }
```

- [ ] **Step 2: Verify project builds**

```bash
xcodebuild -scheme AIUpscaler -configuration Debug build
```

Expected: `BUILD SUCCEEDED`

- [ ] **Step 3: Commit**

```bash
git add AIUpscaler/AIUpscaler/Tiling/TileProcessor.swift
git commit -m "feat: add TileProcessor Metal execution with blit-based tile stitching"
```

---

## Task 6: MPSUpscaler

**Files:**
- Create: `AIUpscaler/AIUpscaler/Engine/MPSUpscaler.swift`
- Create: `AIUpscaler/AIUpscalerTests/MPSUpscalerTests.swift`

- [ ] **Step 1: Write the failing test**

Create `AIUpscaler/AIUpscalerTests/MPSUpscalerTests.swift`:

```swift
import Testing
import Metal
import MetalPerformanceShaders
@testable import AIUpscaler

@Suite struct MPSUpscalerTests {

    var device: MTLDevice { MTLCreateSystemDefaultDevice()! }

    @Test func outputDimensionsAre2xInput() throws {
        let device = device
        let engine = MPSUpscaler(scaleFactor: .x2, device: device)

        let inputDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: 64, height: 48, mipmapped: false
        )
        inputDesc.usage = [.shaderRead, .shaderWrite]
        let input = try #require(device.makeTexture(descriptor: inputDesc))

        let queue = try #require(device.makeCommandQueue())
        let cb    = try #require(queue.makeCommandBuffer())
        let output = try engine.upscale(input: input, commandBuffer: cb)
        cb.commit()
        cb.waitUntilCompleted()

        #expect(output.width  == 128)
        #expect(output.height == 96)
    }

    @Test func outputDimensionsAre4xInput() throws {
        let device = device
        let engine = MPSUpscaler(scaleFactor: .x4, device: device)

        let inputDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: 32, height: 32, mipmapped: false
        )
        inputDesc.usage = [.shaderRead, .shaderWrite]
        let input = try #require(device.makeTexture(descriptor: inputDesc))

        let queue = try #require(device.makeCommandQueue())
        let cb    = try #require(queue.makeCommandBuffer())
        let output = try engine.upscale(input: input, commandBuffer: cb)
        cb.commit()
        cb.waitUntilCompleted()

        #expect(output.width  == 128)
        #expect(output.height == 128)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
xcodebuild test -scheme AIUpscalerTests -destination 'platform=macOS'
```

Expected: FAIL — `MPSUpscaler` not defined.

- [ ] **Step 3: Implement MPSUpscaler**

Create `AIUpscaler/AIUpscaler/Engine/MPSUpscaler.swift`:

```swift
import Metal
import MetalPerformanceShaders

final class MPSUpscaler: UpscalerEngine {

    let scaleFactor: ScaleFactor
    private let device: MTLDevice

    // 3×3 sharpening kernel (unsharp mask approximation)
    private static let sharpenWeights: [Float] = [
         0, -0.5,  0,
        -0.5, 3.0, -0.5,
         0, -0.5,  0,
    ]

    init(scaleFactor: ScaleFactor, device: MTLDevice) {
        self.scaleFactor = scaleFactor
        self.device = device
    }

    func warmup() async throws {
        // MPS filters have negligible init cost — nothing to pre-load
    }

    func upscale(input: MTLTexture, commandBuffer: MTLCommandBuffer) throws -> MTLTexture {
        let scale = Double(scaleFactor.rawValue)
        let outW = Int(Double(input.width)  * scale)
        let outH = Int(Double(input.height) * scale)

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: input.pixelFormat,
            width: outW, height: outH, mipmapped: false
        )
        desc.usage = [.shaderRead, .shaderWrite]

        guard let scaled   = device.makeTexture(descriptor: desc),
              let sharpened = device.makeTexture(descriptor: desc) else {
            throw UpscalerError.metalDeviceUnavailable
        }

        // 1. Lanczos scale
        let scaler = MPSImageLanczosScale(device: device)
        var transform = MPSScaleTransform(scaleX: scale, scaleY: scale, translateX: 0, translateY: 0)
        withUnsafePointer(to: &transform) { scaler.scaleTransform = $0 }
        scaler.encode(commandBuffer: commandBuffer, sourceTexture: input, destinationTexture: scaled)

        // 2. Sharpening via 3×3 convolution
        let sharpen = MPSImageConvolution(
            device: device,
            kernelWidth: 3, kernelHeight: 3,
            weights: MPSUpscaler.sharpenWeights
        )
        sharpen.encode(commandBuffer: commandBuffer, sourceTexture: scaled, destinationTexture: sharpened)

        return sharpened
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
xcodebuild test -scheme AIUpscalerTests -destination 'platform=macOS'
```

Expected: PASS — 2 tests passed (plus all previous tests).

- [ ] **Step 5: Commit**

```bash
git add AIUpscaler/AIUpscaler/Engine/MPSUpscaler.swift \
        AIUpscaler/AIUpscalerTests/MPSUpscalerTests.swift
git commit -m "feat: add MPSUpscaler with Lanczos + sharpening convolution"
```

---

## Task 7: RealESRGAN Model Conversion

**Files:**
- Create: `scripts/convert_realesrgan.py`
- Produces: `AIUpscaler/AIUpscaler/Resources/realesrgan_2x.mlpackage`
- Produces: `AIUpscaler/AIUpscaler/Resources/realesrgan_4x.mlpackage`

> This task runs once on a machine with Python 3.10+ and an internet connection. The output `.mlpackage` files are committed to the repo.

- [ ] **Step 1: Install Python dependencies**

```bash
pip install coremltools torch torchvision basicsr realesrgan
```

- [ ] **Step 2: Create conversion script**

Create `scripts/convert_realesrgan.py`:

```python
"""
Converts RealESRGAN x2plus and x4plus PyTorch weights to Core ML .mlpackage format.
Output: AIUpscaler/AIUpscaler/Resources/realesrgan_2x.mlpackage
        AIUpscaler/AIUpscaler/Resources/realesrgan_4x.mlpackage

Usage: python scripts/convert_realesrgan.py
"""
import os
import urllib.request
import torch
import coremltools as ct
from basicsr.archs.rrdbnet_arch import RRDBNet
from realesrgan import RealESRGANer

RESOURCES_DIR = "AIUpscaler/AIUpscaler/Resources"
MODELS = [
    {
        "name": "realesrgan_2x",
        "scale": 2,
        "url": "https://github.com/xinntao/Real-ESRGAN/releases/download/v0.2.1/RealESRGAN_x2plus.pth",
        "num_feat": 64,
        "num_block": 23,
    },
    {
        "name": "realesrgan_4x",
        "scale": 4,
        "url": "https://github.com/xinntao/Real-ESRGAN/releases/download/v0.1.0/RealESRGAN_x4plus.pth",
        "num_feat": 64,
        "num_block": 23,
    },
]

os.makedirs(RESOURCES_DIR, exist_ok=True)

for cfg in MODELS:
    weights_path = f"/tmp/{cfg['name']}.pth"
    if not os.path.exists(weights_path):
        print(f"Downloading {cfg['name']}...")
        urllib.request.urlretrieve(cfg["url"], weights_path)

    model = RRDBNet(
        num_in_ch=3, num_out_ch=3,
        num_feat=cfg["num_feat"], num_block=cfg["num_block"],
        scale=cfg["scale"]
    )
    upsampler = RealESRGANer(
        scale=cfg["scale"], model_path=weights_path,
        model=model, tile=0, half=False
    )
    model.eval()

    # Trace with a representative tile (512×512, 3-channel, float32)
    example_input = torch.zeros(1, 3, 512, 512)
    traced = torch.jit.trace(model, example_input)

    mlmodel = ct.convert(
        traced,
        inputs=[ct.TensorType(name="input", shape=(1, 3, 512, 512))],
        outputs=[ct.TensorType(name="output")],
        compute_precision=ct.precision.FLOAT16,
        minimum_deployment_target=ct.target.macOS13,
    )

    out_path = os.path.join(RESOURCES_DIR, f"{cfg['name']}.mlpackage")
    mlmodel.save(out_path)
    print(f"Saved {out_path}")

print("Done.")
```

- [ ] **Step 3: Run the conversion**

```bash
python scripts/convert_realesrgan.py
```

Expected: Two `.mlpackage` directories created under `AIUpscaler/AIUpscaler/Resources/`.

- [ ] **Step 4: Add model files to Xcode**

In Xcode, right-click the `AIUpscaler/Resources` group → Add Files → select both `.mlpackage` packages. Ensure they appear in the "Copy Bundle Resources" build phase.

- [ ] **Step 5: Commit**

```bash
git add scripts/convert_realesrgan.py \
        "AIUpscaler/AIUpscaler/Resources/realesrgan_2x.mlpackage" \
        "AIUpscaler/AIUpscaler/Resources/realesrgan_4x.mlpackage"
git commit -m "feat: add RealESRGAN conversion script and converted .mlpackage models"
```

---

## Task 8: CoreMLUpscaler

**Files:**
- Create: `AIUpscaler/AIUpscaler/Engine/CoreMLUpscaler.swift`
- Create: `AIUpscaler/AIUpscalerTests/CoreMLUpscalerTests.swift`

> Tests require the `.mlpackage` files from Task 7 to be present in the test bundle resources. In Xcode, add both `.mlpackage` files to the `AIUpscalerTests` target's "Copy Bundle Resources" build phase.

- [ ] **Step 1: Write the failing test**

Create `AIUpscaler/AIUpscalerTests/CoreMLUpscalerTests.swift`:

```swift
import Testing
import Metal
import CoreML
@testable import AIUpscaler

@Suite struct CoreMLUpscalerTests {

    var device: MTLDevice { MTLCreateSystemDefaultDevice()! }

    @Test func warmupLoads2xModelWithoutThrowing() async throws {
        let engine = CoreMLUpscaler(scaleFactor: .x2, device: device)
        try await engine.warmup()
        // warmup succeeded — model file found and loaded
    }

    @Test func warmupLoads4xModelWithoutThrowing() async throws {
        let engine = CoreMLUpscaler(scaleFactor: .x4, device: device)
        try await engine.warmup()
    }

    @Test func outputDimensionsAre2xInput() async throws {
        let device = device
        let engine = CoreMLUpscaler(scaleFactor: .x2, device: device)
        try await engine.warmup()

        let inputDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: 512, height: 512, mipmapped: false
        )
        inputDesc.usage = [.shaderRead, .shaderWrite]
        let input = try #require(device.makeTexture(descriptor: inputDesc))

        let queue = try #require(device.makeCommandQueue())
        let cb    = try #require(queue.makeCommandBuffer())
        let output = try engine.upscale(input: input, commandBuffer: cb)
        cb.commit()
        cb.waitUntilCompleted()

        #expect(output.width  == 1024)
        #expect(output.height == 1024)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
xcodebuild test -scheme AIUpscalerTests -destination 'platform=macOS'
```

Expected: FAIL — `CoreMLUpscaler` not defined.

- [ ] **Step 3: Implement CoreMLUpscaler**

Create `AIUpscaler/AIUpscaler/Engine/CoreMLUpscaler.swift`:

```swift
import Metal
import CoreML
import CoreVideo

final class CoreMLUpscaler: UpscalerEngine {

    let scaleFactor: ScaleFactor
    private let device: MTLDevice
    private var model: MLModel?

    init(scaleFactor: ScaleFactor, device: MTLDevice) {
        self.scaleFactor = scaleFactor
        self.device = device
    }

    func warmup() async throws {
        let name = scaleFactor == .x2 ? "realesrgan_2x" : "realesrgan_4x"
        guard let url = Bundle.main.url(forResource: name, withExtension: "mlpackage") else {
            throw UpscalerError.modelLoadFailed(
                underlying: NSError(domain: "CoreMLUpscaler", code: 1,
                                    userInfo: [NSLocalizedDescriptionKey: "\(name).mlpackage not found in bundle"])
            )
        }
        let config = MLModelConfiguration()
        config.computeUnits = .all
        do {
            model = try await MLModel.load(contentsOf: url, configuration: config)
        } catch {
            throw UpscalerError.modelLoadFailed(underlying: error)
        }
    }

    func upscale(input: MTLTexture, commandBuffer: MTLCommandBuffer) throws -> MTLTexture {
        guard let model else {
            throw UpscalerError.modelLoadFailed(
                underlying: NSError(domain: "CoreMLUpscaler", code: 2,
                                    userInfo: [NSLocalizedDescriptionKey: "warmup() not called"])
            )
        }

        // Convert MTLTexture → CVPixelBuffer for CoreML input
        let pixelBuffer = try makePixelBuffer(from: input)

        // Run inference
        let featureProvider = try MLDictionaryFeatureProvider(
            dictionary: ["input": MLFeatureValue(pixelBuffer: pixelBuffer)]
        )
        let result = try model.prediction(from: featureProvider)

        guard let outputBuffer = result.featureValue(for: "output")?.imageBufferValue else {
            throw UpscalerError.tileSizeMismatch(
                expected: CGSize(width: input.width * scaleFactor.rawValue,
                                 height: input.height * scaleFactor.rawValue),
                got: .zero
            )
        }

        // Convert CVPixelBuffer → MTLTexture for output
        return try makeTexture(from: outputBuffer, commandBuffer: commandBuffer)
    }

    // MARK: - Private helpers

    private func makePixelBuffer(from texture: MTLTexture) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        ]
        CVPixelBufferCreate(
            nil, texture.width, texture.height,
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary, &pixelBuffer
        )
        guard let pixelBuffer else { throw UpscalerError.metalDeviceUnavailable }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let baseAddr = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            throw UpscalerError.metalDeviceUnavailable
        }
        let region = MTLRegion(origin: .init(x: 0, y: 0, z: 0),
                               size: .init(width: texture.width, height: texture.height, depth: 1))
        texture.getBytes(baseAddr,
                         bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                         from: region, mipmapLevel: 0)
        return pixelBuffer
    }

    private func makeTexture(from pixelBuffer: CVPixelBuffer,
                             commandBuffer: MTLCommandBuffer) throws -> MTLTexture {
        let w = CVPixelBufferGetWidth(pixelBuffer)
        let h = CVPixelBufferGetHeight(pixelBuffer)
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false
        )
        desc.usage = [.shaderRead, .shaderWrite]
        guard let texture = device.makeTexture(descriptor: desc) else {
            throw UpscalerError.metalDeviceUnavailable
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let baseAddr = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            throw UpscalerError.metalDeviceUnavailable
        }
        let region = MTLRegion(origin: .init(x: 0, y: 0, z: 0),
                               size: .init(width: w, height: h, depth: 1))
        texture.replace(region: region, mipmapLevel: 0,
                        withBytes: baseAddr,
                        bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer))
        return texture
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
xcodebuild test -scheme AIUpscalerTests -destination 'platform=macOS'
```

Expected: PASS — 3 new tests passed.

- [ ] **Step 5: Commit**

```bash
git add AIUpscaler/AIUpscaler/Engine/CoreMLUpscaler.swift \
        AIUpscaler/AIUpscalerTests/CoreMLUpscalerTests.swift
git commit -m "feat: add CoreMLUpscaler with RealESRGAN inference and CVPixelBuffer bridge"
```

---

## Task 9: UpscalerEffect — FxPlug Integration

**Files:**
- Create: `AIUpscaler/AIUpscaler/Plugin/UpscalerEffect.swift`

> This class cannot be meaningfully unit-tested without the FCP host. Correctness is verified by the manual test in Task 11. Refer to FxPlug 4 SDK headers (`/Library/Frameworks/FxPlug.framework/Headers/`) for exact method signatures if the compiler flags any mismatch.

- [ ] **Step 1: Create UpscalerEffect.swift**

Create `AIUpscaler/AIUpscaler/Plugin/UpscalerEffect.swift`:

```swift
import Foundation
import FxPlug
import Metal

@objc(UpscalerEffect)
final class UpscalerEffect: NSObject, FxTileableEffect {

    // MARK: - Parameter IDs

    private enum ParamID: UInt32 {
        case scaleFactor  = 1
        case qualityMode  = 2
    }

    // MARK: - Engines (one per scale × quality combination)

    private var engines: [String: any UpscalerEngine] = [:]

    // MARK: - FxTileableEffect — parameter declaration

    func addParameters() throws {
        guard let api = plugInAPI?.parameterCreationAPI?() else { return }

        try api.addPopupMenu(
            withName: "Scale Factor",
            parmId: ParamID.scaleFactor.rawValue,
            defaultValue: 0,
            parameterFlags: FxParameterFlags(rawValue: 0),
            menuEntries: ["2×", "4×"]
        )

        try api.addPopupMenu(
            withName: "Quality Mode",
            parmId: ParamID.qualityMode.rawValue,
            defaultValue: 0,
            parameterFlags: FxParameterFlags(rawValue: 0),
            menuEntries: ["Fast (MPS)", "Best (Core ML)"]
        )
    }

    // MARK: - FxTileableEffect — output size

    func destinationImageSize(
        sourceImages: [FxImageTile],
        pluginState: Data?,
        atTime time: CMTime
    ) -> NSSize {
        guard let src = sourceImages.first else { return .zero }
        let factor = scaleFactorValue(atTime: time).rawValue
        return NSSize(
            width:  src.tileRect.width  * Double(factor),
            height: src.tileRect.height * Double(factor)
        )
    }

    // MARK: - FxTileableEffect — render

    func renderDestination(
        _ destination: FxDestination,
        sourceImages: [FxImageTile],
        destinationImage: FxImageTile,
        pluginState: Data?,
        atTime time: CMTime,
        error: AutoreleasingUnsafeMutablePointer<NSError?>?
    ) -> Bool {
        do {
            guard let sourceTexture = sourceImages.first?.texture,
                  let commandBuffer = destination.commandBuffer()
            else { return false }

            let scale   = scaleFactorValue(atTime: time)
            let quality = qualityModeValue(atTime: time)

            let engine = try resolvedEngine(scale: scale, quality: quality, commandBuffer: commandBuffer)

            guard let device = commandBuffer.device else {
                throw UpscalerError.metalDeviceUnavailable
            }

            let processor = TileProcessor(device: device)
            let result = try processor.process(
                input: sourceTexture,
                scaleFactor: scale,
                engine: engine,
                commandBuffer: commandBuffer
            )

            guard let destTexture = destinationImage.texture else { return false }

            let blit = commandBuffer.makeBlitCommandEncoder()!
            blit.copy(from: result, to: destTexture)
            blit.endEncoding()

            return true
        } catch let renderError {
            error?.pointee = renderError as NSError
            return false
        }
    }

    // MARK: - Private helpers

    private func scaleFactorValue(atTime time: CMTime) -> ScaleFactor {
        guard let api = plugInAPI?.parameterRetrievalAPI?() else { return .x2 }
        var index: Int = 0
        try? api.getIntValue(&index, fromParm: ParamID.scaleFactor.rawValue, at: time)
        return index == 0 ? .x2 : .x4
    }

    private func qualityModeValue(atTime time: CMTime) -> Int {
        guard let api = plugInAPI?.parameterRetrievalAPI?() else { return 0 }
        var index: Int = 0
        try? api.getIntValue(&index, fromParm: ParamID.qualityMode.rawValue, at: time)
        return index
    }

    private func resolvedEngine(
        scale: ScaleFactor,
        quality: Int,
        commandBuffer: MTLCommandBuffer
    ) throws -> any UpscalerEngine {
        let key = "\(quality)-\(scale.rawValue)"
        if let cached = engines[key] { return cached }

        guard let device = commandBuffer.device else {
            throw UpscalerError.metalDeviceUnavailable
        }

        let engine: any UpscalerEngine
        if quality == 0 {
            engine = MPSUpscaler(scaleFactor: scale, device: device)
        } else {
            let cml = CoreMLUpscaler(scaleFactor: scale, device: device)
            Task { try? await cml.warmup() }
            engine = cml
        }
        engines[key] = engine
        return engine
    }
}
```

- [ ] **Step 2: Verify project builds**

```bash
xcodebuild -scheme AIUpscaler -configuration Debug build
```

Expected: `BUILD SUCCEEDED`

- [ ] **Step 3: Commit**

```bash
git add AIUpscaler/AIUpscaler/Plugin/UpscalerEffect.swift
git commit -m "feat: add UpscalerEffect FxTileableEffect implementation"
```

---

## Task 10: Info.plist and Bundle Configuration

**Files:**
- Modify: `AIUpscaler/AIUpscaler/Info.plist`

- [ ] **Step 1: Set required FxPlug keys in Info.plist**

Open `AIUpscaler/AIUpscaler/Info.plist` in Xcode (source editor, not property list editor). Replace contents with:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>$(EXECUTABLE_NAME)</string>
    <key>CFBundleIdentifier</key>
    <string>$(PRODUCT_BUNDLE_IDENTIFIER)</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>AI Upscaler</string>
    <key>CFBundlePackageType</key>
    <string>BNDL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>NSPrincipalClass</key>
    <string>UpscalerEffect</string>

    <!-- FxPlug 4 required keys -->
    <key>FXPlugInAttributes</key>
    <dict>
        <key>FXPlugInAPIVersion</key>
        <string>4.0</string>
        <key>FXCategory</key>
        <string>Stylize</string>
        <key>FXSubcategory</key>
        <string>Stylize</string>
        <key>FXName</key>
        <string>AI Upscaler</string>
        <key>FXPlugInUsage</key>
        <string>FxTileableEffect</string>
    </dict>
</dict>
</plist>
```

- [ ] **Step 2: Build and verify bundle structure**

```bash
xcodebuild -scheme AIUpscaler -configuration Debug build
find ~/Library/Developer/Xcode/DerivedData -name "AIUpscaler.fxplug" -type d 2>/dev/null | head -1
```

Expected: Finds the `.fxplug` bundle in DerivedData.

- [ ] **Step 3: Commit**

```bash
git add AIUpscaler/AIUpscaler/Info.plist
git commit -m "feat: configure Info.plist with FxPlug 4 required keys"
```

---

## Task 11: Integration Test and Manual Verification

**Files:**
- Create: `AIUpscaler/AIUpscalerTests/PipelineIntegrationTests.swift`

- [ ] **Step 1: Write the integration test**

Create `AIUpscaler/AIUpscalerTests/PipelineIntegrationTests.swift`:

```swift
import Testing
import Metal
@testable import AIUpscaler

@Suite struct PipelineIntegrationTests {

    var device: MTLDevice { MTLCreateSystemDefaultDevice()! }

    // Full pipeline: 1920×1080 frame → MPSUpscaler 2x → verify 3840×2160 output
    @Test func fullPipelineMPS2x() throws {
        let device = device
        let engine = MPSUpscaler(scaleFactor: .x2, device: device)
        let processor = TileProcessor(device: device)

        let inputDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: 1920, height: 1080, mipmapped: false
        )
        inputDesc.usage = [.shaderRead, .shaderWrite]
        let input = try #require(device.makeTexture(descriptor: inputDesc))

        let queue = try #require(device.makeCommandQueue())
        let cb    = try #require(queue.makeCommandBuffer())
        let output = try processor.process(
            input: input, scaleFactor: .x2, engine: engine, commandBuffer: cb
        )
        cb.commit()
        cb.waitUntilCompleted()

        #expect(output.width  == 3840)
        #expect(output.height == 2160)
    }

    // Full pipeline: 3840×2160 frame → MPSUpscaler 4x → verify 15360×8640 output
    @Test func fullPipelineMPS4x() throws {
        let device = device
        let engine = MPSUpscaler(scaleFactor: .x4, device: device)
        let processor = TileProcessor(device: device)

        let inputDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: 960, height: 540, mipmapped: false
        )
        inputDesc.usage = [.shaderRead, .shaderWrite]
        let input = try #require(device.makeTexture(descriptor: inputDesc))

        let queue = try #require(device.makeCommandQueue())
        let cb    = try #require(queue.makeCommandBuffer())
        let output = try processor.process(
            input: input, scaleFactor: .x4, engine: engine, commandBuffer: cb
        )
        cb.commit()
        cb.waitUntilCompleted()

        #expect(output.width  == 3840)
        #expect(output.height == 2160)
    }
}
```

- [ ] **Step 2: Run all tests**

```bash
xcodebuild test -scheme AIUpscalerTests -destination 'platform=macOS'
```

Expected: All tests pass, including the 2 new integration tests.

- [ ] **Step 3: Install plugin for manual verification**

```bash
xcodebuild -scheme AIUpscaler -configuration Debug build
BUILT_PLUGIN=$(find ~/Library/Developer/Xcode/DerivedData -name "AIUpscaler.fxplug" -type d 2>/dev/null | head -1)
mkdir -p ~/Library/Plug-Ins/FxPlug
cp -R "$BUILT_PLUGIN" ~/Library/Plug-Ins/FxPlug/
```

- [ ] **Step 4: Manual verification checklist**

Open Final Cut Pro. If already open, quit and reopen (FCP loads plugins at launch).

1. Create a new project with a 1080p timeline
2. Import any test clip
3. In the Effects Browser, search "AI Upscaler" — it should appear
4. Apply the effect to the clip
5. Verify the effect panel shows "Scale Factor" (2×/4×) and "Quality Mode" (Fast/Best)
6. Set Quality Mode = Fast, play the timeline — preview should show upscaled output without FCP crashing
7. Set Quality Mode = Best — first frame may take ~1s to load the CoreML model
8. Export a 10-second segment: File → Share → Master File. Verify the output file resolves at the upscaled resolution.

- [ ] **Step 5: Final commit**

```bash
git add AIUpscaler/AIUpscalerTests/PipelineIntegrationTests.swift
git commit -m "feat: add pipeline integration tests; plugin ready for manual FCP verification"
```

---

## Spec Coverage Checklist

| Spec Section | Covered By |
|---|---|
| Dual-engine architecture | Tasks 3, 6, 8 |
| FxTileableEffect / FxPlug integration | Task 9 |
| Bundle structure + Info.plist | Tasks 1, 10 |
| Scale Factor 2×/4× parameter | Task 9 |
| Quality Mode Fast/Best parameter | Task 9 |
| TileProcessor 512×512 tiles, 16px overlap | Tasks 4, 5 |
| MPSUpscaler (Lanczos + sharpen) | Task 6 |
| CoreMLUpscaler (RealESRGAN) | Tasks 7, 8 |
| UpscalerError + passthrough on failure | Task 2 |
| Unit tests (TileProcessor, MPSUpscaler, CoreMLUpscaler) | Tasks 4, 6, 8 |
| Integration test 1080p → 2x → 3840×2160 | Task 11 |
| Manual preview + export verification | Task 11 |
