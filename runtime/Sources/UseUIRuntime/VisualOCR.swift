import CoreGraphics
import UseUIProtocol
import Foundation
import Vision

struct OCRTextRegion: Sendable {
    let text: String
    let normalizedBounds: CGRect?
}

struct OCRTextScan: Sendable {
    var regions: [OCRTextRegion]
    var truncated = false
}

struct VisualOCR: Sendable {
    private let read: @Sendable (CGImage, String?, OperationContext) throws -> OCRTextScan

    init() { read = Self.readVision }
    init(read: @escaping @Sendable (CGImage, String?, OperationContext) throws -> OCRTextScan) { self.read = read }

    func recognize(image: CGImage, query: String? = nil, context: OperationContext) throws -> OcrEvidence {
        try context.check()
        if let query, query.isEmpty || query.utf8.count > Limits.maxOcrQueryBytes {
            throw NativeFailure(.invalidRequest, "OCR query must be nonempty and within the byte limit")
        }
        let started = ocrMilliseconds()
        let scan: OCRTextScan
        do { scan = try read(image, query, context) }
        catch {
            try context.check()
            return OcrEvidence(status: .failed, collected: interval(started), matches: [])
        }
        try context.check()
        var matches: [OcrMatch] = []
        var partial = scan.truncated
        var missingGeometry = false
        let encoder = JSONEncoder()
        // Reserve the wire envelope at the largest timestamp width; count commas as matches are added.
        var bytes = try encoder.encode(OcrEvidence(status: .partial,
            collected: CollectionInterval(startedUnixMs: .max, finishedUnixMs: .max), matches: [])).count
        for region in scan.regions {
            try context.check()
            if matches.count == Limits.maxOcrMatches { partial = true; break }
            guard !region.text.isEmpty, region.text.utf8.count <= Limits.maxOcrTextBytes else {
                partial = true; continue
            }
            guard let normalized = region.normalizedBounds,
                  let bounds = Self.imageBounds(normalized, width: image.width, height: image.height) else {
                missingGeometry = true; partial = true; continue
            }
            let match = OcrMatch(text: region.text, imageBounds: bounds)
            let size = try encoder.encode(match).count + (matches.isEmpty ? 0 : 1)
            guard bytes + size <= Limits.maxOcrBytes else { partial = true; break }
            matches.append(match); bytes += size
        }
        try context.check()
        let status: OcrStatus = matches.isEmpty && missingGeometry && !scan.truncated ? .unavailable : partial ? .partial : .complete
        return OcrEvidence(status: status, collected: interval(started), matches: matches)
    }

    /// Vision uses bottom-left normalized coordinates. Returned bounds use top-left pixel edges.
    static func imageBounds(_ normalized: CGRect, width: Int, height: Int) -> Rect? {
        guard width > 0, height > 0,
              [normalized.origin.x, normalized.origin.y, normalized.width, normalized.height].allSatisfy(\.isFinite),
              normalized.width > 0, normalized.height > 0,
              normalized.minX >= 0, normalized.minY >= 0, normalized.maxX <= 1, normalized.maxY <= 1 else { return nil }
        return Rect(x: normalized.minX * Double(width), y: (1 - normalized.maxY) * Double(height),
            width: normalized.width * Double(width), height: normalized.height * Double(height))
    }

    /// Ranges always refer to the original candidate string, including its Unicode indices.
    static func queryRanges(_ query: String, in text: String) -> [Range<String.Index>] {
        guard !query.isEmpty else { return [] }
        var ranges: [Range<String.Index>] = []
        var start = text.startIndex
        while start < text.endIndex, ranges.count <= Limits.maxOcrMatches,
              let range = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], range: start..<text.endIndex) {
            guard !range.isEmpty else { break }
            ranges.append(range); start = range.upperBound
        }
        return ranges
    }

    private static func readVision(image: CGImage, query: String?, context: OperationContext) throws -> OCRTextScan {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = false
        request.progressHandler = { request, _, _ in
            if context.interruption != nil { request.cancel() }
        }
        // VNRequest cancellation is cooperative. Keep the synchronous worker occupied until Vision returns.
        let cancellation = OCRCancellation(request)
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + .milliseconds(10), repeating: .milliseconds(10))
        timer.setEventHandler { if context.interruption != nil { cancellation.cancel() } }
        timer.resume()
        defer { timer.cancel() }
        try context.check()
        try VNImageRequestHandler(cgImage: image, orientation: .up, options: [:]).perform([request])
        try context.check()
        guard let observations = request.results else { throw NativeFailure(.nativeFailed, "Vision OCR results unavailable") }
        var scan = OCRTextScan(regions: [])
        for (index, observation) in observations.enumerated() {
            try context.check()
            guard index < 1024 else { scan.truncated = true; break }
            guard let candidate = observation.topCandidates(1).first else { scan.truncated = true; continue }
            let text = candidate.string
            if let query {
                for range in queryRanges(query, in: text) {
                    try context.check()
                    guard scan.regions.count < Limits.maxOcrMatches + 1 else { scan.truncated = true; break }
                    // .fast supplies character-range geometry. These are Vision UI boxes, not glyph-tight bounds.
                    let bounds = try? candidate.boundingBox(for: range)?.boundingBox
                    scan.regions.append(OCRTextRegion(text: String(text[range]), normalizedBounds: bounds))
                }
            } else {
                scan.regions.append(OCRTextRegion(text: text, normalizedBounds: observation.boundingBox))
            }
            if scan.regions.count > Limits.maxOcrMatches { scan.truncated = true; break }
        }
        return scan
    }

    private func interval(_ started: UInt64) -> CollectionInterval {
        CollectionInterval(startedUnixMs: started, finishedUnixMs: max(started, ocrMilliseconds()))
    }
}

/// Only Vision's cooperative cancel operation crosses threads; all other request access stays on the worker.
private final class OCRCancellation: @unchecked Sendable {
    private let request: VNRequest
    init(_ request: VNRequest) { self.request = request }
    func cancel() { request.cancel() }
}

private func ocrMilliseconds() -> UInt64 { UInt64(Date().timeIntervalSince1970 * 1000) }
