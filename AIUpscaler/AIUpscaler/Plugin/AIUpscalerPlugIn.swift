import Foundation
import Metal
import os.log

private let logger = Logger(subsystem: "com.aiupscaler", category: "plugin")

@objc(AIUpscalerPlugIn)
final class UpscalerEffect: NSObject, FxTileableEffect {

    private let apiManager: PROAPIAccessing

    private enum ParamID: UInt32 {
        case scale  = 1  // popup: 0 = 2×, 1 = 4×
        case engine = 2  // popup: 0 = AI (CoreML), 1 = Fast (MPS)
        case status = 3  // read-only string
    }

    private struct StateData {
        var scaleFactor: Int32   // 0 = 2×, 1 = 4×
        var engineMode:  Int32   // 0 = AI (CoreML), 1 = Fast (MPS)
    }

    private var engines: [String: any UpscalerEngine] = [:]

    required init?(apiManager: PROAPIAccessing) {
        self.apiManager = apiManager
        super.init()
    }

    // MARK: - FxTileableEffect — lifecycle

    func addParameters() throws {
        let api = apiManager.api(for: FxParameterCreationAPI_v5.self) as! FxParameterCreationAPI_v5
        api.addPopupMenu(withName: "Scale",
                         parameterID: ParamID.scale.rawValue,
                         defaultValue: 0,
                         menuEntries: ["2×", "4×"],
                         parameterFlags: FxParameterFlags(kFxParameterFlag_DEFAULT))
        api.addPopupMenu(withName: "Engine",
                         parameterID: ParamID.engine.rawValue,
                         defaultValue: 0,
                         menuEntries: ["AI – Best Quality", "Fast – Lanczos"],
                         parameterFlags: FxParameterFlags(kFxParameterFlag_DEFAULT))
        api.addStringParameter(withName: "Status",
                               parameterID: ParamID.status.rawValue,
                               defaultValue: "● AI Active",
                               parameterFlags: FxParameterFlags(kFxParameterFlag_DISABLED |
                                                                kFxParameterFlag_NOT_ANIMATABLE))
    }

    func properties(_ properties: AutoreleasingUnsafeMutablePointer<NSDictionary>?) throws {
        properties?.pointee = [
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
        var engineIdx: Int32 = 0
        api.getIntValue(&scaleIdx,  fromParameter: ParamID.scale.rawValue,  at: renderTime)
        api.getIntValue(&engineIdx, fromParameter: ParamID.engine.rawValue, at: renderTime)
        var state = StateData(scaleFactor: scaleIdx, engineMode: engineIdx)
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

        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw UpscalerError.metalDeviceUnavailable
        }

        var usedFallback = false
        let activeEngine: any UpscalerEngine

        if state.engineMode == 0 {
            do {
                activeEngine = try resolvedEngine(scale: scaleFactor, engineMode: 0, device: device)
            } catch {
                logger.error("CoreML warmup failed: \(error.localizedDescription, privacy: .public)")
                activeEngine = try resolvedEngine(scale: scaleFactor, engineMode: 1, device: device)
                usedFallback = true
            }
        } else {
            activeEngine = try resolvedEngine(scale: scaleFactor, engineMode: 1, device: device)
        }

        let processor = TileProcessor(device: device)
        let result: MTLTexture

        if state.engineMode == 0 && !usedFallback {
            do {
                result = try processor.process(input: sourceTexture, scaleFactor: scaleFactor,
                                               engine: activeEngine, commandBuffer: commandBuffer)
            } catch {
                logger.error("CoreML render failed: \(error.localizedDescription, privacy: .public)")
                let mpsEngine = try resolvedEngine(scale: scaleFactor, engineMode: 1, device: device)
                result = try processor.process(input: sourceTexture, scaleFactor: scaleFactor,
                                               engine: mpsEngine, commandBuffer: commandBuffer)
                usedFallback = true
            }
        } else {
            result = try processor.process(input: sourceTexture, scaleFactor: scaleFactor,
                                           engine: activeEngine, commandBuffer: commandBuffer)
        }

        guard let blit = commandBuffer.makeBlitCommandEncoder() else {
            throw UpscalerError.metalDeviceUnavailable
        }
        blit.copy(from: result, to: destTexture)
        blit.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        updateStatus(engineMode: state.engineMode, fallback: usedFallback)
    }

    // MARK: - Private

    private func updateStatus(engineMode: Int32, fallback: Bool) {
        let text: String
        if fallback {
            text = "⚠ AI unavailable – using Fast"
        } else if engineMode == 0 {
            text = "● AI Active"
        } else {
            text = "● Fast Active"
        }
        guard let api = apiManager.api(for: FxParameterSettingAPI_v5.self) as? FxParameterSettingAPI_v5 else { return }
        _ = api.setStringParameterValue(text, toParameter: ParamID.status.rawValue)
    }

    private func decodeState(_ data: Data?) -> StateData? {
        guard let data, data.count >= MemoryLayout<StateData>.size else { return nil }
        return data.withUnsafeBytes { $0.bindMemory(to: StateData.self).baseAddress?.pointee }
    }

    private func resolvedEngine(scale: ScaleFactor, engineMode: Int32, device: MTLDevice) throws -> any UpscalerEngine {
        let key = "\(engineMode)-\(scale.rawValue)"
        if let cached = engines[key] { return cached }

        let engine: any UpscalerEngine
        if engineMode == 1 {
            // MPS needs no async warmup
            engine = MPSUpscaler(scaleFactor: scale, device: device)
        } else {
            let cml = CoreMLUpscaler(scaleFactor: scale, device: device)
            var warmupError: Error?
            let sema = DispatchSemaphore(value: 0)
            Task.detached {
                do { try await cml.warmup() }
                catch { warmupError = error }
                sema.signal()
            }
            sema.wait()
            if let err = warmupError { throw err }
            engine = cml
        }

        engines[key] = engine
        return engine
    }
}
