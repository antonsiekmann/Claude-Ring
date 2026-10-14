import AppKit
import SwiftUI

/// The popover that opens when clicking the menu bar item. The popover itself
/// provides the Liquid Glass; the content uses plain fills so there is no
/// glass on glass.
struct UsagePopoverView: View {
    let monitor: UsageMonitor
    let settings: AppSettings
    let sessions: ClaudeSessionStore
    let updater: AppUpdater
    let openSettings: () -> Void

    /// Cards inside derive their corner radius from this shape, so they stay
    /// concentric with the popover.
    static let containerRadius: CGFloat = 26
    static let padding: CGFloat = 14

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PopoverHeader(planName: monitor.snapshot?.planName)

            if let snapshot = monitor.snapshot {
                if let session = snapshot.session {
                    SessionHero(info: session)
                }
                if let weekly = snapshot.weekly {
                    UsageCard(info: weekly)
                }
                if settings.showsModelLimits {
                    ForEach(snapshot.scopedWeekly) { info in
                        UsageCard(info: info)
                    }
                }
                if settings.showsBreakdown && !snapshot.breakdown.isEmpty {
                    BreakdownCard(rows: snapshot.breakdown)
                }
            } else if monitor.errorMessage == nil {
                LoadingRow()
            }

            if settings.showsClaudeSessions && !sessions.sessions.isEmpty {
                ClaudeSessionsCard(sessions: sessions.sessions)
            }

            if let error = monitor.errorMessage {
                ErrorBanner(message: error, nextAttempt: monitor.nextAttempt)
            }

            if let release = updater.availableRelease, updater.showsBanner {
                UpdateBanner(release: release, updater: updater)
            }

            PopoverFooter(
                lastUpdated: monitor.lastUpdated,
                isRefreshing: monitor.isRefreshing,
                refresh: { monitor.refreshNow() },
                openSettings: openSettings
            )
        }
        .padding(Self.padding)
        .frame(width: 340)
        .containerShape(.rect(cornerRadius: Self.containerRadius))
    }
}

// MARK: - Header

private struct PopoverHeader: View {
    let planName: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Claude-Nutzung")
                .font(.headline)
            Spacer()
            if let planName {
                Text(planName)
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.fill.tertiary, in: .capsule)
            }
        }
    }
}

private struct LoadingRow: View {
    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text("Lade Nutzungsdaten …")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }
}

// MARK: - Session

/// The current 5-hour session: a large ring with the remaining share.
private struct SessionHero: View {
    let info: UsageWindowInfo

    var body: some View {
        HStack(spacing: 16) {
            UsageRing(remainingPercent: info.remainingPercent, level: info.level)
                .frame(width: 96, height: 96)
            VStack(alignment: .leading, spacing: 4) {
                Text("Aktuelle Sitzung")
                    .font(.headline)
                Text("\(Int(info.usedPercent.rounded())) % genutzt")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                if let resetsAt = info.resetsAt {
                    // Minute precision is enough and redraws once a minute only.
                    TimelineView(.everyMinute) { context in
                        Text(CompactDuration.until(resetsAt, from: context.date).map { "Reset in \($0)" } ?? "Reset gleich")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .font(.callout)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

private struct UsageRing: View {
    let remainingPercent: Double
    let level: UsageLevel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let color = level.color
        ZStack {
            Circle()
                .stroke(.fill.tertiary, lineWidth: 10)
            Circle()
                .trim(from: 0, to: remainingPercent / 100)
                .stroke(
                    AngularGradient(colors: [color.opacity(0.75), color], center: .center,
                                    startAngle: .zero, endAngle: .degrees(360 * remainingPercent / 100)),
                    style: StrokeStyle(lineWidth: 10, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
            VStack(spacing: 0) {
                Text("\(Int(remainingPercent.rounded())) %")
                    .font(.system(.title2, design: .rounded, weight: .semibold))
                    .monospacedDigit()
                    .contentTransition(.numericText(value: remainingPercent))
                Text("übrig")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(5)
        .animation(reduceMotion ? nil : .smooth, value: remainingPercent)
    }
}

// MARK: - Cards

/// A rounded fill concentric with the popover.
private struct CardBackground: ViewModifier {
    var tint: Color?

    func body(content: Content) -> some View {
        content
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                tint.map { AnyShapeStyle($0.opacity(0.14)) } ?? AnyShapeStyle(.fill.quaternary),
                in: ConcentricRectangle(corners: .concentric(minimum: .fixed(10)), isUniform: true)
            )
    }
}

private extension View {
    func card(tint: Color? = nil) -> some View {
        modifier(CardBackground(tint: tint))
    }
}

/// A weekly limit: title, remaining share, slim bar and reset time.
private struct UsageCard: View {
    let info: UsageWindowInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(info.title)
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text("\(Int(info.remainingPercent.rounded())) % übrig")
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
            }
            UsageBar(fraction: info.remainingPercent / 100, color: info.level.color)
            HStack {
                Text("\(Int(info.usedPercent.rounded())) % genutzt")
                Spacer()
                if let resetsAt = info.resetsAt {
                    Text("Reset \(resetsAt, format: .dateTime.weekday(.abbreviated).hour().minute())")
                }
            }
            .font(.caption)
            .monospacedDigit()
            .foregroundStyle(.secondary)
        }
        .card()
        .accessibilityElement(children: .combine)
    }
}

private struct UsageBar: View {
    let fraction: Double
    let color: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.fill.tertiary)
                Capsule()
                    .fill(color.gradient)
                    .frame(width: max(proxy.size.height, proxy.size.width * min(max(fraction, 0), 1)))
            }
        }
        .frame(height: 6)
        .animation(reduceMotion ? nil : .smooth, value: fraction)
    }
}

private struct BreakdownCard: View {
    let rows: [UsageBreakdown.Row]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Wochennutzung nach Bereich")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(rows) { row in
                HStack {
                    Text(row.displayName)
                    Spacer()
                    Text("\(Int(row.percent.rounded())) %")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
            }
        }
        .card()
    }
}

private struct ClaudeSessionsCard: View {
    let sessions: [ClaudeSession]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Claude Code")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(sessions) { session in
                SessionRow(
                    projectName: session.projectName, isBackground: session.isBackground,
                    activity: session.activity, since: session.since
                )
            }
        }
        .card()
    }
}

private struct SessionRow: View {
    let projectName: String
    let isBackground: Bool
    let activity: ClaudeActivity
    let since: Date

    var body: some View {
        HStack(spacing: 8) {
            ActivityDot(activity: activity)
            Text(projectName)
                .lineLimit(1)
                .truncationMode(.middle)
            if isBackground {
                // Tells a background session apart from a terminal in the same project.
                Text("Hintergrund")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(.fill.tertiary, in: Capsule())
                    .fixedSize()
            }
            Spacer(minLength: 8)
            TimelineView(.everyMinute) { context in
                Group {
                    if let duration = CompactDuration.until(context.date, from: since) {
                        Text("\(Text(activity.label)) seit \(duration)")
                    } else {
                        Text(activity.label)
                    }
                }
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
        }
        .font(.callout)
        .accessibilityElement(children: .combine)
    }
}

/// The status dot. With "Differentiate without color" the shape differs too.
private struct ActivityDot: View {
    let activity: ClaudeActivity
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor

    var body: some View {
        Image(systemName: differentiateWithoutColor ? activity.distinctSymbolName : "circle.fill")
            .font(.system(size: 9))
            .foregroundStyle(activity.color)
            .accessibilityHidden(true)
    }
}

private struct ErrorBanner: View {
    let message: String
    let nextAttempt: Date?

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(message)
                if let nextAttempt {
                    Text("Nächster Versuch um \(nextAttempt, format: .dateTime.hour().minute()).")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption)
            .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
        .card(tint: .orange)
    }
}

/// A newer version: install it right here, put it off or read what changed.
private struct UpdateBanner: View {
    let release: AppRelease
    let updater: AppUpdater

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Claude Ring \(release.version.description) ist verfügbar")
                        .fontWeight(.semibold)
                    if let error = updater.lastError {
                        Text(error)
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    if updater.isInstalling {
                        ProgressView()
                            .controlSize(.mini)
                        Text("Wird installiert, die App startet gleich neu …")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Button(updater.canInstall ? "Installieren" : "Herunterladen …") { updater.install() }
                            .buttonStyle(.borderedProminent)
                            .help(updater.canInstall ? "Neue Version installieren und Claude Ring neu starten" : "Seite der neuen Version öffnen")
                        Button("Später") { updater.dismiss() }
                        Spacer(minLength: 0)
                        Link("Was ist neu?", destination: release.pageURL)
                            .font(.caption)
                    }
                }
                .controlSize(.small)
            }
        } icon: {
            Image(systemName: "arrow.down.circle.fill")
                .foregroundStyle(.tint)
        }
        .card(tint: .accentColor)
    }
}

// MARK: - Footer

private struct PopoverFooter: View {
    let lastUpdated: Date?
    let isRefreshing: Bool
    let refresh: () -> Void
    let openSettings: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let usageURL = URL(string: "https://claude.ai/settings/usage")

    var body: some View {
        HStack(spacing: 2) {
            if let lastUpdated {
                Text("Stand \(lastUpdated, format: .dateTime.hour().minute())")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Einstellungen", systemImage: "gearshape", action: openSettings)
                .help("Einstellungen")
            Button("Jetzt aktualisieren", systemImage: "arrow.clockwise", action: refresh)
                .symbolEffect(.rotate, isActive: isRefreshing && !reduceMotion)
                .disabled(isRefreshing)
                .help("Jetzt aktualisieren")
            if let url = Self.usageURL {
                Link(destination: url) {
                    Label("Nutzung auf claude.ai", systemImage: "arrow.up.right.square")
                }
                .help("Nutzung auf claude.ai öffnen")
            }
            Button("Claude Ring beenden", systemImage: "power") {
                NSApplication.shared.terminate(nil)
            }
            .help("Claude Ring beenden")
        }
        .labelStyle(.iconOnly)
        .buttonStyle(FooterButtonStyle())
        .padding(.top, 2)
    }
}

/// Borderless icon button with a subtle hover and press highlight.
private struct FooterButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        FooterButtonBody(configuration: configuration)
    }

    private struct FooterButtonBody: View {
        let configuration: Configuration
        @State private var isHovered = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.system(size: 14))
                .frame(width: 28, height: 28)
                .foregroundStyle(isEnabled ? .primary : .tertiary)
                .background(
                    configuration.isPressed ? AnyShapeStyle(.fill.secondary)
                        : isHovered ? AnyShapeStyle(.fill.tertiary) : AnyShapeStyle(.clear),
                    in: .circle
                )
                .contentShape(.circle)
                .onHover { isHovered = $0 }
        }
    }
}

/// Durations like "2 Std., 13 Min." without seconds.
enum CompactDuration {
    /// Nil when less than a minute is left.
    static func until(_ end: Date, from start: Date) -> String? {
        let seconds = end.timeIntervalSince(start)
        guard seconds >= 60 else { return nil }
        return Duration.seconds(seconds).formatted(
            .units(allowed: [.days, .hours, .minutes], width: .abbreviated, maximumUnitCount: 2)
        )
    }
}
