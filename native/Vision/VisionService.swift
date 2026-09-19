import Foundation
import CoreGraphics
import AppKit
import Vision

func recognizeTextInImage(imagePath: String, logicalWidth: Double? = nil) -> [[String: Any]] {
    guard let image = NSImage(contentsOfFile: imagePath),
          let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        return []
    }
    
    let pixelWidth = Double(cgImage.width)
    let pixelHeight = Double(cgImage.height)
    
    let scale: Double
    if let lWidth = logicalWidth, lWidth > 0 {
        scale = pixelWidth / lWidth
    } else {
        let screen = NSScreen.main
        scale = Double(screen?.backingScaleFactor ?? 2.0)
    }
    
    var results: [[String: Any]] = []
    
    let requestHandler = VNImageRequestHandler(cgImage: cgImage, options: [:])
    let request = VNRecognizeTextRequest { (req, err) in
        guard let observations = req.results as? [VNRecognizedTextObservation] else { return }
        
        for obs in observations {
            guard let topCandidate = obs.topCandidates(1).first else { continue }
            let bbox = obs.boundingBox
            
            let rectX = (bbox.origin.x * pixelWidth) / scale
            let rectY = ((1.0 - bbox.origin.y - bbox.height) * pixelHeight) / scale
            let rectW = (bbox.width * pixelWidth) / scale
            let rectH = (bbox.height * pixelHeight) / scale
            let centerX = rectX + (rectW / 2.0)
            let centerY = rectY + (rectH / 2.0)
            
            results.append([
                "text": topCandidate.string,
                "confidence": topCandidate.confidence,
                "bounds": [
                    "x": rectX,
                    "y": rectY,
                    "width": rectW,
                    "height": rectH,
                    "centerX": centerX,
                    "centerY": centerY
                ]
            ])
        }
    }
    
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true
    
    try? requestHandler.perform([request])
    return results
}

func ocrCommand(imagePath: String, query: String? = nil, logicalWidth: Double? = nil) {
    let allText = recognizeTextInImage(imagePath: imagePath, logicalWidth: logicalWidth)
    
    if let q = query, !q.isEmpty {
        let filtered = allText.filter { item in
            let text = item["text"] as? String ?? ""
            return text.localizedCaseInsensitiveContains(q)
        }
        printJson(["status": "ok", "query": q, "count": filtered.count, "elements": filtered])
    } else {
        printJson(["status": "ok", "count": allText.count, "elements": allText])
    }
}

func queryRanges(in text: String, query: String, matchMode: String) -> [(range: NSRange, type: String, rank: Int)] {
    let source = text as NSString
    let queryLength = (query as NSString).length
    guard queryLength > 0 else { return [] }

    var results: [(range: NSRange, type: String, rank: Int)] = []
    var searchRange = NSRange(location: 0, length: source.length)
    while searchRange.length >= queryLength {
        let found = source.range(
            of: query,
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            range: searchRange
        )
        if found.location == NSNotFound { break }

        let isExact = found.location == 0
            && found.length == source.length
            && normalizedText(text) == normalizedText(query)
        let beforeIsWord = found.location > 0 && isWordCodeUnit(source.character(at: found.location - 1))
        let afterIndex = found.location + found.length
        let afterIsWord = afterIndex < source.length && isWordCodeUnit(source.character(at: afterIndex))
        let isWord = !beforeIsWord && !afterIsWord
        let isPrefix = found.location == 0

        let matchType: String
        let rank: Int
        if isExact {
            matchType = "exact"
            rank = 4
        } else if isWord {
            matchType = "word"
            rank = 3
        } else if isPrefix {
            matchType = "prefix"
            rank = 2
        } else {
            matchType = "substring"
            rank = 1
        }

        let accepted: Bool
        switch matchMode {
        case "exact":
            accepted = isExact
        case "word":
            accepted = isExact || isWord
        case "prefix":
            accepted = isExact || isPrefix
        default:
            accepted = true
        }
        if accepted {
            results.append((found, matchType, rank))
        }

        let nextLocation = found.location + max(1, found.length)
        if nextLocation >= source.length { break }
        searchRange = NSRange(location: nextLocation, length: source.length - nextLocation)
    }
    return results
}

func findTextInWindow(
    targetText: String,
    windowId: Int? = nil,
    appName: String? = nil,
    matchMode: String = "substring"
) {
    var wid = windowId
    var pid: pid_t = 0
    var windowBounds: [String: Double]? = nil
    
    if let w = wid {
        guard let metadata = windowMetadata(windowId: w) else {
            printJson([
                "status": "error",
                "code": "TARGET_NOT_FOUND",
                "error": "Window ID \(w) not found"
            ])
            return
        }
        if let app = appName,
           !metadata.appName.localizedCaseInsensitiveContains(app),
           !metadata.title.localizedCaseInsensitiveContains(app) {
            printJson([
                "status": "error",
                "code": "TARGET_MISMATCH",
                "error": "Window ID \(w) does not belong to \(app)"
            ])
            return
        }
        pid = metadata.pid
        windowBounds = [
            "x": metadata.bounds.origin.x,
            "y": metadata.bounds.origin.y,
            "width": metadata.bounds.size.width,
            "height": metadata.bounds.size.height
        ]
    } else if let app = appName {
        if let target = findTargetWindowInfo(targetApp: app) {
            wid = target.wid
            pid = target.pid
            windowBounds = target.bounds
        } else {
            printJson([
                "status": "error",
                "code": "TARGET_NOT_FOUND",
                "error": "No window found matching \(app)"
            ])
            return
        }
    }

    guard requireScreenCaptureAccess() else { return }
    
    let tmpFile = "/tmp/mcp_ocr_\(Date().timeIntervalSince1970).png"
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    if let targetWid = wid {
        proc.arguments = ["-x", "-o", "-l", "\(targetWid)", "-t", "png", tmpFile]
    } else {
        proc.arguments = ["-x", "-t", "png", tmpFile]
    }
    do {
        try proc.run()
    } catch {
        printJson(["status": "error", "code": "CAPTURE_FAILED", "error": error.localizedDescription])
        return
    }
    proc.waitUntilExit()
    guard proc.terminationStatus == 0, FileManager.default.fileExists(atPath: tmpFile) else {
        printJson([
            "status": "error",
            "code": "CAPTURE_FAILED",
            "error": "screencapture exited with status \(proc.terminationStatus)"
        ])
        return
    }
    
    defer {
        try? FileManager.default.removeItem(atPath: tmpFile)
    }
    
    let elements = recognizeTextInImage(imagePath: tmpFile, logicalWidth: windowBounds?["width"])
    
    var matches: [[String: Any]] = []
    for item in elements {
        let text = item["text"] as? String ?? ""
        let ranges = queryRanges(in: text, query: targetText, matchMode: matchMode)
        for queryMatch in ranges {
            var itemCopy = item
            if let lineBounds = item["bounds"] as? [String: Double] {
                let sourceLength = max(1, (text as NSString).length)
                let startFraction = Double(queryMatch.range.location) / Double(sourceLength)
                let widthFraction = Double(queryMatch.range.length) / Double(sourceLength)
                let matchX = (lineBounds["x"] ?? 0) + ((lineBounds["width"] ?? 0) * startFraction)
                let matchWidth = (lineBounds["width"] ?? 0) * widthFraction
                let matchBounds: [String: Double] = [
                    "x": matchX,
                    "y": lineBounds["y"] ?? 0,
                    "width": matchWidth,
                    "height": lineBounds["height"] ?? 0,
                    "centerX": matchX + (matchWidth / 2.0),
                    "centerY": lineBounds["centerY"] ?? 0
                ]
                itemCopy["lineBounds"] = lineBounds
                itemCopy["bounds"] = matchBounds
                itemCopy["matchedText"] = (text as NSString).substring(with: queryMatch.range)
                itemCopy["matchType"] = queryMatch.type
                itemCopy["matchRank"] = queryMatch.rank
                itemCopy["querySimilarity"] = min(1.0, Double(queryMatch.range.length) / Double(sourceLength))

                if let winB = windowBounds {
                    let globalCenterX = (matchBounds["centerX"] ?? 0) + (winB["x"] ?? 0)
                    let globalCenterY = (matchBounds["centerY"] ?? 0) + (winB["y"] ?? 0)
                    itemCopy["globalCoordinates"] = [
                        "x": globalCenterX,
                        "y": globalCenterY
                    ]
                }
            }
            if windowBounds == nil,
               let bounds = itemCopy["bounds"] as? [String: Double] {
                itemCopy["globalCoordinates"] = [
                    "x": bounds["centerX"] ?? 0,
                    "y": bounds["centerY"] ?? 0
                ]
            }
            matches.append(itemCopy)
        }
    }

    matches.sort { lhs, rhs in
        let lhsRank = lhs["matchRank"] as? Int ?? 0
        let rhsRank = rhs["matchRank"] as? Int ?? 0
        if lhsRank != rhsRank { return lhsRank > rhsRank }
        return (lhs["confidence"] as? Float ?? 0) > (rhs["confidence"] as? Float ?? 0)
    }
    
    if let best = matches.first {
        printJson([
            "status": "ok",
            "found": true,
            "bestMatch": best,
            "allMatches": matches,
            "windowId": wid ?? 0,
            "pid": pid,
            "matchMode": matchMode,
            "windowBounds": windowBounds ?? [:]
        ])
    } else {
        printJson([
            "status": "ok",
            "found": false,
            "error": "Text '\(targetText)' not found",
            "windowId": wid ?? 0,
            "pid": pid,
            "matchMode": matchMode,
            "availableText": elements.prefix(15).map { $0["text"] ?? "" }
        ])
    }
}

func waitForText(targetText: String, windowId: Int? = nil, appName: String? = nil, timeoutSeconds: Double = 5.0) {
    let start = CFAbsoluteTimeGetCurrent()
    var wid = windowId
    var pid: pid_t = 0
    var windowBounds: [String: Double]? = nil
    
    if let w = wid {
        guard let metadata = windowMetadata(windowId: w) else {
            printJson([
                "status": "error",
                "code": "TARGET_NOT_FOUND",
                "error": "Window ID \(w) not found"
            ])
            return
        }
        if let app = appName,
           !metadata.appName.localizedCaseInsensitiveContains(app),
           !metadata.title.localizedCaseInsensitiveContains(app) {
            printJson([
                "status": "error",
                "code": "TARGET_MISMATCH",
                "error": "Window ID \(w) does not belong to \(app)"
            ])
            return
        }
        pid = metadata.pid
        windowBounds = [
            "x": metadata.bounds.origin.x,
            "y": metadata.bounds.origin.y,
            "width": metadata.bounds.size.width,
            "height": metadata.bounds.size.height
        ]
    } else if let app = appName {
        if let target = findTargetWindowInfo(targetApp: app) {
            wid = target.wid
            pid = target.pid
            windowBounds = target.bounds
        } else {
            printJson([
                "status": "error",
                "code": "TARGET_NOT_FOUND",
                "error": "No window found matching \(app)"
            ])
            return
        }
    }

    guard requireScreenCaptureAccess() else { return }
    
    while (CFAbsoluteTimeGetCurrent() - start) < timeoutSeconds {
        let tmpFile = "/tmp/mcp_wait_\(Date().timeIntervalSince1970).png"
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        if let targetWid = wid {
            proc.arguments = ["-x", "-o", "-l", "\(targetWid)", "-t", "png", tmpFile]
        } else {
            proc.arguments = ["-x", "-t", "png", tmpFile]
        }
        do {
            try proc.run()
        } catch {
            printJson(["status": "error", "code": "CAPTURE_FAILED", "error": error.localizedDescription])
            return
        }
        proc.waitUntilExit()
        guard proc.terminationStatus == 0, FileManager.default.fileExists(atPath: tmpFile) else {
            usleep(120000)
            continue
        }
        
        let elements = recognizeTextInImage(imagePath: tmpFile, logicalWidth: windowBounds?["width"])
        try? FileManager.default.removeItem(atPath: tmpFile)
        
        for item in elements {
            let text = item["text"] as? String ?? ""
            let ranges = queryRanges(in: text, query: targetText, matchMode: "substring")
            if !ranges.isEmpty {
                var match = item
                if let lineBounds = item["bounds"] as? [String: Double] {
                    let sourceLength = max(1, (text as NSString).length)
                    let startFraction = Double(ranges[0].range.location) / Double(sourceLength)
                    let widthFraction = Double(ranges[0].range.length) / Double(sourceLength)
                    let matchX = (lineBounds["x"] ?? 0) + ((lineBounds["width"] ?? 0) * startFraction)
                    let matchWidth = (lineBounds["width"] ?? 0) * widthFraction
                    let matchBounds: [String: Double] = [
                        "x": matchX,
                        "y": lineBounds["y"] ?? 0,
                        "width": matchWidth,
                        "height": lineBounds["height"] ?? 0,
                        "centerX": matchX + (matchWidth / 2.0),
                        "centerY": lineBounds["centerY"] ?? 0
                    ]
                    match["lineBounds"] = lineBounds
                    match["bounds"] = matchBounds
                    match["matchedText"] = (text as NSString).substring(with: ranges[0].range)
                    match["matchType"] = ranges[0].type
                    match["matchRank"] = ranges[0].rank

                    if let winB = windowBounds {
                        match["globalCoordinates"] = [
                            "x": (matchBounds["centerX"] ?? 0) + (winB["x"] ?? 0),
                            "y": (matchBounds["centerY"] ?? 0) + (winB["y"] ?? 0)
                        ]
                    }
                }
                printJson([
                    "status": "ok",
                    "found": true,
                    "elapsed": CFAbsoluteTimeGetCurrent() - start,
                    "bestMatch": match,
                    "windowId": wid ?? 0,
                    "pid": pid,
                    "windowBounds": windowBounds ?? [:]
                ])
                return
            }
        }
        
        usleep(120000) // 120ms polling interval
    }
    
    printJson([
        "status": "ok",
        "found": false,
        "error": "Timeout waiting for '\(targetText)' after \(timeoutSeconds)s",
        "windowId": wid ?? 0,
        "pid": pid,
        "windowBounds": windowBounds ?? [:]
    ])
}
