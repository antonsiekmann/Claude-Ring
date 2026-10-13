import AppKit
import Foundation
import Testing
@testable import ClaudeRing

private let german = Locale(identifier: "de_DE")

private func snapshot(sessionUsed: Double?, weeklyUsed: Double?) throws -> UsageSnapshot {
    var limits: [String] = []
    if let sessionUsed { limits.append(#"{ "kind": "session", "percent": \#(sessionUsed) }"#) }
    if let weeklyUsed { limits.append(#"{ "kind": "weekly_all", "percent": \#(weeklyUsed) }"#) }
    let json = #"{ "limits": [\#(limits.joined(separator: ","))] }"#
    let response = try UsageAPIClient.makeDecoder().decode(UsageResponse.self, from: Data(json.utf8))
    let credentials = ClaudeCredentials.OAuth(accessToken: "t", expiresAt: nil, subscriptionType: nil, rateLimitTier: nil)
    return UsageSnapshot(response: response, credentials: credentials)
}

private func preferences(
    style: MenuBarStyle = .ring,
    limit: MenuBarLimit = .session,
    value: MenuBarValue = .remaining,
    colorsRing: Bool = true,
    showsStatusDot: Bool = true
) -> MenuBarDisplay.Preferences {
    .init(style: style, limit: limit, value: value, colorsRing: colorsRing, showsStatusDot: showsStatusDot)
}

struct MenuBarDisplayTests {
    @Test func `Shows the remaining session share next to the ring`() throws {
        let display = MenuBarDisplay.make(
            snapshot: try snapshot(sessionUsed: 13, weeklyUsed: 64), hasError: false,
            preferences: preferences(), activity: .working, locale: german
        )

        #expect(display.text == "87\u{00A0}%")
        #expect(display.graphic == .ring(.init(fraction: 0.87, level: .normal)))
        #expect(display.activity == .working)
        #expect(!display.isTemplate)
    }

    @Test func `Shows the used share but keeps the level of the remaining share`() throws {
        let display = MenuBarDisplay.make(
            snapshot: try snapshot(sessionUsed: 92, weeklyUsed: 10), hasError: false,
            preferences: preferences(value: .used), activity: nil, locale: german
        )

        #expect(display.text == "92\u{00A0}%")
        #expect(display.graphic == .ring(.init(fraction: 0.92, level: .critical)))
    }

    @Test func `Can follow the weekly limit instead`() throws {
        let display = MenuBarDisplay.make(
            snapshot: try snapshot(sessionUsed: 13, weeklyUsed: 75), hasError: false,
            preferences: preferences(limit: .weekly), activity: nil, locale: german
        )

        #expect(display.text == "25\u{00A0}%")
        #expect(display.graphic == .ring(.init(fraction: 0.25, level: .warning)))
    }

    @Test func `Shows both windows as bars`() throws {
        let display = MenuBarDisplay.make(
            snapshot: try snapshot(sessionUsed: 13, weeklyUsed: 64), hasError: false,
            preferences: preferences(style: .bars), activity: nil, locale: german
        )

        #expect(display.graphic == .bars(
            top: .init(fraction: 0.87, level: .normal),
            bottom: .init(fraction: 0.36, level: .normal)
        ))
    }

    @Test func `Shows only numbers without any color`() throws {
        let display = MenuBarDisplay.make(
            snapshot: try snapshot(sessionUsed: 13, weeklyUsed: 64), hasError: false,
            preferences: preferences(style: .numbers), activity: nil, locale: german
        )

        #expect(display.text == "87 · 36")
        #expect(display.graphic == .none)
        #expect(!display.colorsGauge)
        #expect(display.isTemplate)
    }

    @Test func `Marks loading, missing and stale data`() throws {
        let loading = MenuBarDisplay.make(snapshot: nil, hasError: false, preferences: preferences(), activity: nil)
        let failed = MenuBarDisplay.make(snapshot: nil, hasError: true, preferences: preferences(), activity: nil)
        let stale = MenuBarDisplay.make(
            snapshot: try snapshot(sessionUsed: 13, weeklyUsed: nil), hasError: true,
            preferences: preferences(), activity: nil, locale: german
        )

        #expect(loading.text == "…")
        #expect(loading.graphic == .ring(.init(fraction: 0, level: nil)))
        #expect(failed.text == "–")
        #expect(stale.text == "87\u{00A0}% !")
    }

    @Test func `Uses a template image only when nothing is colored`() throws {
        let data = try snapshot(sessionUsed: 13, weeklyUsed: nil)
        let monochrome = MenuBarDisplay.make(snapshot: data, hasError: false, preferences: preferences(colorsRing: false), activity: nil)
        let withDot = MenuBarDisplay.make(snapshot: data, hasError: false, preferences: preferences(colorsRing: false), activity: .idle)
        let dotHidden = MenuBarDisplay.make(
            snapshot: data, hasError: false, preferences: preferences(colorsRing: false, showsStatusDot: false), activity: .idle
        )

        #expect(monochrome.isTemplate)
        #expect(!withDot.isTemplate)
        #expect(dotHidden.activity == nil)
        #expect(dotHidden.isTemplate)
    }

    @Test func `Describes everything for VoiceOver`() throws {
        let display = MenuBarDisplay.make(
            snapshot: try snapshot(sessionUsed: 13, weeklyUsed: 64), hasError: false,
            preferences: preferences(), activity: .waiting
        )

        #expect(display.accessibilityLabel.contains("Sitzung 87 Prozent übrig"))
        #expect(display.accessibilityLabel.contains("Woche 36 Prozent übrig"))
        #expect(display.accessibilityLabel.contains("wartet auf deine Antwort"))
    }
}

struct UsageLevelTests {
    @Test(arguments: [
        (0.0, UsageLevel.critical), (9.9, .critical), (10, .warning), (29.9, .warning), (30, .normal), (100, .normal),
    ])
    func `Maps the remaining share to a level`(remaining: Double, expected: UsageLevel) {
        #expect(UsageLevel(remainingPercent: remaining) == expected)
    }
}

struct ClaudeActivityTests {
    @Test func `Prefers waiting over working over idle`() {
        #expect(ClaudeActivity.aggregate([.idle, .working, .waiting]) == .waiting)
        #expect(ClaudeActivity.aggregate([.idle, .working]) == .working)
        #expect(ClaudeActivity.aggregate([.idle]) == .idle)
        #expect(ClaudeActivity.aggregate([]) == nil)
    }
}

@MainActor
struct MenuBarIconRendererTests {
    private func display(_ style: MenuBarStyle, activity: ClaudeActivity?) throws -> MenuBarDisplay {
        MenuBarDisplay.make(
            snapshot: try snapshot(sessionUsed: 13, weeklyUsed: 64), hasError: false,
            preferences: preferences(style: style), activity: activity, locale: german
        )
    }

    @Test func `Fits the menu bar height`() throws {
        let image = MenuBarIconRenderer.image(for: try display(.ring, activity: .working), differentiateWithoutColor: false)
        #expect(image.size.height == 18)
    }

    @Test func `Puts the dot inside the ring without taking space`() throws {
        let ring = MenuBarIconRenderer.image(for: try display(.ring, activity: nil), differentiateWithoutColor: false)
        let ringWithDot = MenuBarIconRenderer.image(for: try display(.ring, activity: .idle), differentiateWithoutColor: false)

        #expect(ringWithDot.size.width == ring.size.width)
    }

    /// Renders the image at 4x and returns the color at a point in image coordinates.
    private func color(of image: NSImage, at point: NSPoint) throws -> NSColor {
        let scale: CGFloat = 4
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(image.size.width * scale), pixelsHigh: Int(image.size.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        rep.size = image.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance {
            image.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
        }
        NSGraphicsContext.restoreGraphicsState()
        let x = Int(point.x * scale), y = rep.pixelsHigh - 1 - Int(point.y * scale)
        return try #require(rep.colorAt(x: x, y: y))
    }

    @Test(arguments: [MenuBarStyle.ring, .bars, .numbers])
    func `Draws the dot exactly where the pulse layer goes`(style: MenuBarStyle) throws {
        let display = try display(style, activity: .working)
        let rect = try #require(MenuBarIconRenderer.dotRect(for: display))
        let center = NSPoint(x: rect.midX, y: rect.midY)

        let drawn = try color(of: MenuBarIconRenderer.image(for: display, differentiateWithoutColor: false), at: center)
        let left = try color(
            of: MenuBarIconRenderer.image(for: display, differentiateWithoutColor: false, drawsDot: false), at: center
        )

        #expect(drawn.redComponent > 0.8 && drawn.greenComponent < 0.4 && drawn.alphaComponent > 0.9)
        #expect(left.alphaComponent < 0.1)
    }

    @Test func `Has no dot position without a session`() throws {
        #expect(MenuBarIconRenderer.dotRect(for: try display(.ring, activity: nil)) == nil)
    }

    @Test func `Puts the dot next to bars and numbers`() throws {
        for style in [MenuBarStyle.bars, .numbers] {
            let plain = MenuBarIconRenderer.image(for: try display(style, activity: nil), differentiateWithoutColor: false)
            let withDot = MenuBarIconRenderer.image(for: try display(style, activity: .working), differentiateWithoutColor: false)
            #expect(withDot.size.width > plain.size.width)
        }
    }
}

/// Renders the menu bar item in several states to PNG files for a visual
/// check. Runs only when `SNAPSHOT_DIR` is set, e.g. via
/// `TEST_RUNNER_SNAPSHOT_DIR=/tmp/shots xcodebuild test …`.
@MainActor
struct MenuBarSnapshotTests {
    nonisolated static let directory = ProcessInfo.processInfo.environment["SNAPSHOT_DIR"]

    @Test(.enabled(if: directory != nil))
    func `Render menu bar states`() throws {
        let directory = try #require(Self.directory)
        let cases: [(String, MenuBarStyle, Double, Double, ClaudeActivity?, Bool, Bool)] = [
            ("ring-normal-working", .ring, 13, 64, .working, true, false),
            ("ring-warning-waiting", .ring, 78, 64, .waiting, true, false),
            ("ring-critical-idle", .ring, 95, 64, .idle, true, false),
            ("ring-mono-nodot", .ring, 13, 64, nil, false, false),
            ("ring-dwc-waiting", .ring, 13, 64, .waiting, true, true),
            ("bars-working", .bars, 40, 85, .working, true, false),
            ("numbers-idle", .numbers, 13, 64, .idle, true, false),
        ]
        var rows: [NSImage] = []
        for (name, style, sessionUsed, weeklyUsed, activity, colors, dwc) in cases {
            let display = MenuBarDisplay.make(
                snapshot: try snapshot(sessionUsed: sessionUsed, weeklyUsed: weeklyUsed), hasError: false,
                preferences: preferences(style: style, colorsRing: colors), activity: activity, locale: german
            )
            let image = MenuBarIconRenderer.image(for: display, differentiateWithoutColor: dwc)
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                rows.append(Self.render(image, appearance: appearance))
            }
            _ = name
        }
        try Self.writeSheet(rows, columns: 2, to: URL(filePath: directory).appending(path: "menubar.png"))
    }

    /// Draws the image at 4x on a menu-bar-like background.
    static func render(_ image: NSImage, appearance: NSAppearance.Name) -> NSImage {
        let scale: CGFloat = 4
        let size = NSSize(width: 120, height: 24)
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance {
            (appearance == .darkAqua ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.93, alpha: 1)).setFill()
            NSRect(origin: .zero, size: size).fill()
            let origin = NSPoint(x: 8, y: (size.height - image.size.height) / 2)
            if image.isTemplate {
                // The menu bar tints template images with the label color.
                let tinted = NSImage(size: image.size, flipped: false) { rect in
                    image.draw(in: rect)
                    NSColor.labelColor.set()
                    rect.fill(using: .sourceAtop)
                    return true
                }
                tinted.draw(at: origin, from: .zero, operation: .sourceOver, fraction: 1)
            } else {
                image.draw(at: origin, from: .zero, operation: .sourceOver, fraction: 1)
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        let result = NSImage(size: size)
        result.addRepresentation(rep)
        return result
    }

    static func writeSheet(_ images: [NSImage], columns: Int, to url: URL) throws {
        let tile = images.first?.size ?? .zero
        let rows = (images.count + columns - 1) / columns
        let scale: CGFloat = 4
        let sheet = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(tile.width * scale) * columns, pixelsHigh: Int(tile.height * scale) * rows,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        sheet.size = NSSize(width: tile.width * CGFloat(columns), height: tile.height * CGFloat(rows))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: sheet)
        for (index, image) in images.enumerated() {
            let x = CGFloat(index % columns) * tile.width
            let y = sheet.size.height - CGFloat(index / columns + 1) * tile.height
            image.draw(in: NSRect(x: x, y: y, width: tile.width, height: tile.height))
        }
        NSGraphicsContext.restoreGraphicsState()
        try sheet.representation(using: .png, properties: [:])!.write(to: url)
    }
}
