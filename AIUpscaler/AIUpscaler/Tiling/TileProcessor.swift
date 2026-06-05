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
}
