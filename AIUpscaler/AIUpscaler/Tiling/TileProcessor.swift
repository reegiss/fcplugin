import Metal
import CoreGraphics

final class TileProcessor {

    static let defaultTileSize = 512
    static let defaultOverlap  = 16

    private let device: MTLDevice
    private lazy var internalQueue: MTLCommandQueue = device.makeCommandQueue()!

    private var pipelineAccumulate: MTLComputePipelineState?
    private var pipelineNormalize:  MTLComputePipelineState?

    // Must match struct AccumParams in TileUpscaler.metal (field-by-field layout).
    // Metal uint2 = 2 × UInt32; we use two UInt32 fields to guarantee identical memory layout.
    private struct AccumParams {
        var outputOriginX:      UInt32
        var outputOriginY:      UInt32
        var innerOriginInTileX: UInt32
        var innerOriginInTileY: UInt32
        var innerSizeW:         UInt32
        var innerSizeH:         UInt32
        var leftOverlap:        UInt32
        var rightOverlap:       UInt32
        var topOverlap:         UInt32
        var bottomOverlap:      UInt32
    }

    init(device: MTLDevice) {
        self.device = device
        loadPipelines()
    }

    // MARK: - Pure tile geometry (no Metal — fully testable)

    static func calculateTiles(
        inputWidth: Int,
        inputHeight: Int,
        tileSize: Int = defaultTileSize,
        overlap: Int = defaultOverlap,
        scaleFactor: Int
    ) -> [TileRegion] {
        let colCount = max(1, Int(ceil(Double(inputWidth)  / Double(tileSize))))
        let rowCount = max(1, Int(ceil(Double(inputHeight) / Double(tileSize))))
        var regions: [TileRegion] = []
        regions.reserveCapacity(colCount * rowCount)

        for row in 0..<rowCount {
            for col in 0..<colCount {
                let leftOverlap   = col > 0              ? overlap : 0
                let topOverlap    = row > 0              ? overlap : 0
                let rightOverlap  = col < colCount - 1   ? overlap : 0
                let bottomOverlap = row < rowCount - 1   ? overlap : 0

                let colStart = col * tileSize
                let rowStart = row * tileSize
                let colTileW = min(tileSize, inputWidth  - colStart)
                let rowTileH = min(tileSize, inputHeight - rowStart)

                regions.append(TileRegion(
                    inputRect: CGRect(
                        x: colStart - leftOverlap,
                        y: rowStart - topOverlap,
                        width:  leftOverlap + colTileW + rightOverlap,
                        height: topOverlap  + rowTileH + bottomOverlap
                    ),
                    upscaledInnerOrigin: CGPoint(
                        x: leftOverlap * scaleFactor,
                        y: topOverlap  * scaleFactor
                    ),
                    upscaledInnerSize: CGSize(
                        width:  colTileW * scaleFactor,
                        height: rowTileH * scaleFactor
                    ),
                    outputOrigin: CGPoint(
                        x: colStart * scaleFactor,
                        y: rowStart * scaleFactor
                    ),
                    leftOverlap:   leftOverlap,
                    rightOverlap:  rightOverlap,
                    topOverlap:    topOverlap,
                    bottomOverlap: bottomOverlap
                ))
            }
        }
        return regions
    }

    // MARK: - Metal execution

    func process(
        input: MTLTexture,
        scaleFactor: ScaleFactor,
        engine: any UpscalerEngine,
        commandBuffer: MTLCommandBuffer
    ) throws -> MTLTexture {
        let scale = scaleFactor.rawValue
        let outW = input.width  * scale
        let outH = input.height * scale

        let tiles = TileProcessor.calculateTiles(
            inputWidth:  input.width,
            inputHeight: input.height,
            scaleFactor: scale
        )

        // Phase A: Extract all tiles in ONE command buffer (one GPU round-trip total).
        let tileTextures = try extractAllTiles(from: input, regions: tiles)

        // Phase B: Upscale all tiles using a dedicated internal CB so the caller's commandBuffer
        // is never committed here. CoreML ignores the CB and uses its own; MPS encodes into it.
        guard let upscaleCB = internalQueue.makeCommandBuffer() else {
            throw UpscalerError.metalDeviceUnavailable
        }
        let upscaledTiles = try engine.upscaleBatch(inputs: tileTextures, commandBuffer: upscaleCB)
        upscaleCB.commit()
        upscaleCB.waitUntilCompleted()

        // Phase C: GPU blend reconstruction with feathered seams.
        return try gpuReconstruct(
            upscaledTiles: upscaledTiles,
            regions: tiles,
            scaleFactor: scale,
            outputWidth: outW,
            outputHeight: outH,
            pixelFormat: input.pixelFormat
        )
    }

    // MARK: - Private

    private func loadPipelines() {
        guard let library = loadMetalLibrary() else { return }
        pipelineAccumulate = (try? library.makeFunction(name: "tile_accumulate"))
            .flatMap { try? device.makeComputePipelineState(function: $0) }
        pipelineNormalize  = (try? library.makeFunction(name: "tile_normalize"))
            .flatMap { try? device.makeComputePipelineState(function: $0) }
    }

    private func loadMetalLibrary() -> MTLLibrary? {
        if let lib = device.makeDefaultLibrary() { return lib }
        guard let url = Bundle(for: TileProcessor.self).url(forResource: "default",
                                                             withExtension: "metallib"),
              let lib = try? device.makeLibrary(URL: url) else { return nil }
        return lib
    }

    // Extracts every tile region from the input texture into its own .shared texture.
    // All blit copies are encoded into ONE command buffer — one GPU commit+wait total.
    private func extractAllTiles(from input: MTLTexture, regions: [TileRegion]) throws -> [MTLTexture] {
        guard let cb   = internalQueue.makeCommandBuffer(),
              let blit = cb.makeBlitCommandEncoder() else {
            throw UpscalerError.metalDeviceUnavailable
        }

        let tileTextures: [MTLTexture] = try regions.map { region in
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: input.pixelFormat,
                width:  Int(region.inputRect.width),
                height: Int(region.inputRect.height),
                mipmapped: false
            )
            desc.usage = [.shaderRead, .shaderWrite]
            desc.storageMode = .shared
            guard let tex = device.makeTexture(descriptor: desc) else {
                throw UpscalerError.metalDeviceUnavailable
            }
            let srcX = max(0, Int(region.inputRect.origin.x))
            let srcY = max(0, Int(region.inputRect.origin.y))
            blit.copy(
                from: input,
                sourceSlice: 0, sourceLevel: 0,
                sourceOrigin: MTLOrigin(x: srcX, y: srcY, z: 0),
                sourceSize:   MTLSize(width:  Int(region.inputRect.width),
                                      height: Int(region.inputRect.height), depth: 1),
                to: tex,
                destinationSlice: 0, destinationLevel: 0,
                destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
            )
            return tex
        }

        blit.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        return tileTextures
    }

    // Reconstructs the full upscaled image from per-tile upscaled textures using GPU blend kernels.
    // Falls back to hard-blit stitching when the blend pipelines are unavailable.
    private func gpuReconstruct(
        upscaledTiles: [MTLTexture],
        regions: [TileRegion],
        scaleFactor: Int,
        outputWidth: Int,
        outputHeight: Int,
        pixelFormat: MTLPixelFormat
    ) throws -> MTLTexture {

        let outDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat, width: outputWidth, height: outputHeight, mipmapped: false)
        outDesc.usage = [.shaderRead, .shaderWrite]
        outDesc.storageMode = .shared
        guard let finalOutput = device.makeTexture(descriptor: outDesc) else {
            throw UpscalerError.metalDeviceUnavailable
        }

        guard let accumPipeline = pipelineAccumulate,
              let normPipeline  = pipelineNormalize else {
            try blitStitch(upscaledTiles: upscaledTiles, regions: regions, into: finalOutput)
            return finalOutput
        }

        // Accum textures in .private storage (GPU-only, no CPU bandwidth cost).
        let accumColorDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba32Float, width: outputWidth, height: outputHeight, mipmapped: false)
        accumColorDesc.usage  = [.shaderRead, .shaderWrite, .renderTarget]
        accumColorDesc.storageMode = .private

        let accumWeightDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r32Float, width: outputWidth, height: outputHeight, mipmapped: false)
        accumWeightDesc.usage  = [.shaderRead, .shaderWrite, .renderTarget]
        accumWeightDesc.storageMode = .private

        guard let accumColor  = device.makeTexture(descriptor: accumColorDesc),
              let accumWeight = device.makeTexture(descriptor: accumWeightDesc) else {
            throw UpscalerError.metalDeviceUnavailable
        }

        guard let cb = internalQueue.makeCommandBuffer() else {
            throw UpscalerError.metalDeviceUnavailable
        }

        // Clear accum textures to zero via empty render passes (reliable on all Apple Silicon GPUs).
        clearTexture(accumColor, clearColor: MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0), in: cb)
        clearTexture(accumWeight, clearColor: MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0), in: cb)

        // Accumulate each tile sequentially. Separate compute encoders guarantee ordering:
        // Metal executes encoders in the order they were created within a command buffer.
        for (tile, region) in zip(upscaledTiles, regions) {
            let leftOvl  = UInt32(region.leftOverlap   * scaleFactor)
            let rightOvl = UInt32(region.rightOverlap  * scaleFactor)
            let topOvl   = UInt32(region.topOverlap    * scaleFactor)
            let botOvl   = UInt32(region.bottomOverlap * scaleFactor)

            var params = AccumParams(
                outputOriginX:      UInt32(region.outputOrigin.x),
                outputOriginY:      UInt32(region.outputOrigin.y),
                innerOriginInTileX: UInt32(region.upscaledInnerOrigin.x),
                innerOriginInTileY: UInt32(region.upscaledInnerOrigin.y),
                innerSizeW:         UInt32(region.upscaledInnerSize.width),
                innerSizeH:         UInt32(region.upscaledInnerSize.height),
                leftOverlap:   leftOvl,
                rightOverlap:  rightOvl,
                topOverlap:    topOvl,
                bottomOverlap: botOvl
            )

            let writeW = Int(params.innerSizeW) + Int(leftOvl + rightOvl)
            let writeH = Int(params.innerSizeH) + Int(topOvl  + botOvl)

            guard let enc = cb.makeComputeCommandEncoder() else {
                throw UpscalerError.metalDeviceUnavailable
            }
            enc.setComputePipelineState(accumPipeline)
            enc.setTexture(tile,        index: 0)
            enc.setTexture(accumColor,  index: 1)
            enc.setTexture(accumWeight, index: 2)
            enc.setBytes(&params, length: MemoryLayout<AccumParams>.size, index: 0)

            let tgW = accumPipeline.threadExecutionWidth
            let tgH = accumPipeline.maxTotalThreadsPerThreadgroup / tgW
            enc.dispatchThreadgroups(
                MTLSize(width: max(1, (writeW + tgW - 1) / tgW),
                        height: max(1, (writeH + tgH - 1) / tgH), depth: 1),
                threadsPerThreadgroup: MTLSize(width: tgW, height: tgH, depth: 1)
            )
            enc.endEncoding()
        }

        // Normalize: accumColor / accumWeight → finalOutput
        guard let normEnc = cb.makeComputeCommandEncoder() else {
            throw UpscalerError.metalDeviceUnavailable
        }
        normEnc.setComputePipelineState(normPipeline)
        normEnc.setTexture(accumColor,  index: 0)
        normEnc.setTexture(accumWeight, index: 1)
        normEnc.setTexture(finalOutput, index: 2)

        let tgW2 = normPipeline.threadExecutionWidth
        let tgH2 = normPipeline.maxTotalThreadsPerThreadgroup / tgW2
        normEnc.dispatchThreadgroups(
            MTLSize(width:  max(1, (outputWidth  + tgW2 - 1) / tgW2),
                    height: max(1, (outputHeight + tgH2 - 1) / tgH2), depth: 1),
            threadsPerThreadgroup: MTLSize(width: tgW2, height: tgH2, depth: 1)
        )
        normEnc.endEncoding()

        cb.commit()
        cb.waitUntilCompleted()
        return finalOutput
    }

    // Clears a texture to a solid color via an empty render pass (GPU-side, works for private textures).
    private func clearTexture(_ texture: MTLTexture, clearColor: MTLClearColor,
                              in commandBuffer: MTLCommandBuffer) {
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture     = texture
        rp.colorAttachments[0].loadAction  = .clear
        rp.colorAttachments[0].clearColor  = clearColor
        rp.colorAttachments[0].storeAction = .store
        commandBuffer.makeRenderCommandEncoder(descriptor: rp)?.endEncoding()
    }

    // Hard-blit fallback (original behavior): copies only the inner (non-overlap) region per tile.
    private func blitStitch(upscaledTiles: [MTLTexture], regions: [TileRegion],
                             into output: MTLTexture) throws {
        guard let cb   = internalQueue.makeCommandBuffer(),
              let blit = cb.makeBlitCommandEncoder() else {
            throw UpscalerError.metalDeviceUnavailable
        }
        for (tile, region) in zip(upscaledTiles, regions) {
            blit.copy(
                from: tile,
                sourceSlice: 0, sourceLevel: 0,
                sourceOrigin: MTLOrigin(x: Int(region.upscaledInnerOrigin.x),
                                        y: Int(region.upscaledInnerOrigin.y), z: 0),
                sourceSize:   MTLSize(width:  Int(region.upscaledInnerSize.width),
                                      height: Int(region.upscaledInnerSize.height), depth: 1),
                to: output,
                destinationSlice: 0, destinationLevel: 0,
                destinationOrigin: MTLOrigin(x: Int(region.outputOrigin.x),
                                             y: Int(region.outputOrigin.y), z: 0)
            )
        }
        blit.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
    }
}
