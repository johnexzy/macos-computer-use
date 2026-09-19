import Foundation
import CoreGraphics
import AppKit

enum AgentCursorFeedback {
    case idle
    case click
    case scroll
    case error
}

func drawAgentCursor(
    context: CGContext,
    tip: CGPoint,
    scale: CGFloat = 1.0,
    feedback: AgentCursorFeedback = .idle,
    feedbackProgress: CGFloat = 0.0
) {
    context.saveGState()
    context.setLineJoin(.round)
    context.setLineCap(.round)

    let arrow = CGMutablePath()
    arrow.move(to: tip)
    arrow.addLine(to: CGPoint(x: tip.x, y: tip.y - (34 * scale)))
    arrow.addLine(to: CGPoint(x: tip.x + (9 * scale), y: tip.y - (25 * scale)))
    arrow.addLine(to: CGPoint(x: tip.x + (16 * scale), y: tip.y - (42 * scale)))
    arrow.addLine(to: CGPoint(x: tip.x + (24 * scale), y: tip.y - (38 * scale)))
    arrow.addLine(to: CGPoint(x: tip.x + (16 * scale), y: tip.y - (22 * scale)))
    arrow.addLine(to: CGPoint(x: tip.x + (31 * scale), y: tip.y - (22 * scale)))
    arrow.closeSubpath()

    context.setShadow(
        offset: CGSize(width: 0, height: -2 * scale),
        blur: 4 * scale,
        color: CGColor(gray: 0, alpha: 0.28)
    )
    context.addPath(arrow)
    context.setFillColor(CGColor(red: 0.98, green: 0.99, blue: 1.0, alpha: 1.0))
    context.setStrokeColor(CGColor(red: 0.04, green: 0.07, blue: 0.14, alpha: 1.0))
    context.setLineWidth(2.6 * scale)
    context.drawPath(using: .fillStroke)
    context.setShadow(offset: .zero, blur: 0, color: nil)

    let badgeCenter = CGPoint(x: tip.x + (30 * scale), y: tip.y - (37 * scale))
    let badgeRadius = 9.5 * scale
    let badgeRect = CGRect(
        x: badgeCenter.x - badgeRadius,
        y: badgeCenter.y - badgeRadius,
        width: badgeRadius * 2,
        height: badgeRadius * 2
    )
    let badgeColor = feedback == .error
        ? CGColor(red: 0.95, green: 0.20, blue: 0.25, alpha: 1.0)
        : CGColor(red: 0.10, green: 0.55, blue: 1.0, alpha: 1.0)
    context.setFillColor(badgeColor)
    context.fillEllipse(in: badgeRect)
    context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.95))
    context.setLineWidth(1.5 * scale)
    context.strokeEllipse(in: badgeRect)

    let spark = CGMutablePath()
    spark.move(to: CGPoint(x: badgeCenter.x, y: badgeCenter.y + (5 * scale)))
    spark.addLine(to: CGPoint(x: badgeCenter.x + (1.7 * scale), y: badgeCenter.y + (1.7 * scale)))
    spark.addLine(to: CGPoint(x: badgeCenter.x + (5 * scale), y: badgeCenter.y))
    spark.addLine(to: CGPoint(x: badgeCenter.x + (1.7 * scale), y: badgeCenter.y - (1.7 * scale)))
    spark.addLine(to: CGPoint(x: badgeCenter.x, y: badgeCenter.y - (5 * scale)))
    spark.addLine(to: CGPoint(x: badgeCenter.x - (1.7 * scale), y: badgeCenter.y - (1.7 * scale)))
    spark.addLine(to: CGPoint(x: badgeCenter.x - (5 * scale), y: badgeCenter.y))
    spark.addLine(to: CGPoint(x: badgeCenter.x - (1.7 * scale), y: badgeCenter.y + (1.7 * scale)))
    spark.closeSubpath()
    context.addPath(spark)
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    context.fillPath()

    if feedback == .click || feedback == .error {
        let progress = min(1, max(0, feedbackProgress))
        let radius = (12 + (14 * progress)) * scale
        context.setStrokeColor(
            feedback == .error
                ? CGColor(red: 1.0, green: 0.18, blue: 0.22, alpha: 1.0 - progress)
                : CGColor(red: 0.10, green: 0.65, blue: 1.0, alpha: 1.0 - progress)
        )
        context.setLineWidth(2.5 * scale)
        context.strokeEllipse(
            in: CGRect(
                x: tip.x - radius,
                y: tip.y - radius,
                width: radius * 2,
                height: radius * 2
            )
        )
    } else if feedback == .scroll {
        context.setStrokeColor(CGColor(red: 0.10, green: 0.65, blue: 1.0, alpha: 0.95))
        context.setLineWidth(2.5 * scale)
        for offset in [CGFloat(-5), CGFloat(5)] {
            let chevron = CGMutablePath()
            let centerY = tip.y - (45 * scale) + (offset * scale)
            chevron.move(to: CGPoint(x: tip.x + (43 * scale), y: centerY + (3 * scale)))
            chevron.addLine(to: CGPoint(x: tip.x + (47 * scale), y: centerY - (1 * scale)))
            chevron.addLine(to: CGPoint(x: tip.x + (51 * scale), y: centerY + (3 * scale)))
            context.addPath(chevron)
            context.strokePath()
        }
    }

    context.restoreGState()
}
