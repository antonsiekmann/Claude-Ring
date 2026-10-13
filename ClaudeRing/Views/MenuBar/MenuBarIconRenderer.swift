import AppKit

/// Draws the menu bar item: gauge, number and Claude Code status dot in one
/// image.
///
/// The image draws lazily, so `labelColor` resolves against the appearance of
/// the status bar button at display time. That keeps the number legible on
/// light and dark menu bars without tinting it.
enum MenuBarIconRenderer {
    /// The menu bar is 24 pt tall; the content stays within 18 pt.
    static let height: CGFloat = 18

    private static let ringDiameter: CGFloat = 15
    private static let ringLineWidth: CGFloat = 2.25
    private static let barWidth: CGFloat = 18
    private static let barHeight: CGFloat = 3.5
    private static let barGap: CGFloat = 2.5
    private static let dotDiameter: CGFloat = 6.5
    /// Inside the ring the dot is smaller, leaving a gap to the ring's stroke.
    private static let innerDotDiameter: CGFloat = 5.5
    private static let spacing: CGFloat = 4

    /// - Parameter drawsDot: False when the dot is shown as an animated layer
    ///   on top of the image instead; the space for it stays reserved.
    static func image(for display: MenuBarDisplay, differentiateWithoutColor: Bool, drawsDot: Bool = true) -> NSImage {
        let layout = Layout(display: display)
        let image = NSImage(size: NSSize(width: layout.width, height: height), flipped: false) { _ in
            draw(display, layout: layout, differentiateWithoutColor: differentiateWithoutColor, drawsDot: drawsDot)
            return true
        }
        image.isTemplate = display.isTemplate
        image.accessibilityDescription = display.accessibilityLabel
        return image
    }

    // MARK: - Layout

    struct Layout: Sendable {
        var graphicWidth: CGFloat
        var textWidth: CGFloat
        var dotWidth: CGFloat

        init(display: MenuBarDisplay) {
            graphicWidth = switch display.graphic {
            case .ring: MenuBarIconRenderer.ringDiameter
            case .bars: MenuBarIconRenderer.barWidth
            case .none: 0
            }
            textWidth = ceil(display.text.size(withAttributes: [.font: MenuBarIconRenderer.font]).width)
            // With a ring the dot sits inside it and takes no extra space.
            dotWidth = display.activity == nil || display.graphic.isRing ? 0 : MenuBarIconRenderer.dotDiameter
        }

        var width: CGFloat {
            let parts = [graphicWidth, textWidth, dotWidth].filter { $0 > 0 }
            return parts.reduce(0, +) + MenuBarIconRenderer.spacing * CGFloat(max(0, parts.count - 1)) + 1
        }
    }

    static var font: NSFont {
        NSFont.monospacedDigitSystemFont(ofSize: NSFont.menuBarFont(ofSize: 0).pointSize, weight: .regular)
    }

    /// Where the status dot sits, in image coordinates (origin bottom left):
    /// in the center of the ring, or after the text for the other styles.
    static func dotRect(for display: MenuBarDisplay) -> NSRect? {
        guard display.activity != nil else { return nil }
        if display.graphic.isRing {
            let inset = (ringDiameter - innerDotDiameter) / 2
            return NSRect(x: 0.5 + inset, y: (height - innerDotDiameter) / 2, width: innerDotDiameter, height: innerDotDiameter)
        }
        var x: CGFloat = 0.5
        if case .bars = display.graphic {
            x += barWidth + spacing
        }
        x += Layout(display: display).textWidth + spacing
        return NSRect(x: x, y: (height - dotDiameter) / 2, width: dotDiameter, height: dotDiameter)
    }

    // MARK: - Drawing

    private static func draw(_ display: MenuBarDisplay, layout: Layout, differentiateWithoutColor: Bool, drawsDot: Bool) {
        // Template images only use their alpha channel, so draw them in black.
        let foreground: NSColor = display.isTemplate ? .black : .labelColor
        let track = foreground.withAlphaComponent(0.25)
        var x: CGFloat = 0.5

        switch display.graphic {
        case .ring(let gauge):
            let ringRect = NSRect(x: x, y: (height - ringDiameter) / 2, width: ringDiameter, height: ringDiameter)
            drawRing(gauge, in: ringRect, color: gaugeColor(gauge, display: display, fallback: foreground), track: track)
            x += ringDiameter + spacing
        case .bars(let top, let bottom):
            let totalHeight = barHeight * 2 + barGap
            let bottomY = (height - totalHeight) / 2
            drawBar(bottom, in: NSRect(x: x, y: bottomY, width: barWidth, height: barHeight),
                    color: gaugeColor(bottom, display: display, fallback: foreground), track: track)
            drawBar(top, in: NSRect(x: x, y: bottomY + barHeight + barGap, width: barWidth, height: barHeight),
                    color: gaugeColor(top, display: display, fallback: foreground), track: track)
            x += barWidth + spacing
        case .none:
            break
        }

        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: foreground]
        let textSize = display.text.size(withAttributes: attributes)
        display.text.draw(at: NSPoint(x: x, y: (height - textSize.height) / 2), withAttributes: attributes)

        if drawsDot, let activity = display.activity, let rect = dotRect(for: display) {
            drawDot(activity, in: rect, differentiateWithoutColor: differentiateWithoutColor)
        }
    }

    private static func gaugeColor(_ gauge: MenuBarDisplay.Gauge, display: MenuBarDisplay, fallback: NSColor) -> NSColor {
        guard display.colorsGauge, let level = gauge.level else { return fallback }
        return level.nsColor
    }

    private static func drawRing(_ gauge: MenuBarDisplay.Gauge, in rect: NSRect, color: NSColor, track: NSColor) {
        let inset = ringLineWidth / 2
        let center = NSPoint(x: rect.midX, y: rect.midY)
        let radius = rect.width / 2 - inset

        let trackPath = NSBezierPath()
        trackPath.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
        trackPath.lineWidth = ringLineWidth
        track.setStroke()
        trackPath.stroke()

        let fraction = min(max(gauge.fraction, 0), 1)
        guard gauge.level != nil, fraction > 0.005 else { return }
        // Start at 12 o'clock and fill clockwise.
        let arc = NSBezierPath()
        arc.appendArc(withCenter: center, radius: radius, startAngle: 90, endAngle: 90 - 360 * fraction, clockwise: true)
        arc.lineWidth = ringLineWidth
        arc.lineCapStyle = fraction < 0.995 ? .round : .butt
        color.setStroke()
        arc.stroke()
    }

    private static func drawBar(_ gauge: MenuBarDisplay.Gauge, in rect: NSRect, color: NSColor, track: NSColor) {
        let radius = rect.height / 2
        track.setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()

        let fraction = min(max(gauge.fraction, 0), 1)
        guard gauge.level != nil, fraction > 0.005 else { return }
        let filled = NSRect(x: rect.minX, y: rect.minY, width: max(rect.height, rect.width * fraction), height: rect.height)
        color.setFill()
        NSBezierPath(roundedRect: filled, xRadius: radius, yRadius: radius).fill()
    }

    /// With "Differentiate without color" each state also gets its own shape:
    /// filled while working, half filled while waiting, hollow when idle.
    private static func drawDot(_ activity: ClaudeActivity, in rect: NSRect, differentiateWithoutColor: Bool) {
        let color = activity.nsColor
        let circle = NSBezierPath(ovalIn: rect)
        guard differentiateWithoutColor else {
            color.setFill()
            circle.fill()
            return
        }
        let outline = NSBezierPath(ovalIn: rect.insetBy(dx: 0.6, dy: 0.6))
        outline.lineWidth = 1.2
        color.setStroke()
        color.setFill()
        switch activity {
        case .working:
            circle.fill()
        case .waiting:
            outline.stroke()
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: NSRect(x: rect.minX, y: rect.minY, width: rect.width / 2, height: rect.height)).addClip()
            circle.fill()
            NSGraphicsContext.restoreGraphicsState()
        case .idle:
            outline.stroke()
        }
    }
}
