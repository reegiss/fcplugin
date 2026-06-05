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

        guard let scaled    = device.makeTexture(descriptor: desc),
              let sharpened = device.makeTexture(descriptor: desc) else {
            throw UpscalerError.metalDeviceUnavailable
        }

        // 1. Lanczos scale
        let scaler = MPSImageLanczosScale(device: device)
        var transform = MPSScaleTransform(scaleX: scale, scaleY: scale, translateX: 0, translateY: 0)
        withUnsafePointer(to: &transform) { scaler.scaleTransform = $0.pointee }
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
