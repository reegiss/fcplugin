import Foundation
import Metal
import CoreML
import MetalPerformanceShaders
import CoreGraphics
import ImageIO
import Darwin

// MARK: - Image I/O

func loadPNG(path: String, device: MTLDevice) -> MTLTexture? {
    guard let url = URL(string: "file://\(path)"),
          let src = CGImageSourceCreateWithURL(url as CFURL, nil),
          let cgImage = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
        fputs("Error: cannot load \(path)\n", stderr); return nil
    }

    let width  = cgImage.width
    let height = cgImage.height

    let desc = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
    desc.usage = [.shaderRead, .shaderWrite]
    desc.storageMode = .shared
    guard let tex = device.makeTexture(descriptor: desc) else { return nil }

    // Render CGImage into BGRA pixel buffer then upload to texture.
    let bytesPerRow = width * 4
    var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)
    pixels.withUnsafeMutableBytes { ptr in
        guard let ctx = CGContext(
            data: ptr.baseAddress,
            width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue |
                        CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else { return }
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
    }
    tex.replace(region: MTLRegion(origin: MTLOrigin(x: 0, y: 0, z: 0),
                                  size:   MTLSize(width: width, height: height, depth: 1)),
                mipmapLevel: 0, withBytes: &pixels, bytesPerRow: bytesPerRow)
    return tex
}

func savePNG(texture: MTLTexture, path: String) {
    let width  = texture.width
    let height = texture.height
    let bytesPerRow = width * 4
    var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)
    texture.getBytes(&pixels, bytesPerRow: bytesPerRow,
                     from: MTLRegion(origin: MTLOrigin(x: 0, y: 0, z: 0),
                                     size:   MTLSize(width: width, height: height, depth: 1)),
                     mipmapLevel: 0)

    guard let ctx = CGContext(
        data: &pixels,
        width: width, height: height,
        bitsPerComponent: 8, bytesPerRow: bytesPerRow,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue |
                    CGImageAlphaInfo.premultipliedFirst.rawValue
    ), let cgImage = ctx.makeImage() else {
        fputs("Error: cannot create CGContext for save\n", stderr); return
    }

    let url = URL(fileURLWithPath: path)
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
        fputs("Error: cannot create image destination at \(path)\n", stderr); return
    }
    CGImageDestinationAddImage(dest, cgImage, nil)
    if !CGImageDestinationFinalize(dest) {
        fputs("Error: failed to write \(path)\n", stderr)
    }
}

// MARK: - Warmup helper

func warmupSync(_ engine: any UpscalerEngine) throws {
    var warmupError: Error?
    let sema = DispatchSemaphore(value: 0)
    Task.detached {
        do    { try await engine.warmup() }
        catch { warmupError = error }
        sema.signal()
    }
    sema.wait()
    if let e = warmupError { throw e }
}

// MARK: - Main

let args = CommandLine.arguments
guard args.count == 3 else {
    fputs("Usage: visualtest <input.png> <output_dir>\n", stderr); exit(1)
}
let inputPath  = args[1]
let outputDir  = args[2]

guard let device = MTLCreateSystemDefaultDevice() else {
    fputs("Error: no Metal device\n", stderr); exit(1)
}
guard let commandQueue = device.makeCommandQueue() else {
    fputs("Error: cannot create command queue\n", stderr); exit(1)
}

print("Device: \(device.name)")
print("Loading: \(inputPath)")

guard let sourceTex = loadPNG(path: inputPath, device: device) else {
    fputs("Error: failed to load input image\n", stderr); exit(1)
}
print("Source: \(sourceTex.width)×\(sourceTex.height)")

let scale = ScaleFactor.x4
print("Scale: \(scale.rawValue)×")
print("")

// Warm up engines
print("Warming up AI engine (CoreML)...")
let coreml = CoreMLUpscaler(scaleFactor: scale, device: device, computeUnits: .all)
do {
    try warmupSync(coreml)
    print("AI engine ready.")
} catch {
    fputs("CoreML warmup failed: \(error)\nAI result will not be generated.\n", stderr)
}

print("Warming up Fast engine (MPS)...")
let mps = MPSUpscaler(scaleFactor: scale, device: device)
try warmupSync(mps)
print("Fast engine ready.\n")

let processor = TileProcessor(device: device)

// Run AI upscale
var aiResult: MTLTexture?
print("Running AI upscale...")
let aiStart = Date()
do {
    let cb = commandQueue.makeCommandBuffer()!
    aiResult = try processor.process(input: sourceTex, scaleFactor: scale, engine: coreml, commandBuffer: cb)
    cb.commit(); cb.waitUntilCompleted()
    let ms = Int(Date().timeIntervalSince(aiStart) * 1000)
    print("AI done in \(ms)ms → \(aiResult!.width)×\(aiResult!.height)")
} catch {
    fputs("AI failed: \(error)\n", stderr)
}

// Run MPS upscale
print("Running Fast (Lanczos) upscale...")
let mpsStart = Date()
let cbMPS = commandQueue.makeCommandBuffer()!
let mpsResult = try processor.process(input: sourceTex, scaleFactor: scale, engine: mps, commandBuffer: cbMPS)
cbMPS.commit(); cbMPS.waitUntilCompleted()
let mpsMs = Int(Date().timeIntervalSince(mpsStart) * 1000)
print("Fast done in \(mpsMs)ms → \(mpsResult.width)×\(mpsResult.height)")

// Save results
print("\nSaving results to \(outputDir)...")

// Save original upscaled with sips-quality (nearest neighbour equivalent — raw pixels)
let aiPath  = "\(outputDir)/result_ai_4x.png"
let mpsPath = "\(outputDir)/result_fast_4x.png"

if let ai = aiResult {
    savePNG(texture: ai,        path: aiPath)
    print("  AI  → \(aiPath)")
}
savePNG(texture: mpsResult, path: mpsPath)
print("  MPS → \(mpsPath)")
print("\nDone. Open the PNGs in Preview to compare.")
