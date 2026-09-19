import Foundation
import CoreGraphics
import AppKit
import ImageIO

func markCursor(imagePath: String, x: Double, y: Double, displayWidth: Double = 1800.0) {
    guard let image = NSImage(contentsOfFile: imagePath),
          let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        printJson(["error": "Could not open image"])
        return
    }
    
    let width = cgImage.width
    let height = cgImage.height
    let scale = Double(width) / displayWidth
    
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        printJson(["error": "Could not create context"])
        return
    }
    
    ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
    
    let targetX = x * scale
    let targetY = Double(height) - (y * scale)
    let center = CGPoint(x: targetX, y: targetY)
    
    drawAgentCursor(context: ctx, tip: center, scale: scale)
    
    guard let newImage = ctx.makeImage() else {
        printJson(["error": "Could not finalize image"])
        return
    }
    
    let destUrl = URL(fileURLWithPath: imagePath)
    let isPNG = destUrl.pathExtension.lowercased() == "png"
    let destinationType = isPNG ? "public.png" : "public.jpeg"
    if let dest = CGImageDestinationCreateWithURL(destUrl as CFURL, destinationType as CFString, 1, nil) {
        let options: [CFString: Any] = isPNG
            ? [:]
            : [kCGImageDestinationLossyCompressionQuality: 0.88]
        CGImageDestinationAddImage(dest, newImage, options as CFDictionary)
        CGImageDestinationFinalize(dest)
        printJson(["status": "ok", "action": "mark_cursor", "x": x, "y": y])
    }
}
