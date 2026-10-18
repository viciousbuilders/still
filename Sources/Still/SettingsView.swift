import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @Environment(\.colorScheme) private var scheme
    private var secondary: Color { StillStyle.secondary(scheme) }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Open Still at login", isOn: Binding(
                    get: { model.loginStatus == .enabled || model.loginStatus == .requiresApproval },
                    set: { model.setLogin($0) }
                )).toggleStyle(.switch).font(.system(size: 13)).disabled(model.isDemo || model.busy)
                Text("Keep Still available in your menu bar.").font(.system(size: 12)).foregroundStyle(secondary)
                if model.loginStatus == .requiresApproval {
                    Button("Approve in Login Items…") { SMAppService.openSystemSettingsLoginItems() }
                }
                if let error = model.settingsError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.system(size: 12)).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel("Login item error: \(error)")
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text("Block groups").font(.system(size: 12, weight: .semibold))
                Text("Block groups independently. A website stays blocked while any active group includes it. Unblock a group before deleting it.")
                    .font(.system(size: 12)).foregroundStyle(secondary).fixedSize(horizontal: false, vertical: true)
                if model.active || model.focus.session != nil {
                    Button("Unblock all groups") { Task { await model.stopAll() } }.disabled(model.busy)
                    if let error = model.error { Text(error).font(.system(size: 12)).foregroundStyle(.red) }
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Website blocking").font(.system(size: 12, weight: .semibold))
                Text(verbatim: "Each domain includes its www version. Add other subdomains separately.")
                    .font(.system(size: 12)).foregroundStyle(secondary).fixedSize(horizontal: false, vertical: true)
                Text("Blocks website lookups and server connections, including existing connections. Already downloaded content may remain visible. VPNs and proxies can bypass blocking.")
                    .font(.system(size: 12)).foregroundStyle(secondary).fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Always on").font(.system(size: 12, weight: .semibold))
                Text("Stays active after quitting or restarting your Mac. Use Unblock group to turn it off.")
                    .font(.system(size: 12)).foregroundStyle(secondary).fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Timed sessions").font(.system(size: 12, weight: .semibold))
                Text("The helper follows your timers even with Still closed. After sleep it catches up to the current phase. A helper restart can take up to 15 seconds.")
                    .font(.system(size: 12)).foregroundStyle(secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

}
