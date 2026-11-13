import SwiftUI
import UserNotifications

struct NotificationSettingsView: View {
    @Bindable var settings: AppSettings
    let notifier: UsageNotifier

    private static let warningOptions = [50, 60, 70, 75, 80, 85, 90]
    fileprivate static let criticalOptions = [80, 85, 90, 95, 98]

    var body: some View {
        Form {
            Section {
                Toggle("Mitteilungen senden", isOn: $settings.notificationsEnabled)
                if settings.notificationsEnabled && notifier.authorization == .denied {
                    LabeledContent {
                        Button("Systemeinstellungen") { notifier.openSystemSettings() }
                    } label: {
                        Label("Mitteilungen sind für Claude Ring ausgeschaltet.", systemImage: "exclamationmark.triangle")
                    }
                }
            }

            Section {
                Picker("Warnung", selection: $settings.warningThreshold) {
                    ForEach(Self.warningOptions, id: \.self) { percent in
                        ThresholdLabel(usedPercent: percent, value: settings.menuBarValue).tag(percent)
                    }
                }
                Picker("Kritisch", selection: $settings.criticalThreshold) {
                    ForEach(Self.criticalOptions.filter { $0 > settings.warningThreshold }, id: \.self) { percent in
                        ThresholdLabel(usedPercent: percent, value: settings.menuBarValue).tag(percent)
                    }
                }
            } header: {
                Text("Schwellen")
            } footer: {
                Text("Ring und Balken färben sich an diesen Schwellen orange und rot; mit eingeschalteten Mitteilungen kommt dann jeweils eine Meldung.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Auch für das Wochenlimit", isOn: $settings.notifiesForWeekly)
                Toggle("Melden, wenn die Sitzung zurückgesetzt wurde", isOn: $settings.notifiesOnSessionReset)
            } footer: {
                Text("Jede Schwelle meldet sich höchstens einmal pro Zeitraum. Die Reset-Meldung kommt nur, wenn vorher die Warnschwelle erreicht war.")
                    .foregroundStyle(.secondary)
            }
            .disabled(!settings.notificationsEnabled)

            Section {
                Toggle("Melden, wenn eine neue Version verfügbar ist", isOn: $settings.notifiesAboutUpdates)
            } header: {
                Text("Updates")
            } footer: {
                Text("Einmal pro Version. Ein Klick auf die Mitteilung öffnet die Einstellungen mit dem Update.")
                    .foregroundStyle(.secondary)
            }
            .disabled(!settings.notificationsEnabled)

            Section {
                Button("Test-Mitteilung senden") { notifier.sendTest() }
                    .disabled(!settings.notificationsEnabled || notifier.authorization != .authorized)
            }
        }
        .formStyle(.grouped)
        .task { await notifier.refreshAuthorization() }
        .notificationPermissionRequest(settings: settings, notifier: notifier)
    }
}

/// A threshold in the unit the menu bar shows: "20 % übrig" or "80 % genutzt".
private struct ThresholdLabel: View {
    let usedPercent: Int
    let value: MenuBarValue

    var body: some View {
        switch value {
        case .remaining: Text("ab \(100 - usedPercent) % übrig")
        case .used: Text("ab \(usedPercent) % genutzt")
        }
    }
}

/// Asks for permission when notifications get switched on. Kept apart so that
/// only this modifier re-runs when the toggle changes.
private struct NotificationPermissionRequest: ViewModifier {
    let settings: AppSettings
    let notifier: UsageNotifier

    func body(content: Content) -> some View {
        content
            .onChange(of: settings.notificationsEnabled) { _, isEnabled in
                guard isEnabled else { return }
                Task { await notifier.requestAuthorization() }
            }
            .onChange(of: settings.warningThreshold) { _, warning in
                if settings.criticalThreshold <= warning {
                    settings.criticalThreshold = NotificationSettingsView.criticalOptions.first { $0 > warning } ?? 98
                }
            }
    }
}

private extension View {
    func notificationPermissionRequest(settings: AppSettings, notifier: UsageNotifier) -> some View {
        modifier(NotificationPermissionRequest(settings: settings, notifier: notifier))
    }
}
