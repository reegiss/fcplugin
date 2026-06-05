import Metal
import CoreGraphics

final class TileProcessor {

    static let defaultTileSize = 512
    static let defaultOverlap  = 16

    private let device: MTLDevice

    init(device: MTLDevice) {
        self.device = device
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

                let colStart  = col * tileSize
                let rowStart  = row * tileSize
                let colTileW  = min(tileSize, inputWidth  - colStart)
                let rowTileH  = min(tileSize, inputHeight - rowStart)

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
                    )
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
        let outDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: input.pixelFormat,
            width:  input.width  * scale,
            height: input.height * scale,
            mipmapped: false
        )
        outDesc.usage = [.shaderRead, .shaderWrite]
        guard let output = device.makeTexture(descriptor: outDesc) else {
            throw UpscalerError.metalDeviceUnavailable
        }

        let tiles = TileProcessor.calculateTiles(
            inputWidth:  input.width,
            inputHeight: input.height,
            scaleFactor: scale
        )

        for region in tiles {
            let tileDesc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: input.pixelFormat,
                width:  Int(region.inputRect.width),
                height: Int(region.inputRect.height),
                mipmapped: false
            )
            tileDesc.usage = [.shaderRead, .shaderWrite]
            guard let tileTexture = device.makeTexture(descriptor: tileDesc) else {
                throw UpscalerError.metalDeviceUnavailable
            }

            // 1. Blit input region → tile texture
            let blit1 = commandBuffer.makeBlitCommandEncoder()!
            blit1.copy(
                from: input,
                sourceSlice: 0, sourceLevel: 0,
                sourceOrigin: MTLOrigin(x: Int(region.inputRect.origin.x),
                                        y: Int(region.inputRect.origin.y), z: 0),
                sourceSize:   MTLSize(width:  Int(region.inputRect.width),
                                      height: Int(region.inputRect.height), depth: 1),
                to: tileTexture,
                destinationSlice: 0, destinationLevel: 0,
                destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
            )
            blit1.endEncoding()

            // 2. Upscale tile via engine
            let upscaled = try engine.upscale(input: tileTexture, commandBuffer: commandBuffer)

            // 3. Blit inner (non-overlap) region of upscaled tile → output
            let blit2 = commandBuffer.makeBlitCommandEncoder()!
            blit2.copy(
                from: upscaled,
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
            blit2.endEncoding()
        }

        return output
    }
}
