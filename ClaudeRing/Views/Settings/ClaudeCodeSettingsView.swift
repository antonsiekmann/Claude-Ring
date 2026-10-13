import AppKit
import SwiftUI

struct ClaudeCodeSettingsView: View {
    let monitor: UsageMonitor
    let installer: HookInstaller
    let sessions: ClaudeSessionStore

    var body: some View {
        Form {
            HookSection(installer: installer, lastEventDate: sessions.lastEventDate)
            CredentialSection(planName: monitor.snapshot?.planName, tokenExpiry: monitor.tokenExpiry)
        }
        .formStyle(.grouped)
        .onAppear { installer.refresh() }
    }
}

private struct HookSection: View {
    let installer: HookInstaller
    let lastEventDate: Date?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Section {
            LabeledContent("Status") {
                HookStatusLabel(status: installer.status)
            }
            if let lastEventDate {
                LabeledContent("Letztes Ereignis") {
                    Text(lastEventDate, format: .relative(presentation: .named))
                }
            }
            LabeledContent {
                if installer.status == .installed {
                    Button("Entfernen", role: .destructive) { run(installer.uninstall) }
                } else {
                    Button(installer.status == .needsUpdate ? "Aktualisieren" : "Einrichten") { run(installer.install) }
                        .buttonStyle(.borderedProminent)
                }
            } label: {
                if let backup = installer.lastBackup {
                    Button("Sicherung im Finder zeigen") {
                        NSWorkspace.shared.activateFileViewerSelecting([backup])
                    }
                    .buttonStyle(.link)
                }
            }
            if let error = installer.lastError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("Statusanzeige")
        } footer: {
            Text("Für den Punkt in der Menüleiste trägt die App ein kleines Skript als Hook in „~/.claude/settings.json“ ein und sichert die Datei vorher. Andere Hooks bleiben unverändert. Das Skript merkt sich nur Ereignis, Sitzung, Projektordner und Werkzeugname, keine Eingaben oder Inhalte. Neue Claude-Code-Sitzungen melden sich sofort.")
                .foregroundStyle(.secondary)
        }
    }

    private func run(_ action: () -> Void) {
        withAnimation(reduceMotion ? nil : .default) { action() }
    }
}

private struct HookStatusLabel: View {
    let status: HookInstaller.Status

    var body: some View {
        HStack(spacing: 6) {
            switch status {
            case .installed:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .transition(.symbolEffect(.drawOn))
                Text("Eingerichtet")
            case .needsUpdate:
                Image(systemName: "arrow.triangle.2.circlepath")
                    .foregroundStyle(.orange)
                Text("Veraltet")
            case .notInstalled:
                Image(systemName: "circle.dashed")
                    .foregroundStyle(.secondary)
                Text("Nicht eingerichtet")
            }
        }
    }
}

private struct CredentialSection: View {
    let planName: String?
    let tokenExpiry: Date?

    var body: some View {
        Section {
            LabeledContent("Quelle", value: "Schlüsselbund von Claude Code")
            LabeledContent("Plan", value: planName ?? "–")
            LabeledContent("Token gültig bis") {
                if let tokenExpiry {
                    Text(tokenExpiry, format: .dateTime.weekday().day().month().hour().minute())
                } else {
                    Text(verbatim: "–")
                }
            }
        } header: {
            Text("Anmeldung")
        } footer: {
            Text("Die App liest das Token über „/usr/bin/security“, ohne Passwortabfrage, und hält es nur im Arbeitsspeicher. Sie speichert, ändert oder erneuert es nie; das übernimmt Claude Code.")
                .foregroundStyle(.secondary)
        }
    }
}
