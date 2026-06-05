import Testing
import CoreGraphics
@testable import AIUpscaler

@Suite struct TileCalculatorTests {

    // Single tile: image smaller than tileSize on both axes
    @Test func singleTileForSmallImage() {
        let tiles = TileProcessor.calculateTiles(
            inputWidth: 400, inputHeight: 300,
            tileSize: 512, overlap: 16, scaleFactor: 2
        )
        #expect(tiles.count == 1)
        let t = tiles[0]
        #expect(t.inputRect == CGRect(x: 0, y: 0, width: 400, height: 300))
        #expect(t.upscaledInnerOrigin == .zero)
        #expect(t.upscaledInnerSize == CGSize(width: 800, height: 600))
        #expect(t.outputOrigin == .zero)
    }

    // 1920x1080 → 4 cols × 3 rows = 12 tiles at 2x
    @Test func tileCountFor1080pAt2x() {
        let tiles = TileProcessor.calculateTiles(
            inputWidth: 1920, inputHeight: 1080,
            tileSize: 512, overlap: 16, scaleFactor: 2
        )
        #expect(tiles.count == 12) // ceil(1920/512)=4, ceil(1080/512)=3
    }

    // Interior tile (col=1, row=1) has overlap on all four sides
    @Test func interiorTileHasOverlapOnAllSides() {
        let tiles = TileProcessor.calculateTiles(
            inputWidth: 1920, inputHeight: 1080,
            tileSize: 512, overlap: 16, scaleFactor: 2
        )
        // tile at index col=1, row=1 → index = row*4 + col = 5
        let t = tiles[5]
        // inputRect starts 16px before the tile origin
        #expect(t.inputRect.origin.x == CGFloat(512 - 16))
        #expect(t.inputRect.origin.y == CGFloat(512 - 16))
        // inner origin in upscaled tile = 16*2 = 32 on both axes
        #expect(t.upscaledInnerOrigin == CGPoint(x: 32, y: 32))
        // inner size = 512 * 2 = 1024 on both axes
        #expect(t.upscaledInnerSize == CGSize(width: 1024, height: 1024))
        // output placed at col*tileSize*scale, row*tileSize*scale
        #expect(t.outputOrigin == CGPoint(x: 1 * 512 * 2, y: 1 * 512 * 2))
    }

    // Reconstructed output dimensions equal input × scaleFactor
    @Test func reconstructedSizeIsCorrect() {
        let w = 1920, h = 1080, scale = 2
        let tiles = TileProcessor.calculateTiles(
            inputWidth: w, inputHeight: h,
            tileSize: 512, overlap: 16, scaleFactor: scale
        )
        let maxX = tiles.map { $0.outputOrigin.x + $0.upscaledInnerSize.width }.max()!
        let maxY = tiles.map { $0.outputOrigin.y + $0.upscaledInnerSize.height }.max()!
        #expect(Int(maxX) == w * scale)
        #expect(Int(maxY) == h * scale)
    }
}
