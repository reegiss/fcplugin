import Metal
import CoreML
import Accelerate

final class CoreMLUpscaler: UpscalerEngine {

    let scaleFactor: ScaleFactor
    private let device: MTLDevice
    private let computeUnits: MLComputeUnits
    private var model: MLModel?

    init(scaleFactor: ScaleFactor, device: MTLDevice, computeUnits: MLComputeUnits = .all) {
        self.scaleFactor = scaleFactor
        self.device = device
        self.computeUnits = computeUnits
    }

    func warmup() async throws {
        let name = scaleFactor == .x2 ? "realesrgan_2x" : "realesrgan_4x"
        guard let url = Bundle(for: CoreMLUpscaler.self).url(forResource: name, withExtension: "mlmodelc") else {
            throw UpscalerError.modelLoadFailed(
                underlying: NSError(domain: "CoreMLUpscaler", code: 1,
                                    userInfo: [NSLocalizedDescriptionKey: "\(name).mlmodelc not found in bundle"])
            )
        }
        let config = MLModelConfiguration()
        config.computeUnits = computeUnits
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

        let w = input.width, h = input.height
        let scale = scaleFactor.rawValue
        let outW = w * scale, outH = h * scale

        // Read texture → Float32 RGB MLMultiArray (1, 3, H, W) normalized [0, 1]
        let inputArray = try textureToMultiArray(texture: input, width: w, height: h)
        let featureProvider = try MLDictionaryFeatureProvider(
            dictionary: ["input": MLFeatureValue(multiArray: inputArray)]
        )

        let result = try model.prediction(from: featureProvider)

        guard let outputArray = result.featureValue(for: "output")?.multiArrayValue else {
            throw UpscalerError.tileSizeMismatch(
                expected: CGSize(width: outW, height: outH), got: .zero
            )
        }

        return try multiArrayToTexture(array: outputArray, width: outW, height: outH)
    }

    // MARK: - Private

    private func textureToMultiArray(texture: MTLTexture, width: Int, height: Int) throws -> MLMultiArray {
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var bgra = [UInt8](repeating: 0, count: height * bytesPerRow)
        texture.getBytes(&bgra,
                         bytesPerRow: bytesPerRow,
                         from: MTLRegion(origin: .init(x: 0, y: 0, z: 0),
                                         size: .init(width: width, height: height, depth: 1)),
                         mipmapLevel: 0)

        let array = try MLMultiArray(shape: [1, 3, NSNumber(value: height), NSNumber(value: width)],
                                     dataType: .float32)
        let ptr = array.dataPointer.bindMemory(to: Float32.self, capacity: array.count)
        
        let cStride = array.strides[1].intValue
        let hStride = array.strides[2].intValue
        let wStride = array.strides[3].intValue
        
        for y in 0..<height {
            for x in 0..<width {
                let src = y * bytesPerRow + x * bytesPerPixel
                let idx = y * hStride + x * wStride
                ptr[0 * cStride + idx] = Float32(bgra[src + 2]) / 255.0  // R
                ptr[1 * cStride + idx] = Float32(bgra[src + 1]) / 255.0  // G
                ptr[2 * cStride + idx] = Float32(bgra[src + 0]) / 255.0  // B
            }
        }
        return array
    }

    private func multiArrayToTexture(array: MLMultiArray, width: Int, height: Int) throws -> MTLTexture {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false
        )
        desc.usage = [.shaderRead, .shaderWrite]
        #if targetEnvironment(macCatalyst) || os(macOS)
        desc.storageMode = .shared
        #endif
        guard let texture = device.makeTexture(descriptor: desc) else {
            throw UpscalerError.metalDeviceUnavailable
        }

        let bytesPerRow = width * 4
        var bgra = [UInt8](repeating: 255, count: height * bytesPerRow)
        
        let cStride = array.strides[1].intValue
        let hStride = array.strides[2].intValue
        let wStride = array.strides[3].intValue

        if array.dataType == .float16 {
            let count = array.count
            var f32 = [Float](repeating: 0, count: count)
            var src = vImage_Buffer(data: array.dataPointer, height: 1, width: UInt(count), rowBytes: count * 2)
            var dst = vImage_Buffer(data: &f32, height: 1, width: UInt(count), rowBytes: count * 4)
            vImageConvert_Planar16FtoPlanarF(&src, &dst, 0)

            for y in 0..<height {
                for x in 0..<width {
                    let dstIdx = y * bytesPerRow + x * 4
                    let idx = y * hStride + x * wStride
                    bgra[dstIdx + 2] = UInt8(min(1.0, max(0.0, f32[0 * cStride + idx])) * 255)
                    bgra[dstIdx + 1] = UInt8(min(1.0, max(0.0, f32[1 * cStride + idx])) * 255)
                    bgra[dstIdx + 0] = UInt8(min(1.0, max(0.0, f32[2 * cStride + idx])) * 255)
                }
            }
        } else if array.dataType == .float32 {
            let ptr = array.dataPointer.bindMemory(to: Float32.self, capacity: array.count)
            for y in 0..<height {
                for x in 0..<width {
                    let dstIdx = y * bytesPerRow + x * 4
                    let idx = y * hStride + x * wStride
                    bgra[dstIdx + 2] = UInt8(min(1.0, max(0.0, ptr[0 * cStride + idx])) * 255)
                    bgra[dstIdx + 1] = UInt8(min(1.0, max(0.0, ptr[1 * cStride + idx])) * 255)
                    bgra[dstIdx + 0] = UInt8(min(1.0, max(0.0, ptr[2 * cStride + idx])) * 255)
                }
            }
        } else {
            throw UpscalerError.modelLoadFailed(
                underlying: NSError(domain: "CoreMLUpscaler", code: 3, userInfo: [NSLocalizedDescriptionKey: "Unsupported output data type"])
            )
        }

        texture.replace(region: MTLRegion(origin: .init(x: 0, y: 0, z: 0),
                                          size: .init(width: width, height: height, depth: 1)),
                        mipmapLevel: 0, withBytes: bgra, bytesPerRow: bytesPerRow)
        return texture
    }
}
