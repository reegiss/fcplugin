import Foundation
import Metal
import CoreML
import MetalPerformanceShaders
import CoreGraphics
import Darwin

// MARK: - Timing

func measureMs(_ block: () -> Void) -> Double {
    var start = timespec()
    var end   = timespec()
    clock_gettime(CLOCK_MONOTONIC, &start)
    block()
    clock_gettime(CLOCK_MONOTONIC, &end)
    let sec  = Int(end.tv_sec  - start.tv_sec)
    let nsec = Int(end.tv_nsec - start.tv_nsec)
    return Double(sec * 1_000_000_000 + nsec) / 1_000_000
}

// MARK: - Async warmup on sync caller (same pattern as AIUpscalerPlugIn)

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

// MARK: - Synthetic texture

func makeNoiseTexture(device: MTLDevice, width: Int, height: Int) -> MTLTexture {
    let desc = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
    desc.usage = [.shaderRead, .shaderWrite]
    desc.storageMode = .shared
    guard let tex = device.makeTexture(descriptor: desc) else {
        fputs("Fatal: cannot allocate \(width)×\(height) texture\n", stderr); exit(1)
    }
    let bytesPerRow = width * 4
    var noise = [UInt8](repeating: 0, count: height * bytesPerRow)
    for i in noise.indices { noise[i] = UInt8.random(in: 0...255) }
    tex.replace(
        region: MTLRegion(origin: MTLOrigin(x: 0, y: 0, z: 0),
                          size:   MTLSize(width: width, height: height, depth: 1)),
        mipmapLevel: 0, withBytes: &noise, bytesPerRow: bytesPerRow)
    return tex
}

// MARK: - Table formatting

func col(_ s: String, width: Int, right: Bool = false) -> String {
    let pad = max(0, width - s.count)
    return right ? String(repeating: " ", count: pad) + s
                 : s + String(repeating: " ", count: pad)
}

// MARK: - Scenarios

struct Scenario {
    let label: String
    let width: Int
    let height: Int
    let scale: ScaleFactor
}

let scenarios: [Scenario] = [
    Scenario(label: "480p",  width: 854,  height: 480,  scale: .x2),
    Scenario(label: "480p",  width: 854,  height: 480,  scale: .x4),
    Scenario(label: "540p",  width: 960,  height: 540,  scale: .x2),
    Scenario(label: "540p",  width: 960,  height: 540,  scale: .x4),
    Scenario(label: "720p",  width: 1280, height: 720,  scale: .x2),
    Scenario(label: "720p",  width: 1280, height: 720,  scale: .x4),
    Scenario(label: "1080p", width: 1920, height: 1080, scale: .x2),
    Scenario(label: "1080p", width: 1920, height: 1080, scale: .x4),
    Scenario(label: "4K",    width: 3840, height: 2160, scale: .x2),
    Scenario(label: "4K",    width: 3840, height: 2160, scale: .x4),
]

let iterationCount = 5

// MARK: - Device setup

guard let device = MTLCreateSystemDefaultDevice() else {
    fputs("Error: no Metal device available\n", stderr); exit(1)
}
guard let commandQueue = device.makeCommandQueue() else {
    fputs("Error: cannot create command queue\n", stderr); exit(1)
}

print("=== AIUpscaler Benchmark ===")
print("Device: \(device.name) | Iterations: \(iterationCount)")
print("")

// MARK: - Engine warmup (once, before any scenarios)

print("Warming up engines...")

let coreml2x = CoreMLUpscaler(scaleFactor: .x2, device: device, computeUnits: .all)
let coreml4x = CoreMLUpscaler(scaleFactor: .x4, device: device, computeUnits: .all)
let mps2x    = MPSUpscaler(scaleFactor: .x2, device: device)
let mps4x    = MPSUpscaler(scaleFactor: .x4, device: device)

do {
    try warmupSync(coreml2x)
    try warmupSync(coreml4x)
    try warmupSync(mps2x)
    try warmupSync(mps4x)
} catch {
    fputs("Error during warmup: \(error)\n", stderr); exit(1)
}

let processor = TileProcessor(device: device)
print("Warmup complete.\n")

// MARK: - Results

struct Result {
    let label: String
    let scale: Int
    let coremlAvg: Double
    let coremlMin: Double
    let mpsAvg: Double
    let mpsMin: Double
}

var results: [Result] = []

for scenario in scenarios {
    let scaleLabel = "\(scenario.scale.rawValue)×"
    print("  \(scenario.label) \(scaleLabel)...", terminator: " ")
    fflush(stdout)

    let inputTex = makeNoiseTexture(device: device, width: scenario.width, height: scenario.height)
    let coreml = scenario.scale == .x2 ? coreml2x : coreml4x
    let mps    = scenario.scale == .x2 ? mps2x    : mps4x

    func runIterations(engine: any UpscalerEngine) -> [Double] {
        var times: [Double] = []
        // Warmup iteration (discarded)
        let wcb = commandQueue.makeCommandBuffer()!
        _ = try? processor.process(input: inputTex, scaleFactor: scenario.scale,
                                   engine: engine, commandBuffer: wcb)
        wcb.commit(); wcb.waitUntilCompleted()
        // Timed iterations
        for _ in 0..<iterationCount {
            let ms = measureMs {
                let cb = commandQueue.makeCommandBuffer()!
                _ = try? processor.process(input: inputTex, scaleFactor: scenario.scale,
                                           engine: engine, commandBuffer: cb)
                cb.commit(); cb.waitUntilCompleted()
            }
            times.append(ms)
        }
        return times
    }

    let coremlTimes = runIterations(engine: coreml)
    let mpsTimes    = runIterations(engine: mps)

    let coremlAvg = coremlTimes.reduce(0, +) / Double(coremlTimes.count)
    let mpsAvg    = mpsTimes.reduce(0, +)    / Double(mpsTimes.count)

    results.append(Result(
        label: scenario.label,
        scale: scenario.scale.rawValue,
        coremlAvg: coremlAvg,
        coremlMin: coremlTimes.min()!,
        mpsAvg:    mpsAvg,
        mpsMin:    mpsTimes.min()!
    ))
    print("done")
}

// MARK: - Table

let divider = String(repeating: "─", count: 76)
print("")
print(
    col("Resolution", width: 12) +
    col("Scale", width: 7, right: true) +
    col("CoreML avg", width: 12, right: true) +
    col("CoreML min", width: 12, right: true) +
    col("MPS avg", width: 10, right: true) +
    col("MPS min", width: 10, right: true) +
    col("ratio", width: 8, right: true)
)
print(divider)
for r in results {
    let ratio = r.coremlAvg / r.mpsAvg
    print(
        col(r.label, width: 12) +
        col("\(r.scale)×", width: 7, right: true) +
        col(String(format: "%.0fms", r.coremlAvg), width: 12, right: true) +
        col(String(format: "%.0fms", r.coremlMin), width: 12, right: true) +
        col(String(format: "%.0fms", r.mpsAvg),    width: 10, right: true) +
        col(String(format: "%.0fms", r.mpsMin),    width: 10, right: true) +
        col(String(format: "%.1f×",  ratio),        width: 8,  right: true)
    )
}
print(divider)
print("ratio = CoreML avg / MPS avg  (>1 = CoreML slower: trades speed for AI quality)")
