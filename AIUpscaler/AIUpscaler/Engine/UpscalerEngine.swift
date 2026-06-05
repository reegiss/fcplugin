import Metal
import CoreGraphics

enum ScaleFactor: Int, CaseIterable {
    case x2 = 2
    case x4 = 4
}

/// Describes one tile to extract from the input, upscale, and place into the output.
struct TileRegion {
    /// Region to extract from the input texture (includes overlap padding).
    let inputRect: CGRect
    /// Offset within the upscaled tile where non-overlap content starts.
    let upscaledInnerOrigin: CGPoint
    /// Size of the non-overlap content in the upscaled tile.
    let upscaledInnerSize: CGSize
    /// Top-left corner in the output texture where this tile's content is placed.
    let outputOrigin: CGPoint
}

protocol UpscalerEngine: AnyObject {
    var scaleFactor: ScaleFactor { get }
    /// Upscales `input` and encodes GPU work into `commandBuffer`.
    /// Returns a new MTLTexture with dimensions `input.width * scaleFactor x input.height * scaleFactor`.
    func upscale(input: MTLTexture, commandBuffer: MTLCommandBuffer) throws -> MTLTexture
    /// Pre-loads model weights / MPS filters so first-frame latency is minimal.
    func warmup() async throws
}
