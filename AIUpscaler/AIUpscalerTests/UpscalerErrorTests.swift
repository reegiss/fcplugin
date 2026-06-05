import Testing
import Foundation
@testable import AIUpscaler

@Suite struct UpscalerErrorTests {

    @Test func allCasesHaveNonNilDescription() {
        struct Dummy: Error {}
        let cases: [UpscalerError] = [
            .modelLoadFailed(underlying: Dummy()),
            .metalDeviceUnavailable,
            .tileSizeMismatch(expected: CGSize(width: 512, height: 512),
                              got: CGSize(width: 256, height: 256)),
            .renderTimeout,
        ]
        for error in cases {
            #expect(error.errorDescription != nil)
            #expect(error.errorDescription?.isEmpty == false)
        }
    }

    @Test func modelLoadFailedEmbeddsUnderlyingMessage() {
        struct Cause: LocalizedError {
            var errorDescription: String? { "disk full" }
        }
        let error = UpscalerError.modelLoadFailed(underlying: Cause())
        #expect(error.errorDescription?.contains("disk full") == true)
    }
}
