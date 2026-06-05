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

        let pixelBuffer = try makePixelBuffer(from: input)

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
