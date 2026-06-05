import Foundation
import Metal

@objc(AIUpscalerPlugIn)
final class UpscalerEffect: NSObject, FxTileableEffect {

    private let apiManager: PROAPIAccessing

    private enum ParamID: UInt32 {
        case scaleFactor = 1
        case qualityMode = 2
    }

    private struct StateData {
        var scaleFactor: Int32  // 0 = 2x, 1 = 4x
        var qualityMode: Int32  // 0 = Fast/MPS, 1 = Best/CoreML
    }

    private var engines: [String: any UpscalerEngine] = [:]

    required init?(apiManager: PROAPIAccessing) {
        self.apiManager = apiManager
        super.init()
    }

    // MARK: - FxTileableEffect — lifecycle

    func addParameters() throws {
        let api = apiManager.api(for: FxParameterCreationAPI_v5.self) as! FxParameterCreationAPI_v5
        api.addPopupMenu(withName: "Scale Factor",
                         parameterID: ParamID.scaleFactor.rawValue,
                         defaultValue: 0,
                         menuEntries: ["2×", "4×"],
                         parameterFlags: FxParameterFlags(kFxParameterFlag_DEFAULT))
        api.addPopupMenu(withName: "Quality Mode",
                         parameterID: ParamID.qualityMode.rawValue,
                         defaultValue: 0,
                         menuEntries: ["Fast (MPS)", "Best (Core ML)"],
                         parameterFlags: FxParameterFlags(kFxParameterFlag_DEFAULT))
    }

    func properties(_ properties: AutoreleasingUnsafeMutablePointer<NSDictionary>?) throws {
        properties?.pointee = [
            kFxPropertyKey_NeedsFullBuffer:           NSNumber(booleanLiteral: true),
            kFxPropertyKey_MayRemapTime:              NSNumber(booleanLiteral: false),
            kFxPropertyKey_ChangesOutputSize:         NSNumber(booleanLiteral: true),
            kFxPropertyKey_VariesWhenParamsAreStatic: NSNumber(booleanLiteral: false),
        ] as NSDictionary
    }

    // MARK: - FxTileableEffect — parameter gathering (called before render)

    func pluginState(_ pluginState: AutoreleasingUnsafeMutablePointer<NSData>?,
                     at renderTime: CMTime,
                     quality _: UInt) throws {
        let api = apiManager.api(for: FxParameterRetrievalAPI_v6.self) as! FxParameterRetrievalAPI_v6
        var scaleIdx: Int32 = 0
        var qualityIdx: Int32 = 0
        api.getIntValue(&scaleIdx,   fromParameter: ParamID.scaleFactor.rawValue, at: renderTime)
        api.getIntValue(&qualityIdx, fromParameter: ParamID.qualityMode.rawValue, at: renderTime)
        var state = StateData(scaleFactor: scaleIdx, qualityMode: qualityIdx)
        pluginState?.pointee = NSData(bytes: &state, length: MemoryLayout.size(ofValue: state))
    }

    // MARK: - FxTileableEffect — geometry

    func destinationImageRect(_ destinationImageRect: UnsafeMutablePointer<FxRect>,
                               sourceImages: [FxImageTile],
                               destinationImage _: FxImageTile,
                               pluginState: Data?,
                               at _: CMTime) throws {
        let src = sourceImages[0].imagePixelBounds
        let scale = Int32(decodeState(pluginState)?.scaleFactor == 0 ? 2 : 4)
        destinationImageRect.pointee = FxRect(left:   src.left   * scale,
                                              bottom: src.bottom * scale,
                                              right:  src.right  * scale,
                                              top:    src.top    * scale)
    }

    func sourceTileRect(_ sourceTileRect: UnsafeMutablePointer<FxRect>,
                        sourceImageIndex: UInt,
                        sourceImages: [FxImageTile],
                        destinationTileRect _: FxRect,
                        destinationImage _: FxImageTile,
                        pluginState _: Data?,
                        at _: CMTime) throws {
        sourceTileRect.pointee = sourceImages[Int(sourceImageIndex)].imagePixelBounds
    }

    // MARK: - FxTileableEffect — render

    func renderDestinationImage(_ destinationImage: FxImageTile,
                                 sourceImages: [FxImageTile],
                                 pluginState: Data?,
                                 at _: CMTime) throws {
        guard let state = decodeState(pluginState),
              let sourceImage = sourceImages.first else { return }

        let scaleFactor: ScaleFactor = state.scaleFactor == 0 ? .x2 : .x4
        let deviceCache = MetalDeviceCache.shared

        guard let device = deviceCache.device(forRegistryID: sourceImage.deviceRegistryID),
              let commandQueue = deviceCache.commandQueue(forRegistryID: sourceImage.deviceRegistryID)
        else { throw UpscalerError.metalDeviceUnavailable }
        defer { deviceCache.returnCommandQueue(commandQueue, forRegistryID: sourceImage.deviceRegistryID) }

        guard let sourceTexture = sourceImage.metalTexture(for: device),
              let destTexture   = destinationImage.metalTexture(for: device)
        else { throw UpscalerError.metalDeviceUnavailable }

        let engine = try resolvedEngine(scale: scaleFactor, quality: state.qualityMode, device: device)
        let processor = TileProcessor(device: device)

        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw UpscalerError.metalDeviceUnavailable
        }

        let result = try processor.process(input: sourceTexture, scaleFactor: scaleFactor,
                                           engine: engine, commandBuffer: commandBuffer)

        let blit = commandBuffer.makeBlitCommandEncoder()!
        blit.copy(from: result, to: destTexture)
        blit.endEncoding()

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
    }

    // MARK: - Private

    private func decodeState(_ data: Data?) -> StateData? {
        guard let data, data.count >= MemoryLayout<StateData>.size else { return nil }
        return data.withUnsafeBytes { $0.bindMemory(to: StateData.self).baseAddress?.pointee }
    }

    private func resolvedEngine(scale: ScaleFactor, quality: Int32, device: MTLDevice) throws -> any UpscalerEngine {
        let key = "\(quality)-\(scale.rawValue)"
        if let cached = engines[key] { return cached }
        let engine: any UpscalerEngine
        if quality == 0 {
            engine = MPSUpscaler(scaleFactor: scale, device: device)
        } else {
            let cml = CoreMLUpscaler(scaleFactor: scale, device: device)
            Task { try? await cml.warmup() }
            engine = cml
        }
        engines[key] = engine
        return engine
    }
}
