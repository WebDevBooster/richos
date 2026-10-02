// `bin/rios screen-text PNG` — the text on a screenshot, read by the Mac's own Vision framework.
//
// The start-time measurement uses it to check, after its launches, that the app is showing the
// conversation it was given (`perf.py ios`): a Release app has no development bridge to ask, and the
// check must read what is on screen, not what the app believes. Lines come back top to bottom.
#if os(macOS)
import Foundation
import Vision
import RichOSCore

enum ScreenText {
    static func read(_ png: URL) throws -> [String] {
        guard FileManager.default.fileExists(atPath: png.path) else { throw CoreError("no screenshot at \(png.path)") }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.recognitionLanguages = ["en-US"]
        try VNImageRequestHandler(url: png).perform([request])
        let observations = request.results ?? []
        // Vision's origin is the bottom left: a larger y is higher on the screen.
        return observations
            .sorted { ($0.boundingBox.maxY, -$0.boundingBox.minX) > ($1.boundingBox.maxY, -$1.boundingBox.minX) }
            .compactMap { $0.topCandidates(1).first?.string }
    }
}
#endif
