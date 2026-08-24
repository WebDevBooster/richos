import XCTest
@testable import RichOSCompanionCore

/// The frozen L=mic / R=system invariant is the one thing that, if wrong, silently mis-attributes
/// every speaker. These tests pin it mechanically.
final class ChannelMixerTests: XCTestCase {

    func testFloatToInt16ClampsAndScales() {
        XCTAssertEqual(ChannelMixer.floatToInt16(0), 0)
        XCTAssertEqual(ChannelMixer.floatToInt16(1.0), 32767)
        XCTAssertEqual(ChannelMixer.floatToInt16(-1.0), -32767)
        XCTAssertEqual(ChannelMixer.floatToInt16(2.0), 32767)   // clamps high
        XCTAssertEqual(ChannelMixer.floatToInt16(-2.0), -32767) // clamps low
    }

    func testInterleaveMapsMicToLeftSystemToRight() {
        // Distinct amplitudes so L/R can't be confused.
        let mic: [Float] = [1.0, 0.5]
        let sys: [Float] = [-1.0, -0.5]
        let out = ChannelMixer.interleaveToInt16(mic: mic, system: sys)
        // frame 0: L=mic(1.0)=32767, R=sys(-1.0)=-32767 ; frame 1: L=0.5, R=-0.5
        XCTAssertEqual(out[0], 32767)          // LEFT  = me
        XCTAssertEqual(out[1], -32767)         // RIGHT = others
        XCTAssertEqual(out[2], ChannelMixer.floatToInt16(0.5))
        XCTAssertEqual(out[3], ChannelMixer.floatToInt16(-0.5))
        XCTAssertEqual(out.count, 4)
    }

    func testDownmixAveragesChannels() {
        // interleaved stereo: [L0,R0, L1,R1]
        let interleaved: [Float] = [1.0, 0.0, 0.0, 1.0]
        let mono = ChannelMixer.downmixToMono(interleaved: interleaved, channelCount: 2)
        XCTAssertEqual(mono, [0.5, 0.5])
    }

    func testInt16LEByteOrder() {
        let bytes = ChannelMixer.int16LEBytes([0x0102])
        XCTAssertEqual(bytes, [0x02, 0x01]) // little-endian
    }

    func testPeakAndRms() {
        XCTAssertEqual(ChannelMixer.peak([-0.3, 0.7, -0.2]), 0.7, accuracy: 1e-6)
        XCTAssertEqual(ChannelMixer.rms([1.0, -1.0]), 1.0, accuracy: 1e-6)
        XCTAssertEqual(ChannelMixer.rms([]), 0.0, accuracy: 1e-6)
    }
}
