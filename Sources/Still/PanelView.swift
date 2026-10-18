import SwiftUI

private enum PanelTab: String, CaseIterable {
    case focus = "Focus", groups = "Groups", garden = "Garden"
}

struct PanelView: View {
    @ObservedObject var model: AppModel
    @State private var tab: PanelTab = .focus
    @Environment(\.colorScheme) private var scheme
    private var accent: Color { StillStyle.accent(scheme) }
    private var secondary: Color { StillStyle.secondary(scheme) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if model.showSettings {
                Divider()
                ScrollView { SettingsView(model: model).padding(20) }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Picker("Still view", selection: $tab) {
                    ForEach(PanelTab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).labelsHidden().padding(.horizontal, 20).padding(.bottom, 4).disabled(model.busy)
                Group {
                    switch tab {
                    case .focus: FocusView(model: model, focus: model.focus)
                    case .groups: GroupsView(model: model)
                    case .garden: GardenView(focus: model.focus, now: model.now)
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            footer
        }.frame(width: 400, height: Self.panelHeight)
            .background(Color(nsColor: .windowBackgroundColor)).tint(accent)
    }

    static var panelHeight: CGFloat {
        min(620, max(460, (NSScreen.main?.visibleFrame.height ?? 900) - 40))
    }

    private var header: some View {
        HStack(spacing: 9) {
            if model.showSettings {
                Button { model.showSettings = false } label: {
                    Image(systemName: "chevron.left").frame(width: 24, height: 28)
                }.buttonStyle(.borderless).accessibilityLabel("Back to Still")
                Text("Settings").font(.system(size: 16, weight: .semibold))
            } else {
                Image(systemName: "leaf.fill").font(.system(size: 18)).foregroundStyle(accent).accessibilityHidden(true)
                Text("still").font(.system(size: 22, weight: .semibold, design: .rounded))
            }
            Spacer()
            if !model.showSettings {
                Button { model.showSettings = true } label: {
                    Image(systemName: "gearshape").font(.system(size: 14)).frame(width: 28, height: 28)
                }.buttonStyle(.borderless).foregroundStyle(secondary).disabled(model.busy)
                    .accessibilityLabel("Show settings").help("Settings")
            }
        }.padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 14)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if model.isDemo {
                Text("Preview · no system changes").font(.system(size: 10)).foregroundStyle(secondary)
            } else {
                Label(model.active ? "\(model.activeGroupCount) \(model.activeGroupCount == 1 ? "group" : "groups") blocked" : "No groups blocked",
                      systemImage: model.active ? "shield.lefthalf.filled" : "shield")
                    .font(.system(size: 11)).foregroundStyle(model.active ? accent : secondary)
            }
            Spacer()
            Button("Quit") { NSApplication.shared.terminate(nil) }.buttonStyle(.borderless)
                .font(.system(size: 11)).foregroundStyle(secondary).disabled(model.busy)
                .help("Blocking and scheduled focus cycles continue after quitting.")
        }.padding(.horizontal, 20).padding(.vertical, 12)
    }
}
