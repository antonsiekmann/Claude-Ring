// Draws the background picture of the Claude Ring disk image window as
// background.png (1x) and background@2x.png into the given folder:
//
//   xcrun swift scripts/render-dmg-background.swift build/dmg
//
// scripts/make-dmg.sh combines both into one multi-resolution TIFF. Everything
// is drawn into bitmap contexts, so this runs without a window, also in CI.
//
// Finder draws the icons and their names on top. With a background picture it
// draws the names in black even in Dark Mode, so the picture stays light and
// the strip under the icons stays plain. Positions are in points from the top
// left of the window content and must match scripts/dmg-settings.py.

import AppKit
import ImageIO
import UniformTypeIdentifiers

enum Layout {
    /// The window content is 640 × 480 pt. The picture is as tall as the whole
    /// window: should Finder's title bar be lower than the 32 pt the window
    /// size allows for, the extra room shows the plain ground, not white.
    static let canvas = CGSize(width: 640, height: 512)
    static let content = CGSize(width: 640, height: 480)
    static let margin: CGFloat = 24
    /// Finder may cover the bottom of the content with the path bar, status
    /// bar or tab bar, up to 59 pt; nothing drawn reaches into that band.
    static let coverableBottom: CGFloat = 59

    static let iconSize: CGFloat = 128
    static let appIcon = CGPoint(x: 160, y: 148)
    static let applicationsIcon = CGPoint(x: 480, y: 148)
    /// Finder writes the names here; it stays plain.
    static let labelStrip = 212.0...248.0

    static let titleBaseline: CGFloat = 56
    static let firstStepBaseline: CGFloat = 304
    static let stepSpacing: CGFloat = 25
    static let footerBaseline: CGFloat = 414

    /// The arrow runs between the icons as a gently raised arc, from
    /// (244, 148) to (396, 148).
    static let arrowGap: CGFloat = 20
    static let arrowStart = CGPoint(x: appIcon.x + iconSize / 2 + arrowGap, y: appIcon.y)
    static let arrowEnd = CGPoint(x: applicationsIcon.x - iconSize / 2 - arrowGap, y: applicationsIcon.y)
    static let arrowRise: CGFloat = 18
    static let arrowWidth: CGFloat = 5
    static let arrowHeadLength: CGFloat = 11
    static let arrowHeadAngle: CGFloat = 40 * .pi / 180
    static let dotDiameter: CGFloat = 12
}

/// Colours from the app icon (AppIcon.icon) on a light, slightly cool ground.
enum Palette {
    static let background = color(0xF3F4FA)
    static let text = color(0x14172F)
    static let secondaryText = color(0x565B80)
    static let arcStart = color(0x1FC7B6)
    static let arcEnd = color(0x08887C)
    static let dot = color(0xFF9F0A)

    static let space = CGColorSpace(name: CGColorSpace.sRGB)!

    static func color(_ hex: Int) -> CGColor {
        let components = [CGFloat((hex >> 16) & 0xFF) / 255, CGFloat((hex >> 8) & 0xFF) / 255, CGFloat(hex & 0xFF) / 255, 1]
        return CGColor(colorSpace: space, components: components)!
    }
}

enum Copy {
    static let title = "„Claude Ring“ auf „Programme“ ziehen"
    static let steps = [
        "In „Programme“ öffnen und die Meldung mit „Fertig“ schließen",
        "Systemeinstellungen ▸ Datenschutz & Sicherheit ▸ „Dennoch öffnen“",
        "Bestätigen – danach führt Claude Ring durch die Einrichtung",
    ]
    static let footer = "Inoffiziell, nicht mit Anthropic verbunden · GPL-3.0"
}

struct Text {
    let line: CTLine
    let width: CGFloat
    let ascent: CGFloat
    let descent: CGFloat

    init(_ runs: [(String, NSFont, CGColor)]) {
        let string = NSMutableAttributedString()
        for (text, font, color) in runs {
            string.append(NSAttributedString(string: text, attributes: [
                .font: font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
            ]))
        }
        line = CTLineCreateWithAttributedString(string)
        var ascent: CGFloat = 0, descent: CGFloat = 0
        width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, nil))
        self.ascent = ascent
        self.descent = descent
    }

    func draw(x: CGFloat, baseline: CGFloat, in context: CGContext) {
        context.textPosition = CGPoint(x: x, y: baseline)
        CTLineDraw(line, context)
    }
}

let title = Text([(Copy.title, .systemFont(ofSize: 20, weight: .semibold), Palette.text)])
let steps = Copy.steps.enumerated().map { index, step in
    Text([
        ("\(index + 1)", .monospacedDigitSystemFont(ofSize: 13, weight: .semibold), Palette.text),
        (" · ", .systemFont(ofSize: 13), Palette.secondaryText),
        (step, .systemFont(ofSize: 13), Palette.secondaryText),
    ])
}
let footer = Text([(Copy.footer, .systemFont(ofSize: 11), Palette.secondaryText)])

/// Fails the build instead of drawing text that runs off the picture or into
/// the bottom band Finder may cover, e.g. after a change to the wording.
func checkLayout() {
    let usableWidth = Layout.content.width - 2 * Layout.margin
    let lowestBaseline = Layout.content.height - Layout.coverableBottom
    for text in [title, footer] + steps {
        precondition(text.width <= usableWidth, "Text is too wide for the window: \(text.width) pt")
    }
    precondition(Layout.titleBaseline - title.ascent >= Layout.margin, "Title is too close to the top")
    precondition(Layout.firstStepBaseline - steps[0].ascent > Layout.labelStrip.upperBound, "Steps overlap the icon names")
    let lastStep = Layout.firstStepBaseline + CGFloat(steps.count - 1) * Layout.stepSpacing
    precondition(lastStep + steps[0].descent < Layout.footerBaseline - footer.ascent, "Steps overlap the footer")
    precondition(Layout.footerBaseline + footer.descent <= lowestBaseline, "Footer reaches the band Finder may cover")
}

func drawArrow(in context: CGContext) {
    let start = Layout.arrowStart, end = Layout.arrowEnd
    let chord = end.x - start.x
    let rise = Layout.arrowRise
    let radius = (chord * chord / 4 + rise * rise) / (2 * rise)
    let center = CGPoint(x: (start.x + end.x) / 2, y: start.y - rise + radius)
    let startAngle = atan2(start.y - center.y, start.x - center.x)
    let endAngle = atan2(end.y - center.y, end.x - center.x)

    let path = CGMutablePath()
    path.addArc(center: center, radius: radius, startAngle: startAngle, endAngle: endAngle, clockwise: false)
    // Two short strokes back from the tip, turned with the arc's direction there.
    let back = atan2(-cos(endAngle), sin(endAngle))
    for side: CGFloat in [-1, 1] {
        let angle = back + side * Layout.arrowHeadAngle
        path.move(to: CGPoint(x: end.x + cos(angle) * Layout.arrowHeadLength, y: end.y + sin(angle) * Layout.arrowHeadLength))
        path.addLine(to: end)
    }

    context.saveGState()
    context.addPath(path)
    context.setLineWidth(Layout.arrowWidth)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.replacePathWithStrokedPath()
    context.clip()
    let gradient = CGGradient(colorsSpace: Palette.space, colors: [Palette.arcStart, Palette.arcEnd] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(gradient, start: CGPoint(x: start.x, y: 0), end: CGPoint(x: end.x, y: 0),
                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    context.restoreGState()

    // The dot starts the arc, as on the app icon.
    let d = Layout.dotDiameter
    context.setFillColor(Palette.dot)
    context.fillEllipse(in: CGRect(x: start.x - d / 2, y: start.y - d / 2, width: d, height: d))
}

func render(scale: CGFloat) -> CGImage {
    let context = CGContext(data: nil, width: Int(Layout.canvas.width * scale), height: Int(Layout.canvas.height * scale),
                            bitsPerComponent: 8, bytesPerRow: 0, space: Palette.space,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    // Points with the origin at the top left, like Finder's icon positions.
    context.scaleBy(x: scale, y: scale)
    context.translateBy(x: 0, y: Layout.canvas.height)
    context.scaleBy(x: 1, y: -1)
    context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
    context.setAllowsFontSmoothing(false)
    context.setShouldSubpixelPositionFonts(true)

    context.setFillColor(Palette.background)
    context.fill(CGRect(origin: .zero, size: Layout.canvas))

    title.draw(x: (Layout.content.width - title.width) / 2, baseline: Layout.titleBaseline, in: context)
    drawArrow(in: context)

    // The steps share a left edge; the block is centred as a whole.
    let blockWidth = steps.map(\.width).max()!
    let left = ((Layout.content.width - blockWidth) / 2).rounded()
    for (index, step) in steps.enumerated() {
        step.draw(x: left, baseline: Layout.firstStepBaseline + CGFloat(index) * Layout.stepSpacing, in: context)
    }
    footer.draw(x: (Layout.content.width - footer.width) / 2, baseline: Layout.footerBaseline, in: context)

    return context.makeImage()!
}

func writePNG(_ image: CGImage, scale: CGFloat, to url: URL) {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        fatalError("Cannot write \(url.path)")
    }
    // 72 dpi per point, so both files describe the same size in points.
    let dpi = 72 * scale
    CGImageDestinationAddImage(destination, image, [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi] as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { fatalError("Cannot write \(url.path)") }
}

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("Usage: render-dmg-background.swift <output folder>\n".utf8))
    exit(2)
}
let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
checkLayout()
writePNG(render(scale: 1), scale: 1, to: folder.appending(path: "background.png"))
writePNG(render(scale: 2), scale: 2, to: folder.appending(path: "background@2x.png"))
