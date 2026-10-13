import SwiftUI

struct MenuBarSettingsView: View {
    @Bindable var settings: AppSettings
    let monitor: UsageMonitor
    let sessions: ClaudeSessionStore

    var body: some View {
        Form {
            Section {
                MenuBarPreview(display: MenuBarDisplay.make(
                    snapshot: monitor.snapshot,
                    hasError: monitor.errorMessage != nil,
                    preferences: MenuBarDisplay.Preferences(
                        style: settings.menuBarStyle,
                        limit: settings.menuBarLimit,
                        value: settings.menuBarValue,
                        colorsRing: settings.colorsRing,
                        showsStatusDot: settings.showsStatusDot
                    ),
                    activity: sessions.aggregate
                ))
            }

            Section("Darstellung") {
                Picker("Stil", selection: $settings.menuBarStyle) {
                    ForEach(MenuBarStyle.allCases) { style in
                        Text(style.label).tag(style)
                    }
                }
                Picker("Limit", selection: $settings.menuBarLimit) {
                    ForEach(MenuBarLimit.allCases) { limit in
                        Text(limit.label).tag(limit)
                    }
                }
                .disabled(settings.menuBarStyle == .numbers)
                Picker("Wert", selection: $settings.menuBarValue) {
                    ForEach(MenuBarValue.allCases) { value in
                        Text(value.label).tag(value)
                    }
                }
                .pickerStyle(.segmented)
                Toggle("Ring und Balken einfärben", isOn: $settings.colorsRing)
                    .disabled(settings.menuBarStyle == .numbers)
            }

            Section {
                Toggle("Claude-Code-Status anzeigen", isOn: $settings.showsStatusDot)
            } footer: {
                StatusLegend()
            }
        }
        .formStyle(.grouped)
    }
}

/// The menu bar item as it currently looks, on a menu-bar-like capsule.
private struct MenuBarPreview: View {
    let display: MenuBarDisplay
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor

    var body: some View {
        Image(nsImage: MenuBarIconRenderer.image(for: display, differentiateWithoutColor: differentiateWithoutColor))
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(.quaternary, in: .capsule)
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Vorschau: \(display.accessibilityLabel)"))
    }
}

private struct StatusLegend: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 14) {
                ForEach([ClaudeActivity.working, .waiting, .idle], id: \.self) { activity in
                    Label {
                        Text(activity.label)
                    } icon: {
                        Image(systemName: "circle.fill")
                            .foregroundStyle(activity.color)
                            .imageScale(.small)
                    }
                }
            }
            Text("Der Punkt erscheint, sobald eine Claude-Code-Sitzung läuft. Einrichten im Tab „Claude Code“.")
        }
        .foregroundStyle(.secondary)
    }
}
