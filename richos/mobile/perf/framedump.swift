// framedump.swift — every frame of a screen recording, scaled down, with its presentation time.
//
//   swift framedump.swift VIDEO WIDTH
//
// Run by blank.py (the no-blank-screen frame analyzer); not meant to be read by a person. It
// decodes with macOS's own AVFoundation, so it needs nothing installed: on 2026-10-02 this Mac's
// Homebrew ffmpeg could not load at all (libvpx.11.dylib missing after libvpx moved to 1.17), and
// a check that dies with a package upgrade is not a check.
//
// Output on stdout, binary:
//   one header line, ASCII:  "RFD1 <width> <height> <sourceWidth> <sourceHeight> <frames> <durationSeconds>\n"
//   then per frame:          8 bytes little-endian IEEE double, the presentation time in seconds,
//                            followed by width*height*3 bytes of RGB, rows top to bottom.
// Every decoded frame is written, in decode order, with the time the recording gives it: a
// variable-rate recording (Android's screenrecord writes a frame only when the screen changes)
// keeps its gaps, which is where a long blank screen lives.
//
// Scaling is an area average (vImage box-free high-quality resampling), so a thin line of text
// still darkens the pixels it crosses. WIDTH is chosen by the caller; height keeps the aspect.
// Exit 0 with every frame written; 2 with a sentence on stderr when the file cannot be decoded.

import AVFoundation
import Accelerate
import CoreVideo
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(("framedump: " + message + "\n").data(using: .utf8)!)
    exit(2)
}

let args = CommandLine.arguments
guard args.count == 3, let outWidth = Int(args[2]), outWidth > 0 else {
    fail("usage: framedump.swift VIDEO WIDTH")
}
let url = URL(fileURLWithPath: args[1])
guard FileManager.default.fileExists(atPath: url.path) else { fail("no such file: \(url.path)") }

let asset = AVURLAsset(url: url)
let track: AVAssetTrack
let duration: Double
do {
    guard let first = try await asset.loadTracks(withMediaType: .video).first else {
        fail("the file has no video track: \(url.path)")
    }
    track = first
    duration = CMTimeGetSeconds(try await asset.load(.duration))
} catch {
    fail("cannot read the video's tracks or duration: \(error.localizedDescription)")
}

let reader: AVAssetReader
do { reader = try AVAssetReader(asset: asset) } catch { fail("cannot open a reader: \(error.localizedDescription)") }
let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
])
output.alwaysCopiesSampleData = false
guard reader.canAdd(output) else { fail("the reader cannot produce BGRA frames for this track") }
reader.add(output)
guard reader.startReading() else { fail("decoding did not start: \(reader.error?.localizedDescription ?? "unknown")") }

var frames: [(Double, [UInt8])] = []
var outHeight = 0
var sourceWidth = 0
var sourceHeight = 0

while let sample = output.copyNextSampleBuffer() {
    guard let image = CMSampleBufferGetImageBuffer(sample) else { continue }
    let pts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
    CVPixelBufferLockBaseAddress(image, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
    let w = CVPixelBufferGetWidth(image)
    let h = CVPixelBufferGetHeight(image)
    if sourceWidth == 0 {
        sourceWidth = w
        sourceHeight = h
        outHeight = max(1, Int((Double(h) * Double(outWidth) / Double(w)).rounded()))
    }
    guard w == sourceWidth, h == sourceHeight, let base = CVPixelBufferGetBaseAddress(image) else {
        fail("frame size changed mid-recording (\(w)x\(h) after \(sourceWidth)x\(sourceHeight))")
    }
    var src = vImage_Buffer(data: base, height: vImagePixelCount(h), width: vImagePixelCount(w),
                            rowBytes: CVPixelBufferGetBytesPerRow(image))
    var scaled = [UInt8](repeating: 0, count: outWidth * outHeight * 4)
    let status = scaled.withUnsafeMutableBytes { raw -> vImage_Error in
        var dst = vImage_Buffer(data: raw.baseAddress, height: vImagePixelCount(outHeight),
                                width: vImagePixelCount(outWidth), rowBytes: outWidth * 4)
        return vImageScale_ARGB8888(&src, &dst, nil, vImage_Flags(kvImageHighQualityResampling))
    }
    guard status == kvImageNoError else { fail("scaling failed (vImage \(status))") }
    var rgb = [UInt8](repeating: 0, count: outWidth * outHeight * 3)
    for i in 0..<(outWidth * outHeight) {
        rgb[i * 3] = scaled[i * 4 + 2]      // BGRA -> RGB
        rgb[i * 3 + 1] = scaled[i * 4 + 1]
        rgb[i * 3 + 2] = scaled[i * 4]
    }
    frames.append((pts, rgb))
}
if reader.status == .failed { fail("decoding failed: \(reader.error?.localizedDescription ?? "unknown")") }
if frames.isEmpty { fail("no frame decoded from \(url.path)") }

let out = FileHandle.standardOutput
out.write("RFD1 \(outWidth) \(outHeight) \(sourceWidth) \(sourceHeight) \(frames.count) \(duration)\n".data(using: .ascii)!)
for (pts, rgb) in frames {
    var t = pts.bitPattern.littleEndian
    out.write(Data(bytes: &t, count: 8))
    out.write(Data(rgb))
}
