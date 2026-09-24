import Foundation
import Testing
import RichOSCore

struct WaveRecoveryTests {
    private var header: Data {
        var result = Data("RIFF".utf8)
        func integer(_ value: UInt32) {
            var value = value.littleEndian
            withUnsafeBytes(of: &value) { result.append(contentsOf: $0) }
        }
        integer(0)
        result.append(Data("WAVEfmt ".utf8)); integer(16)
        result.append(contentsOf: [1, 0, 1, 0]); integer(16_000); integer(32_000)
        result.append(contentsOf: [2, 0, 16, 0]); result.append(Data("data".utf8)); integer(0)
        return result
    }
    @Test func unfinishedSizesAndPartialLastSampleRecoverOnlyCapturedAudio() throws {
        let inspected = try WaveRecovery.inspect(header: header, fileBytes: 32_045)
        let plan = try #require(inspected)
        #expect(plan.dataOffset == 44 && plan.sizeOffset == 40 && plan.byteCount == 32_000)
        #expect(plan.durationMs == 1_000)
        #expect(try WaveRecovery.inspect(header: header, fileBytes: 44) == nil)
    }
    @Test func unrelatedAndIncompleteFilesAreNeverReinterpreted() {
        #expect(throws: CoreError.self) { try WaveRecovery.inspect(header: Data(repeating: 99, count: 80), fileBytes: 80) }
        #expect(throws: CoreError.self) { try WaveRecovery.inspect(header: header.prefix(25), fileBytes: 100) }
    }
}
