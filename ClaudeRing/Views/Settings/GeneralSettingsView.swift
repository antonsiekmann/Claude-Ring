import SwiftUI

struct GeneralSettingsView: View {
    @Bindable var settings: AppSettings
    let launchAtLogin: LaunchAtLogin
    let uninstaller: AppUninstaller

    var body: some View {
        Form {
            Section("Start") {
                LaunchAtLoginRow(launchAtLogin: launchAtLogin)
            }

            Section {
                Picker("Nutzung abrufen", selection: $settings.refreshInterval) {
                    ForEach(RefreshInterval.allCases) { interval in
                        Text(interval.label).tag(interval)
                    }
                }
            } header: {
                Text("Aktualisierung")
            } footer: {
                Text("Anthropic begrenzt die Abfragen der Nutzung streng; seltener abzurufen vermeidet Sperren. Beim Öffnen des Popovers wird zusätzlich aktualisiert, wenn die Daten älter als 2 Minuten sind. Im Ruhezustand und bei gesperrtem Bildschirm pausiert der Abruf, nach Fehlern wird er seltener.")
                    .foregroundStyle(.secondary)
            }

            Section {
                UninstallRow(uninstaller: uninstaller)
            } header: {
                Text("Entfernen")
            } footer: {
                Text("Entfernt die App und alles, was sie angelegt hat, einschließlich der Hooks in Claude Code. Claude Code selbst bleibt unverändert.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { launchAtLogin.refresh() }
    }
}

private struct UninstallRow: View {
    let uninstaller: AppUninstaller
    @State private var isConfirming = false

    var body: some View {
        LabeledContent("Claude Ring vollständig entfernen") {
            Button("Entfernen …", role: .destructive) { isConfirming = true }
        }
        .alert("Claude Ring vollständig entfernen?", isPresented: $isConfirming) {
            Button("Entfernen und beenden", role: .destructive) { uninstaller.uninstall() }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text(uninstaller.summary)
        }
        if let error = uninstaller.lastError {
            Label(error, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        }
    }
}

private struct LaunchAtLoginRow: View {
    @Bindable var launchAtLogin: LaunchAtLogin

    var body: some View {
        Toggle("Bei der Anmeldung öffnen", isOn: $launchAtLogin.isOn)
            .disabled(!launchAtLogin.isAvailable)
        if !launchAtLogin.isAvailable {
            Text("Verfügbar, sobald die App im Ordner „Programme“ liegt.")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else if launchAtLogin.requiresApproval {
            LabeledContent("Wartet auf deine Freigabe in den Systemeinstellungen.") {
                Button("Öffnen") { launchAtLogin.openSystemSettings() }
            }
            .font(.callout)
        } else if let error = launchAtLogin.lastError {
            Text(error)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

extension LaunchAtLogin {
    /// Two-way projection for the toggle.
    var isOn: Bool {
        get { isEnabled || requiresApproval }
        set { setEnabled(newValue) }
    }
}
