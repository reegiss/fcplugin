import Testing
import Metal
import CoreML
@testable import AIUpscaler

@Suite struct CoreMLUpscalerTests {

    var device: MTLDevice { MTLCreateSystemDefaultDevice()! }

    @Test func warmupLoads2xModelWithoutThrowing() async throws {
        let engine = CoreMLUpscaler(scaleFactor: .x2, device: device, computeUnits: .cpuAndGPU)
        try await engine.warmup()
    }

    @Test func warmupLoads4xModelWithoutThrowing() async throws {
        let engine = CoreMLUpscaler(scaleFactor: .x4, device: device, computeUnits: .cpuAndGPU)
        try await engine.warmup()
    }

    @Test func outputDimensionsAre2xInput() async throws {
        let device = device
        // Use .cpuAndGPU to avoid ANE initialization issues in the test process sandbox
        let engine = CoreMLUpscaler(scaleFactor: .x2, device: device, computeUnits: .cpuAndGPU)
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
