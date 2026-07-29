import Testing
@testable import XDecodeCore

@Suite("Decode limits")
struct DecodeLimitsTests {
    @Test("Decoded output accepts the exact limit and rejects cumulative overflow")
    func validatesCumulativeOutputSize() throws {
        try DecodeLimits.validateDecompressedOutputSize(
            currentSize: 60,
            appending: 40,
            maximumSize: 100
        )

        let error = #expect(throws: DecodeError.self) {
            try DecodeLimits.validateDecompressedOutputSize(
                currentSize: 60,
                appending: 41,
                maximumSize: 100
            )
        }
        guard case .outputLimitExceeded = error else {
            Issue.record("Expected outputLimitExceeded")
            return
        }
    }
}
