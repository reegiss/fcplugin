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