import Foundation

@main struct RecordingRecoveryTests {
    static func main() throws {
        var wav = Data("RIFF".utf8) + Data(repeating:0,count:4) + Data("WAVEfmt ".utf8)
        wav += Data([16,0,0,0,1,0,1,0,128,62,0,0,0,125,0,0,2,0,16,0])
        wav += Data("data".utf8) + Data(repeating:0,count:4)
        wav += Data((0..<32_000).map {UInt8($0 % 256)})
        let repaired = recoverInterruptedRecording(wav)!
        precondition(repaired.suffix(32_000) == wav.suffix(32_000),"Recovery must preserve every audio byte")
        precondition(repaired[40..<44] == Data([0,125,0,0]),"Data size must describe the retained one-second recording")
        precondition(recoverInterruptedRecording(repaired) == nil,"A valid recording must remain unchanged")
        var stereo = wav; stereo[22] = 2
        precondition(recoverInterruptedRecording(stereo) == nil,"Never infer recovery for another format")
        precondition(recoverInterruptedRecording(Data(wav.prefix(43))) == nil,"Truncated headers are not audio")
        var odd = wav; odd.append(1)
        precondition(recoverInterruptedRecording(odd) == nil,"Never invent a missing PCM sample byte")
        print("Recording recovery: 6 checks passed")
    }
}
