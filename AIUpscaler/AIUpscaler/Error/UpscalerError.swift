import Foundation

enum UpscalerError: Error {
    case modelLoadFailed(underlying: Error)
    case metalDeviceUnavailable
    case tileSizeMismatch(expected: CGSize, got: CGSize)
    case renderTimeout // threshold: 5000ms per frame
}

extension UpscalerError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .modelLoadFailed(let e):
            return "Model load failed: \(e.localizedDescription)"
        case .metalDeviceUnavailable:
            return "Metal device unavailable on this system"
        case .tileSizeMismatch(let expected, let got):
            return "Tile size mismatch: expected \(expected), got \(got)"
        case .renderTimeout:
            return "Render exceeded 5000ms timeout — frame passed through unmodified"
        }
    }
}
