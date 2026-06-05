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
