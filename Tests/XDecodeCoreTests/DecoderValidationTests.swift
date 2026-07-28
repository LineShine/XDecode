import Foundation
import Testing
@testable import XDecodeCore

@Suite("Decoder validation")
struct DecoderValidationTests {
    @Test("Empty and malformed files fail without producing output", arguments: [LogFormat.xlog, .mx])
    func rejectsMalformedInput(format: LogFormat) {
        let decoder: any LogDecoder = format == .xlog ? XlogDecoder() : MXDecoder()
        #expect(throws: (any Error).self) {
            try decoder.decode(Data(), sourceURL: URL(fileURLWithPath: "/tmp/empty.\(format.rawValue)"))
        }
    }

    @Test("Logan credentials require at least 16 bytes and truncate longer values")
    func validatesLoganCredentials() {
        #expect(throws: (any Error).self) {
            try LoganCredentials(key: "short", iv: "1234567890123456")
        }
        #expect(throws: Never.self) {
            try LoganCredentials(key: "1234567890123456", iv: "1234567890123456")
        }
        let extended = try? LoganCredentials(
            key: "1234567890123456-extra-key",
            iv: "abcdefghijklmnop-extra-iv"
        )
        #expect(extended?.key == Data("1234567890123456".utf8))
        #expect(extended?.iv == Data("abcdefghijklmnop".utf8))
    }

    @Test("A yyyy-MM-dd filename is detected as extensionless Logan")
    func detectsExtensionlessLogan() throws {
        #expect(try LogFormat.detect(from: URL(fileURLWithPath: "/tmp/2026-07-27")) == .logan)
        #expect(throws: (any Error).self) {
            try LogFormat.detect(from: URL(fileURLWithPath: "/tmp/2026-7-27"))
        }
    }

    @Test("Xlog credentials normalize prefix and whitespace")
    func normalizesXlogCredentials() throws {
        let expected = validPrivateKey
        let hex = expected.map { String(format: "%02X", $0) }.joined(separator: " ")
        let credentials = try XlogCredentials(privateKeyHex: "  0x\(hex)\n")

        #expect(credentials.privateKey == expected)
    }

    @Test("Xlog credentials reject invalid Hex, length, and scalar")
    func rejectsInvalidXlogCredentials() {
        #expect(throws: (any Error).self) { try XlogCredentials(privateKeyHex: "abc") }
        #expect(throws: (any Error).self) { try XlogCredentials(privateKeyHex: String(repeating: "g", count: 64)) }
        #expect(throws: (any Error).self) { try XlogCredentials(privateKeyHex: String(repeating: "0", count: 64)) }
        #expect(throws: (any Error).self) { try XlogCredentials(privateKeyHex: String(repeating: "f", count: 64)) }
    }

    private var validPrivateKey: Data {
        var data = Data(repeating: 0, count: 32)
        data[data.count - 1] = 1
        return data
    }
}
