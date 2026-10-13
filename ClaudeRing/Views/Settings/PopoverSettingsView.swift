import SwiftUI

struct PopoverSettingsView: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Form {
            Section {
                Toggle("Modell-Wochenlimits", isOn: $settings.showsModelLimits)
                Toggle("Wochennutzung nach Bereich", isOn: $settings.showsBreakdown)
                Toggle("Claude-Code-Sitzungen", isOn: $settings.showsClaudeSessions)
            } header: {
                Text("Abschnitte im Popover")
            } footer: {
                Text("Die aktuelle Sitzung und das Wochenlimit für alle Modelle sind immer zu sehen.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
