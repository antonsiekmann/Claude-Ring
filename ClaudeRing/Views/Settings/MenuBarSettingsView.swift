import SwiftUI

struct MenuBarSettingsView: View {
    @Bindable var settings: AppSettings
    let monitor: UsageMonitor
    let sessions: ClaudeSessionStore
    let installer: HookInstaller

    var body: some View {
        Form {
            Section {
                MenuBarPreview(display: MenuBarDisplay.make(
                    snapshot: monitor.snapshot,
                    hasError: monitor.needsAttention,
                    preferences: MenuBarDisplay.Preferences(
                        style: settings.menuBarStyle,
                        limit: settings.menuBarLimit,
                        value: settings.menuBarValue,
                        colorsRing: settings.colorsRing,
                        showsStatusDot: settings.showsStatusDot,
                        thresholds: settings.thresholds
                    ),
                    activity: sessions.aggregate
                ))
            }

            Section {
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
            } header: {
                Text("Darstellung")
            } footer: {
                Text("Die Farben wechseln an den Schwellen aus dem Tab „Mitteilungen“.")
                    .foregroundStyle(.secondary)
            }

            StatusDotSection(settings: settings, installer: installer)
        }
        .formStyle(.grouped)
    }
}

/// The status dot works only once the hooks are set up, so until then the
/// switch shows off and the section offers the setup right here.
private struct StatusDotSection: View {
    @Bindable var settings: AppSettings
    let installer: HookInstaller

    private var isInstalled: Bool { installer.status == .installed }

    var body: some View {
        Section {
            Toggle("Claude-Code-Status anzeigen", isOn: isInstalled ? $settings.showsStatusDot : .constant(false))
                .disabled(!isInstalled)
            if !isInstalled {
                LabeledContent {
                    Button(installer.status == .needsUpdate ? "Aktualisieren" : "Einrichten") { installer.install() }
                } label: {
                    Text(installer.status == .needsUpdate
                         ? "Der Statuspunkt muss aktualisiert werden."
                         : "Der Statuspunkt ist noch nicht eingerichtet.")
                }
                if let error = installer.lastError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }
        } footer: {
            if isInstalled {
                StatusLegend()
            } else {
                Text("Für den Punkt trägt Claude Ring ein kleines Skript als Hook in Claude Code ein; Details im Tab „Claude Code“.")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// The menu bar item as it currently looks, on a menu-bar-like capsule.
private struct MenuBarPreview: View {
    let display: MenuBarDisplay

    var body: some View {
        Image(nsImage: MenuBarIconRenderer.image(for: display))
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
                        Image(systemName: activity.distinctSymbolName)
                            .foregroundStyle(activity.color)
                            .imageScale(.small)
                    }
                }
            }
            Text("Der Punkt erscheint, sobald eine Claude-Code-Sitzung läuft.")
        }
        .foregroundStyle(.secondary)
    }
}
