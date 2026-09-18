// Decode QR codes from an image, with Apple's Vision framework — the same detector behind the
// iPhone camera's own QR scanning.
//
// This exists so the QR encoder in lib/qr.js is proved against a REAL decoder rather than against
// its own arithmetic. A code that round-trips through my own reader would prove only that my two
// halves agree with each other.
//
// Compiled on demand by test/qr-verify.js. Not part of `npm test` — a Swift compile is not something
// to make the unit tests wait for, and a machine without the developer tools should skip this
// honestly rather than fail.
//
// Exit codes: 0 with one payload per line = decoded; 3 = nothing found; 2 = could not read the input.

import Foundation
import CoreImage
import Vision

guard CommandLine.arguments.count > 1 else {
    FileHandle.standardError.write("usage: qr-decode <image>\n".data(using: .utf8)!)
    exit(2)
}

let path = CommandLine.arguments[1]
guard let data = FileManager.default.contents(atPath: path), let image = CIImage(data: data) else {
    FileHandle.standardError.write("cannot read \(path)\n".data(using: .utf8)!)
    exit(2)
}

let request = VNDetectBarcodesRequest()
request.symbologies = [.qr]
let handler = VNImageRequestHandler(ciImage: image, options: [:])
do {
    try handler.perform([request])
} catch {
    FileHandle.standardError.write("vision failed: \(error)\n".data(using: .utf8)!)
    exit(2)
}

let payloads = (request.results ?? []).compactMap { $0.payloadStringValue }
if payloads.isEmpty { exit(3) }
for payload in payloads { print(payload) }
