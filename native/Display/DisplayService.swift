import Foundation
import CoreGraphics
import AppKit

func getDisplaySize() {
    let mainDisplay = CGMainDisplayID()
    let bounds = CGDisplayBounds(mainDisplay)
    let screen = NSScreen.main
    let scale = screen?.backingScaleFactor ?? 1.0
    
    printJson([
        "width": bounds.width,
        "height": bounds.height,
        "scale": scale,
        "pixelWidth": bounds.width * scale,
        "pixelHeight": bounds.height * scale
    ])
}
