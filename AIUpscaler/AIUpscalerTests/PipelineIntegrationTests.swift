import Testing
import Metal
@testable import AIUpscaler

@Suite struct PipelineIntegrationTests {

    var device: MTLDevice { MTLCreateSystemDefaultDevice()! }

    // Full pipeline: 1920×1080 input → MPSUpscaler 2x → verify 3840×2160 output
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

    // Full pipeline: 960×540 input → MPSUpscaler 4x → verify 3840×2160 output
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
