import AppKit
import SwiftUI

/// The welcome window: one page that checks the Claude Code login, sets up
/// the status dot and the login item with one click, and then shows where
/// the icon sits in the menu bar.
struct WelcomeView: View {
    /// Fixed, so the window never jumps; the extra row for moving the app
    /// into „Programme“ gets extra room.
    static func size(needsMove: Bool) -> CGSize {
        CGSize(width: 560, height: needsMove ? 660 : 580)
    }

    @Bindable var model: WelcomeModel
    let finish: () -> Void
    let later: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            Header()
            Form {
                if model.iconIsHidden {
                    HiddenIconSection()
                }
                if model.needsMove {
                    MoveSection(model: model)
                }
                LoginSection(login: model.login)
                SetupSection(model: model)
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            Divider()
            HStack {
                if model.hasPendingSetup {
                    Button("Später", action: later)
                        .keyboardShortcut(.cancelAction)
                }
                Spacer()
                if model.hasPendingSetup {
                    Button("Einrichten") {
                        withAnimation(reduceMotion ? nil : .default) { model.setUp() }
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                } else {
                    Button(model.iconIsHidden ? "Schließen" : "Fertig", action: finish)
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: Self.size(needsMove: model.needsMove).width, height: Self.size(needsMove: model.needsMove).height)
        .animation(reduceMotion ? nil : .default, value: model.login)
        .animation(reduceMotion ? nil : .default, value: model.iconIsHidden)
    }
}

private struct Header: View {
    var body: some View {
        HStack(spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("Willkommen bei Claude Ring")
                    .font(.title2.weight(.semibold))
                Text("Claude Ring zeigt in der Menüleiste, wie viel von deinem Claude-Limit übrig ist und ob Claude Code gerade arbeitet.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 28)
        .padding(.top, 20)
        .padding(.bottom, 4)
    }
}

private struct MoveSection: View {
    let model: WelcomeModel

    var body: some View {
        Section {
            LabeledContent {
                if model.isMoving {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Button("In „Programme“ verschieben") {
                        Task { await model.moveToApplications() }
                    }
                }
            } label: {
                Label("Noch nicht in „Programme“", systemImage: "folder.badge.plus")
                Text("Nur von dort startet Claude Ring bei der Anmeldung und installiert Updates selbst.")
            }
            if let error = model.moveError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
        }
    }
}

private struct LoginSection: View {
    let login: WelcomeModel.Login

    var body: some View {
        Section {
            LabeledContent("Anmeldung") {
                LoginStatusLabel(login: login)
            }
            switch login {
            case .signedOut:
                Text("Öffne das Terminal, gib „claude“ ein und melde dich an. Claude Ring erkennt die Anmeldung von selbst.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Terminal öffnen") {
                        NSWorkspace.shared.openApplication(
                            at: URL(filePath: "/System/Applications/Utilities/Terminal.app"),
                            configuration: NSWorkspace.OpenConfiguration()
                        )
                    }
                    Button("„claude“ kopieren") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString("claude", forType: .string)
                    }
                }
            case .claudeCodeMissing:
                Text("Claude Ring nutzt die Anmeldung von Claude Code. Installiere Claude Code und melde dich einmal mit „claude“ im Terminal an; Claude Ring erkennt das von selbst.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Link("Anleitung zur Installation", destination: URL(string: "https://code.claude.com/docs/en/setup")!)
            case .checking, .signedIn:
                EmptyView()
            }
        } header: {
            Text("Claude Code")
        }
    }
}

private struct LoginStatusLabel: View {
    let login: WelcomeModel.Login

    var body: some View {
        HStack(spacing: 6) {
            switch login {
            case .checking:
                ProgressView()
                    .controlSize(.small)
                Text("Wird geprüft …")
            case .signedIn:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Angemeldet")
            case .signedOut:
                Image(systemName: "person.crop.circle.badge.questionmark")
                    .foregroundStyle(.orange)
                Text("Noch nicht angemeldet")
            case .claudeCodeMissing:
                Image(systemName: "exclamationmark.circle")
                    .foregroundStyle(.orange)
                Text("Claude Code nicht gefunden")
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct SetupSection: View {
    @Bindable var model: WelcomeModel

    var body: some View {
        Section {
            if model.statusDotDone {
                LabeledContent("Statuspunkt für Claude Code") { DoneLabel() }
            } else {
                Toggle(isOn: $model.setsUpStatusDot) {
                    Text("Statuspunkt für Claude Code")
                    Text("Zeigt in der Menüleiste, ob Claude Code arbeitet, auf dich wartet oder frei ist.")
                }
                .toggleStyle(.checkbox)
            }
            if let error = model.installer.lastError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }

            if model.loginItemDone {
                LabeledContent("Bei der Anmeldung öffnen") { DoneLabel() }
            } else if model.launchAtLogin.requiresApproval {
                LabeledContent {
                    Button("Systemeinstellungen öffnen") { model.launchAtLogin.openSystemSettings() }
                } label: {
                    Text("Bei der Anmeldung öffnen")
                    Text("Wartet auf deine Freigabe in den Systemeinstellungen.")
                }
            } else {
                // Unchecked while unavailable, so it doesn't promise anything.
                Toggle(isOn: model.launchAtLogin.isAvailable ? $model.opensAtLogin : .constant(false)) {
                    Text("Bei der Anmeldung öffnen")
                    Text(model.launchAtLogin.isAvailable
                         ? "Claude Ring startet nach jedem Neustart von selbst."
                         : "Verfügbar, sobald Claude Ring in „Programme“ liegt.")
                }
                .toggleStyle(.checkbox)
                .disabled(!model.launchAtLogin.isAvailable)
            }
            if let error = model.launchAtLogin.lastError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("Einrichtung")
        } footer: {
            Text("Für den Statuspunkt trägt Claude Ring ein kleines Skript als Hook in „~/.claude/settings.json“ ein und sichert die Datei vor der ersten Änderung einmal. Andere Hooks bleiben unverändert. Alles lässt sich später in den Einstellungen ändern.\n\nDas Symbol erscheint oben rechts in der Menüleiste. Auf MacBooks mit Kamera-Aussparung können es andere Symbole verdecken.")
                .foregroundStyle(.secondary)
        }
    }
}

private struct HiddenIconSection: View {
    var body: some View {
        Section {
            Label("Das Symbol ist gerade nicht zu sehen", systemImage: "eye.slash")
            Text("Auf MacBooks mit Kamera-Aussparung verdecken zu viele Symbole die hinteren. Entferne andere Symbole aus der Menüleiste oder prüfe in den Systemeinstellungen, ob Claude Ring in der Menüleiste erlaubt ist.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("Systemeinstellungen öffnen") {
                let menuBar = URL(string: "x-apple.systempreferences:com.apple.ControlCenter-Settings.extension")!
                if !NSWorkspace.shared.open(menuBar) {
                    NSWorkspace.shared.open(URL(filePath: "/System/Applications/System Settings.app"))
                }
            }
        }
    }
}

private struct DoneLabel: View {
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text("Eingerichtet")
        }
        .accessibilityElement(children: .combine)
    }
}
