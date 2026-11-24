import AppKit
import CoreGraphics
import Foundation

/// Single source of truth for UseUI's visual identity (brand/palette.json + brand/app-icon.svg)
/// and pure, testable cursor motion physics.
enum UseUIBrand {
    // Brand palette (Ink #101C2C, Mint #66E9BC, Paper #F2F7F5, Slate #506173)
    static let ink = NSColor(srgbRed: 16.0 / 255.0, green: 28.0 / 255.0, blue: 44.0 / 255.0, alpha: 1)
    static let inkSoft = NSColor(srgbRed: 26.0 / 255.0, green: 42.0 / 255.0, blue: 62.0 / 255.0, alpha: 1)
    static let mint = NSColor(srgbRed: 102.0 / 255.0, green: 233.0 / 255.0, blue: 188.0 / 255.0, alpha: 1)
    static let paper = NSColor(srgbRed: 242.0 / 255.0, green: 247.0 / 255.0, blue: 245.0 / 255.0, alpha: 1)
    static let slate = NSColor(srgbRed: 80.0 / 255.0, green: 97.0 / 255.0, blue: 115.0 / 255.0, alpha: 1)
    static let amber = NSColor(srgbRed: 245.0 / 255.0, green: 166.0 / 255.0, blue: 35.0 / 255.0, alpha: 1)
    static let coral = NSColor(srgbRed: 242.0 / 255.0, green: 95.0 / 255.0, blue: 92.0 / 255.0, alpha: 1)

    /// Brand pointer path anchored with its sharp tip at (0, 0) in AppKit's bottom-up layer space.
    static func pointerPath(scale: CGFloat = 1.0) -> CGPath {
        let s = scale
        let p = CGMutablePath()
        p.move(to: .zero)
        p.addLine(to: CGPoint(x: 2.0 * s, y: -21.5 * s))
        p.addLine(to: CGPoint(x: 7.4 * s, y: -15.8 * s))
        p.addLine(to: CGPoint(x: 11.8 * s, y: -24.0 * s))
        p.addLine(to: CGPoint(x: 15.6 * s, y: -22.0 * s))
        p.addLine(to: CGPoint(x: 11.2 * s, y: -13.8 * s))
        p.addLine(to: CGPoint(x: 19.2 * s, y: -13.6 * s))
        p.closeSubpath()
        return p
    }

    /// Mint I-beam writing caret anchored near the text insertion tip at (0, 0).
    static func caretPath(scale: CGFloat = 1.0) -> CGPath {
        let s = scale
        let p = CGMutablePath()
        p.addRoundedRect(in: CGRect(x: -1.4 * s, y: -9 * s, width: 2.8 * s, height: 18 * s), cornerWidth: 1.4 * s, cornerHeight: 1.4 * s)
        p.addRoundedRect(in: CGRect(x: -4.5 * s, y: 7.4 * s, width: 9 * s, height: 2.2 * s), cornerWidth: 1.1 * s, cornerHeight: 1.1 * s)
        p.addRoundedRect(in: CGRect(x: -4.5 * s, y: -9.6 * s, width: 9 * s, height: 2.2 * s), cornerWidth: 1.1 * s, cornerHeight: 1.1 * s)
        return p
    }

    /// Four signature open-frame corner brackets (matching brand/app-icon.svg) around `rect`.
    static func cornerBracketsPath(around rect: CGRect, armLength: CGFloat, radius: CGFloat) -> CGPath {
        let arm = min(armLength, min(rect.width, rect.height) * 0.35)
        let r = min(radius, arm * 0.5)
        let p = CGMutablePath()
        let minX = rect.minX, maxX = rect.maxX, minY = rect.minY, maxY = rect.maxY

        // Top-left (AppKit maxY is top)
        p.move(to: CGPoint(x: minX, y: maxY - arm))
        p.addArc(tangent1End: CGPoint(x: minX, y: maxY), tangent2End: CGPoint(x: minX + arm, y: maxY), radius: r)
        p.addLine(to: CGPoint(x: minX + arm, y: maxY))

        // Top-right
        p.move(to: CGPoint(x: maxX - arm, y: maxY))
        p.addArc(tangent1End: CGPoint(x: maxX, y: maxY), tangent2End: CGPoint(x: maxX, y: maxY - arm), radius: r)
        p.addLine(to: CGPoint(x: maxX, y: maxY - arm))

        // Bottom-right
        p.move(to: CGPoint(x: maxX, y: minY + arm))
        p.addArc(tangent1End: CGPoint(x: maxX, y: minY), tangent2End: CGPoint(x: maxX - arm, y: minY), radius: r)
        p.addLine(to: CGPoint(x: maxX - arm, y: minY))

        // Bottom-left
        p.move(to: CGPoint(x: minX + arm, y: minY))
        p.addArc(tangent1End: CGPoint(x: minX, y: minY), tangent2End: CGPoint(x: minX, y: minY + arm), radius: r)
        p.addLine(to: CGPoint(x: minX, y: minY + arm))

        return p
    }

    /// Vector menu-bar icon reproducing UseUI's open-frame + pointer mark.
    static func menuBarIcon(activeAccent: NSColor? = nil) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: true) { rect in
            let strokeColor: NSColor = activeAccent == nil ? .labelColor : .labelColor
            strokeColor.setStroke()

            // Top-left & bottom-right open frame brackets (matches brand/app-icon.svg)
            let frame = NSBezierPath()
            frame.lineWidth = 1.65
            frame.lineCapStyle = .round
            frame.lineJoinStyle = .round
            // Top-left L
            frame.move(to: CGPoint(x: 2.5, y: 7.5))
            frame.line(to: CGPoint(x: 2.5, y: 4.3))
            frame.curve(to: CGPoint(x: 4.3, y: 2.5), controlPoint1: CGPoint(x: 2.5, y: 3.1), controlPoint2: CGPoint(x: 3.1, y: 2.5))
            frame.line(to: CGPoint(x: 8.5, y: 2.5))
            // Bottom-right L
            frame.move(to: CGPoint(x: 15.5, y: 10.5))
            frame.line(to: CGPoint(x: 15.5, y: 13.7))
            frame.curve(to: CGPoint(x: 13.7, y: 15.5), controlPoint1: CGPoint(x: 15.5, y: 14.9), controlPoint2: CGPoint(x: 14.9, y: 15.5))
            frame.line(to: CGPoint(x: 9.5, y: 15.5))
            frame.stroke()

            // Center pointer
            let pointer = NSBezierPath()
            pointer.move(to: CGPoint(x: 6.2, y: 5.5))
            pointer.line(to: CGPoint(x: 13.6, y: 9.0))
            pointer.line(to: CGPoint(x: 10.4, y: 9.8))
            pointer.line(to: CGPoint(x: 8.7, y: 12.8))
            pointer.close()
            pointer.lineJoinStyle = .round
            (activeAccent ?? strokeColor).setFill()
            pointer.fill()

            // Active status dot in upper-right when an agent is working
            if let accent = activeAccent {
                let dot = NSBezierPath(ovalIn: CGRect(x: 12.8, y: 1.4, width: 4.2, height: 4.2))
                accent.setFill()
                dot.fill()
            }
            return true
        }
        image.isTemplate = (activeAccent == nil)
        return image
    }
}

/// User-selectable motion profile for UseUI's animated agent cursor.
public enum CursorMotionStyle: String, CaseIterable, Sendable {
    case signatureArc = "signature_arc"
    case snappy = "snappy"
    case reduced = "reduced"

    public var displayName: String {
        switch self {
        case .signatureArc: "Signature Arc"
        case .snappy: "Snappy"
        case .reduced: "Reduced"
        }
    }
}

/// Pure, deterministic motion-physics engine shared across native overlays and tests.
struct CursorTrajectory: Sendable, Equatable {
    let start: CGPoint
    let control1: CGPoint
    let control2: CGPoint
    let end: CGPoint
    let duration: TimeInterval
    let maxBankRadians: CGFloat

    /// Fitts's Law adaptive duration + organic cubic Bezier arc between `start` and `end`.
    static func build(from start: CGPoint, to end: CGPoint, style: CursorMotionStyle, reduceMotion: Bool) -> Self {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let distance = hypot(dx, dy)
        if reduceMotion || style == .reduced || distance < 2 {
            return Self(start: start, control1: start, control2: end, end: end, duration: 0, maxBankRadians: 0)
        }

        let baseDuration: TimeInterval
        let arcFactor: CGFloat
        let maxBank: CGFloat
        switch style {
        case .signatureArc:
            baseDuration = min(0.24, max(0.11, 0.085 + 0.036 * log2(1.0 + Double(distance) / 36.0)))
            arcFactor = 0.14
            maxBank = 7.5 * .pi / 180.0
        case .snappy:
            baseDuration = min(0.14, max(0.075, 0.065 + 0.020 * log2(1.0 + Double(distance) / 48.0)))
            arcFactor = 0.07
            maxBank = 4.0 * .pi / 180.0
        case .reduced:
            baseDuration = 0
            arcFactor = 0
            maxBank = 0
        }

        let nx = -dy / distance
        let ny = dx / distance
        let sign: CGFloat = dx >= 0 ? 1 : -1
        let arc = min(52, max(8, distance * arcFactor)) * sign
        let c1 = CGPoint(x: start.x + dx * 0.28 + nx * arc, y: start.y + dy * 0.28 + ny * arc)
        let c2 = CGPoint(x: start.x + dx * 0.72 + nx * arc * 0.65, y: start.y + dy * 0.72 + ny * arc * 0.65)
        return Self(start: start, control1: c1, control2: c2, end: end, duration: baseDuration, maxBankRadians: maxBank)
    }

    func cgPath() -> CGPath {
        let path = CGMutablePath()
        path.move(to: start)
        path.addCurve(to: end, control1: control1, control2: control2)
        return path
    }

    func point(at rawT: CGFloat) -> CGPoint {
        let t = min(1, max(0, rawT))
        let u = 1 - t
        let uu = u * u, tt = t * t
        let x = uu * u * start.x + 3 * uu * t * control1.x + 3 * u * tt * control2.x + tt * t * end.x
        let y = uu * u * start.y + 3 * uu * t * control1.y + 3 * u * tt * control2.y + tt * t * end.y
        return CGPoint(x: x, y: y)
    }

    func bankAngleRadians(at rawT: CGFloat) -> CGFloat {
        guard maxBankRadians > 0 else { return 0 }
        let t = min(1, max(0, rawT))
        let u = 1 - t
        let tx = 3 * u * u * (control1.x - start.x) + 6 * u * t * (control2.x - control1.x) + 3 * t * t * (end.x - control2.x)
        let ty = 3 * u * u * (control1.y - start.y) + 6 * u * t * (control2.y - control1.y) + 3 * t * t * (end.y - control2.y)
        let mag = hypot(tx, ty)
        guard mag > 0.001 else { return 0 }
        let settle = sin(t * .pi)
        return max(-maxBankRadians, min(maxBankRadians, -(tx / mag) * maxBankRadians * settle))
    }
}
