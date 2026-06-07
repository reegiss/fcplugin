import Metal
import CoreML
import Accelerate
import MetalPerformanceShaders

final class CoreMLUpscaler: UpscalerEngine {

    let scaleFactor: ScaleFactor
    private let device: MTLDevice
    private let computeUnits: MLComputeUnits
    private var model: MLModel?

    private var pipelineBgraToFloat: MTLComputePipelineState?
    private var pipelineFloatToBgra: MTLComputePipelineState?
    private lazy var internalQueue: MTLCommandQueue = device.makeCommandQueue()!

    // Fixed input dimensions expected by the compiled RealESRGAN CoreML models.
    private static let modelTileSize = 512

    // Must match struct ConvertParams in TileUpscaler.metal
    private struct ConvertParams {
        var width: UInt32
        var height: UInt32
    }

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
        model = try await MLModel.load(contentsOf: url, configuration: config)

        if let library = loadMetalLibrary() {
            pipelineBgraToFloat = try? library.makeFunction(name: "bgra_to_planar_f16")
                .flatMap { try? device.makeComputePipelineState(function: $0) }
            pipelineFloatToBgra = try? library.makeFunction(name: "planar_f16_to_bgra")
                .flatMap { try? device.makeComputePipelineState(function: $0) }
        }
    }

    // MARK: - UpscalerEngine

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

        if let bgraToFloat = pipelineBgraToFloat, let floatToBgra = pipelineFloatToBgra {
            return try upscaleGPU(model: model, input: input,
                                  w: w, h: h, outW: outW, outH: outH,
                                  bgraToFloat: bgraToFloat, floatToBgra: floatToBgra)
        } else {
            return try upscaleCPU(model: model, input: input, w: w, h: h, outW: outW, outH: outH)
        }
    }

    // Batch path: one Metal encode pass for all inputs, N CoreML predictions, one Metal encode pass for all outputs.
    // Reduces GPU commit/wait from N×2 to 2 regardless of tile count.
    // Tiles that are not exactly modelTileSize×modelTileSize are resized to fit the fixed CoreML input shape,
    // then the output is resized back to the expected (inputW*scale × inputH*scale) dimensions.
    func upscaleBatch(inputs: [MTLTexture], commandBuffer: MTLCommandBuffer) throws -> [MTLTexture] {
        guard let model else {
            throw UpscalerError.modelLoadFailed(
                underlying: NSError(domain: "CoreMLUpscaler", code: 2,
                                    userInfo: [NSLocalizedDescriptionKey: "warmup() not called"])
            )
        }
        guard let bgraToFloat = pipelineBgraToFloat,
              let floatToBgra = pipelineFloatToBgra else {
            // Pipeline unavailable: fall back to sequential single upscale
            return try inputs.map { try upscale(input: $0, commandBuffer: commandBuffer) }
        }

        let n = inputs.count
        let scale = scaleFactor.rawValue
        let tileSize = CoreMLUpscaler.modelTileSize
        let modelOutSize = tileSize * scale

        // Resize any tiles that don't match the model's fixed 512×512 input shape.
        // Edge tiles and overlap-padded tiles commonly differ from 512×512.
        let resizedInputs: [MTLTexture] = try inputs.map { tex in
            if tex.width == tileSize && tex.height == tileSize { return tex }
            return try mpsResize(tex, toWidth: tileSize, height: tileSize)
        }

        // Record original output sizes for final resize step.
        let targetOutSizes: [(Int, Int)] = inputs.map { tex in
            (tex.width * scale, tex.height * scale)
        }

        // Pre-allocate all shared input / output MTLBuffers at model dimensions.
        let inputBuffers  = try (0..<n).map { _ in try makeSharedBuffer(size: 3 * tileSize    * tileSize    * 2) }
        let outputBuffers = try (0..<n).map { _ in try makeSharedBuffer(size: 3 * modelOutSize * modelOutSize * 2) }

        // Single Metal CB: BGRA→float16 for all (resized) tiles
        try batchConvert(
            inputs: zip(resizedInputs, inputBuffers).map { ($0.0, tileSize, tileSize, $0.1) },
            pipeline: bgraToFloat, textureIsInput: true)

        // Wrap each buffer as MLMultiArray (zero-copy — buffer backing not copied)
        let inputArrays  = try inputBuffers.map  { try wrapAsMLMultiArray($0, width: tileSize,     height: tileSize) }
        let outputArrays = try outputBuffers.map { try wrapAsMLMultiArray($0, width: modelOutSize, height: modelOutSize) }

        // Sequential CoreML predictions with pre-allocated output backings (ANE writes to our buffers)
        for i in 0..<n {
            let features = try MLDictionaryFeatureProvider(
                dictionary: ["input": MLFeatureValue(multiArray: inputArrays[i])]
            )
            let opts = MLPredictionOptions()
            opts.outputBackings = ["output": outputArrays[i]]
            _ = try model.prediction(from: features, options: opts)
        }

        // Single Metal CB: float16→BGRA for all tiles (at model output dimensions)
        let modelOutTextures = try (0..<n).map { _ in try makeTexture(width: modelOutSize, height: modelOutSize) }
        let decodePairs = (0..<n).map { i in
            (modelOutTextures[i], modelOutSize, modelOutSize, outputBuffers[i])
        }
        try batchConvert(inputs: decodePairs, pipeline: floatToBgra, textureIsInput: false)

        // Resize each output to the expected (inputW*scale × inputH*scale) dimensions if needed.
        return try (0..<n).map { i in
            let (tw, th) = targetOutSizes[i]
            if tw == modelOutSize && th == modelOutSize { return modelOutTextures[i] }
            return try mpsResize(modelOutTextures[i], toWidth: tw, height: th)
        }
    }

    // MARK: - Private helpers

    private func loadMetalLibrary() -> MTLLibrary? {
        if let lib = device.makeDefaultLibrary() { return lib }
        guard let url = Bundle(for: CoreMLUpscaler.self).url(forResource: "default",
                                                              withExtension: "metallib"),
              let lib = try? device.makeLibrary(URL: url) else { return nil }
        return lib
    }

    private func makeSharedBuffer(size: Int) throws -> MTLBuffer {
        guard let buf = device.makeBuffer(length: size, options: .storageModeShared) else {
            throw UpscalerError.metalDeviceUnavailable
        }
        return buf
    }

    private func makeTexture(width: Int, height: Int) throws -> MTLTexture {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        desc.usage = [.shaderRead, .shaderWrite]
        desc.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: desc) else {
            throw UpscalerError.metalDeviceUnavailable
        }
        return tex
    }

    // Wraps a shared MTLBuffer as an MLMultiArray [1, 3, H, W] float16 with no copy.
    // Caller must keep `buffer` alive for the duration of any CoreML call using this array.
    private func wrapAsMLMultiArray(_ buffer: MTLBuffer, width: Int, height: Int) throws -> MLMultiArray {
        let strides: [NSNumber] = [
            NSNumber(value: 3 * height * width),
            NSNumber(value: height * width),
            NSNumber(value: width),
            NSNumber(value: 1),
        ]
        return try MLMultiArray(
            dataPointer: buffer.contents(),
            shape: [1, 3, NSNumber(value: height), NSNumber(value: width)],
            dataType: .float16,
            strides: strides,
            deallocator: nil
        )
    }

    // Encodes a conversion kernel for multiple (texture, buffer, size) pairs into one CB and waits.
    private func batchConvert(inputs: [(MTLTexture, Int, Int, MTLBuffer)],
                              pipeline: MTLComputePipelineState,
                              textureIsInput: Bool) throws {
        guard let cb = internalQueue.makeCommandBuffer(),
              let enc = cb.makeComputeCommandEncoder() else {
            throw UpscalerError.metalDeviceUnavailable
        }
        enc.setComputePipelineState(pipeline)

        let tgW = pipeline.threadExecutionWidth
        let tgH = pipeline.maxTotalThreadsPerThreadgroup / tgW

        for (texture, width, height, buffer) in inputs {
            var params = ConvertParams(width: UInt32(width), height: UInt32(height))
            if textureIsInput {
                enc.setTexture(texture, index: 0)
                enc.setBuffer(buffer, offset: 0, index: 0)
            } else {
                enc.setBuffer(buffer, offset: 0, index: 0)
                enc.setTexture(texture, index: 0)
            }
            enc.setBytes(&params, length: MemoryLayout<ConvertParams>.size, index: 1)

            let gridSize = MTLSize(width: (width + tgW - 1) / tgW,
                                   height: (height + tgH - 1) / tgH, depth: 1)
            enc.dispatchThreadgroups(gridSize,
                                     threadsPerThreadgroup: MTLSize(width: tgW, height: tgH, depth: 1))
        }
        enc.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
    }

    // MARK: - Single-tile GPU path

    private func upscaleGPU(model: MLModel, input: MTLTexture,
                             w: Int, h: Int, outW: Int, outH: Int,
                             bgraToFloat: MTLComputePipelineState,
                             floatToBgra: MTLComputePipelineState) throws -> MTLTexture {
        let tileSize = CoreMLUpscaler.modelTileSize
        let modelOutSize = tileSize * scaleFactor.rawValue

        // If the tile dimensions differ from the model's fixed 512×512 input, use MPS to resize.
        // Tiles with overlap can be up to tileSize+2*overlap pixels; edge tiles may be smaller.
        let modelInput: MTLTexture
        if w == tileSize && h == tileSize {
            modelInput = input
        } else {
            // Scale input to exactly 512×512 using Lanczos (best quality for downscale).
            modelInput = try mpsResize(input, toWidth: tileSize, height: tileSize)
        }

        let inputBuffer  = try makeSharedBuffer(size: 3 * tileSize * tileSize * 2)
        let outputBuffer = try makeSharedBuffer(size: 3 * modelOutSize * modelOutSize * 2)

        try batchConvert(inputs: [(modelInput, tileSize, tileSize, inputBuffer)],
                         pipeline: bgraToFloat, textureIsInput: true)

        let inputArray  = try wrapAsMLMultiArray(inputBuffer,  width: tileSize,    height: tileSize)
        let outputArray = try wrapAsMLMultiArray(outputBuffer, width: modelOutSize, height: modelOutSize)

        let features = try MLDictionaryFeatureProvider(
            dictionary: ["input": MLFeatureValue(multiArray: inputArray)]
        )
        let opts = MLPredictionOptions()
        opts.outputBackings = ["output": outputArray]
        _ = try model.prediction(from: features, options: opts)

        // Decode the 1024×1024 CoreML output to a texture.
        let modelOutTex = try makeTexture(width: modelOutSize, height: modelOutSize)
        try batchConvert(inputs: [(modelOutTex, modelOutSize, modelOutSize, outputBuffer)],
                         pipeline: floatToBgra, textureIsInput: false)

        // If the caller requested different output dimensions (because input was resized),
        // scale the CoreML output back to outW × outH using MPS.
        if outW == modelOutSize && outH == modelOutSize {
            return modelOutTex
        } else {
            return try mpsResize(modelOutTex, toWidth: outW, height: outH)
        }
    }

    // Synchronous MPS Lanczos resize using the engine's internal command queue.
    private func mpsResize(_ input: MTLTexture, toWidth w: Int, height h: Int) throws -> MTLTexture {
        let outTex = try makeTexture(width: w, height: h)
        guard let cb = internalQueue.makeCommandBuffer() else {
            throw UpscalerError.metalDeviceUnavailable
        }
        let scaler = MPSImageLanczosScale(device: device)
        let scaleX = Double(w) / Double(input.width)
        let scaleY = Double(h) / Double(input.height)
        var transform = MPSScaleTransform(scaleX: scaleX, scaleY: scaleY, translateX: 0, translateY: 0)
        withUnsafePointer(to: &transform) { scaler.scaleTransform = $0 }
        scaler.encode(commandBuffer: cb, sourceTexture: input, destinationTexture: outTex)
        cb.commit()
        cb.waitUntilCompleted()
        return outTex
    }

    // MARK: - CPU fallback (used when Metal shaders unavailable)

    private func upscaleCPU(model: MLModel, input: MTLTexture,
                             w: Int, h: Int, outW: Int, outH: Int) throws -> MTLTexture {
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

    // Legacy CPU conversion kept as fallback only.
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
                                     dataType: .float16)
        let cStride = array.strides[1].intValue
        let hStride = array.strides[2].intValue
        let wStride = array.strides[3].intValue

        // Build float32 buffer then convert to float16 via pointer cast
        var f32 = [Float](repeating: 0, count: array.count)
        for y in 0..<height {
            for x in 0..<width {
                let src = y * bytesPerRow + x * bytesPerPixel
                let idx = y * hStride + x * wStride
                f32[0 * cStride + idx] = Float(bgra[src + 2]) / 255.0
                f32[1 * cStride + idx] = Float(bgra[src + 1]) / 255.0
                f32[2 * cStride + idx] = Float(bgra[src + 0]) / 255.0
            }
        }
        let count = array.count
        f32.withUnsafeMutableBufferPointer { src in
            var vSrc = vImage_Buffer(data: src.baseAddress!, height: 1,
                                     width: UInt(count), rowBytes: count * 4)
            var vDst = vImage_Buffer(data: array.dataPointer, height: 1,
                                     width: UInt(count), rowBytes: count * 2)
            vImageConvert_PlanarFtoPlanar16F(&vSrc, &vDst, 0)
        }
        return array
    }

    private func multiArrayToTexture(array: MLMultiArray, width: Int, height: Int) throws -> MTLTexture {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        desc.usage = [.shaderRead, .shaderWrite]
        desc.storageMode = .shared
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
            var vSrc = vImage_Buffer(data: array.dataPointer, height: 1,
                                     width: UInt(count), rowBytes: count * 2)
            f32.withUnsafeMutableBufferPointer { dst in
                var vDst = vImage_Buffer(data: dst.baseAddress!, height: 1,
                                         width: UInt(count), rowBytes: count * 4)
                vImageConvert_Planar16FtoPlanarF(&vSrc, &vDst, 0)
            }
            for y in 0..<height {
                for x in 0..<width {
                    let dstIdx = y * bytesPerRow + x * 4
                    let idx = y * hStride + x * wStride
                    bgra[dstIdx + 2] = UInt8(min(1.0, max(0.0, f32[0 * cStride + idx])) * 255)
                    bgra[dstIdx + 1] = UInt8(min(1.0, max(0.0, f32[1 * cStride + idx])) * 255)
                    bgra[dstIdx + 0] = UInt8(min(1.0, max(0.0, f32[2 * cStride + idx])) * 255)
                }
            }
        } else {
            let ptr = array.dataPointer.bindMemory(to: Float.self, capacity: array.count)
            for y in 0..<height {
                for x in 0..<width {
                    let dstIdx = y * bytesPerRow + x * 4
                    let idx = y * hStride + x * wStride
                    bgra[dstIdx + 2] = UInt8(min(1.0, max(0.0, ptr[0 * cStride + idx])) * 255)
                    bgra[dstIdx + 1] = UInt8(min(1.0, max(0.0, ptr[1 * cStride + idx])) * 255)
                    bgra[dstIdx + 0] = UInt8(min(1.0, max(0.0, ptr[2 * cStride + idx])) * 255)
                }
            }
        }

        texture.replace(region: MTLRegion(origin: .init(x: 0, y: 0, z: 0),
                                          size: .init(width: width, height: height, depth: 1)),
                        mipmapLevel: 0, withBytes: bgra, bytesPerRow: bytesPerRow)
        return texture
    }
}
