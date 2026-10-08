import SwiftUI
import ServiceManagement

struct PanelView: View {
    @ObservedObject var model: AppModel
    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var websiteFieldFocused: Bool
    private var accent: Color { colorScheme == .dark ? Color(red: 0.43, green: 0.84, blue: 0.74) : Color(red: 0.06, green: 0.38, blue: 0.32) }
    private var secondary: Color {
        let level = colorScheme == .dark ? 0.68 : 0.38
        return Color(red: level, green: level, blue: level)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if model.showSettings {
                ScrollView { settings.padding(18) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                websiteEditor
                Divider()
                blockControls.padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 8)
            }
            footer
        }
        .frame(width: 380, height: Self.panelHeight)
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(accent)
        .onChange(of: model.showSettings) { settings in
            if !settings { websiteFieldFocused = true }
        }
    }

    // Explicit sizing prevents the menu bar host from collapsing scrollable
    // content. Only the website list scrolls; add and blocking controls stay put.
    static var panelHeight: CGFloat {
        min(500, max(380, (NSScreen.main?.visibleFrame.height ?? 900) - 40))
    }

    private var header: some View {
        HStack(spacing: 8) {
            if model.showSettings {
                Button { model.showSettings = false } label: {
                    Image(systemName: "chevron.left").font(.system(size: 13, weight: .medium)).frame(width: 24, height: 26)
                }.buttonStyle(.borderless).accessibilityLabel("Back to blocklist").help("Back to blocklist")
                Text("Settings").font(.system(size: 15, weight: .semibold))
            } else {
                Image(systemName: "leaf.fill").font(.system(size: 17)).foregroundStyle(accent).accessibilityHidden(true)
                Text("still").font(.system(size: 20, weight: .semibold, design: .rounded))
            }
            Spacer()
            Text(model.active ? "Blocking" : "Off")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(model.active ? accent : secondary)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(model.active ? accent.opacity(0.1) : Color.clear, in: Capsule())
                .accessibilityLabel(model.active ? "Website blocking is on" : "Website blocking is off")
            if !model.showSettings {
                Button { model.showSettings = true } label: {
                    Image(systemName: "gearshape").font(.system(size: 14)).frame(width: 26, height: 26)
                }.buttonStyle(.borderless).foregroundStyle(secondary)
                    .accessibilityLabel("Show settings").help("Settings")
            }
        }.padding(.horizontal, 18).padding(.vertical, 12)
    }

    private var websiteEditor: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Websites").font(.system(size: 13, weight: .semibold))
                Spacer()
                if !model.websites.isEmpty {
                    Text("\(model.websites.count)").font(.system(size: 12)).foregroundStyle(secondary).monospacedDigit()
                }
            }.padding(.bottom, 12)
            websiteList.frame(maxWidth: .infinity, maxHeight: .infinity)
            domainEntry.padding(.top, 12)
        }.padding(.horizontal, 18).padding(.top, 18).padding(.bottom, 16)
    }

    @ViewBuilder private var websiteList: some View {
        if model.websites.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "globe").font(.system(size: 24, weight: .light)).foregroundStyle(secondary).accessibilityHidden(true)
                Text("Add your first website").font(.system(size: 13, weight: .medium))
                Text("Paste a domain or website URL below.")
                    .font(.system(size: 12)).foregroundStyle(secondary)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.websites, id: \.self) { domain in
                        HStack(spacing: 10) {
                            Text(domain).font(.system(size: 13)).lineLimit(1).truncationMode(.middle).help(domain)
                            Spacer(minLength: 4)
                            Button { model.removeWebsite(domain) } label: {
                                Image(systemName: "xmark").font(.system(size: 10, weight: .medium)).frame(width: 26, height: 30)
                            }.buttonStyle(.borderless).foregroundStyle(secondary).accessibilityLabel("Remove \(domain)")
                        }.padding(.leading, 2).padding(.vertical, 6)
                        if domain != model.websites.last { Divider() }
                    }
                }
            }.disabled(model.busy)
        }
    }

    private var domainEntry: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField("Add a domain or URL", text: $model.input)
                    .textFieldStyle(.roundedBorder).focused($websiteFieldFocused)
                    .onSubmit { model.addWebsites() }.accessibilityLabel("Website domains or URLs")
                    .accessibilityHint(model.inputError ?? "Paste one or more domains or URLs, then press Return to add them.")
                    .onChange(of: model.input) { _ in model.inputError = nil }
                Button("Add") { model.addWebsites(); websiteFieldFocused = true }
                    .accessibilityLabel("Add websites").disabled(model.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if let error = model.inputError {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.system(size: 11)).foregroundStyle(.red).lineLimit(3).help(error)
                    .accessibilityLabel("Invalid website: \(error)")
            } else {
                Text("Paste one or more domains or URLs.").font(.system(size: 11)).foregroundStyle(secondary)
            }
        }.disabled(model.busy)
    }

    private var durationSelection: Binding<BlockDuration> {
        Binding(
            get: { model.mode == .always ? .always : BlockDuration(rawValue: model.duration) ?? .minutes25 },
            set: { value in
                model.mode = value == .always ? .always : .timer
                if value != .always { model.duration = value.rawValue }
                model.savePreferences()
            }
        )
    }

    private var blockControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                if model.active {
                    Text(model.configuration?.expiresAt == nil ? "Always on" : "Time remaining")
                        .font(.system(size: 12, weight: .medium))
                    Spacer()
                    Text(model.configuration?.expiresAt == nil ? "Until you stop it" : model.statusDetail)
                        .font(.system(size: 12)).monospacedDigit().foregroundStyle(secondary)
                } else {
                    Text("Duration").font(.system(size: 12, weight: .medium))
                    Spacer()
                    Picker("Blocking duration", selection: durationSelection) {
                        ForEach(BlockDuration.allCases, id: \.self) { Text($0.label).tag($0) }
                    }.labelsHidden().frame(width: 175).disabled(model.busy)
                }
            }
            if model.active && model.hasChanges {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Your blocklist has unapplied changes.").font(.system(size: 12)).foregroundStyle(secondary)
                    Button { Task { await model.start(update: true) } } label: {
                        Text("Apply changes").frame(maxWidth: .infinity).padding(.vertical, 3)
                    }.disabled(model.websites.isEmpty || model.busy)
                }
            }
            if let error = model.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12)).foregroundStyle(.red).lineLimit(3).help(error)
                    .accessibilityLabel("Error: \(error)")
            }
            Button { Task { if model.active { await model.stop() } else { await model.start() } } } label: {
                HStack(spacing: 8) {
                    if model.busy { ProgressView().controlSize(.small) }
                    Text(model.busy ? "Waiting for permission…" : model.active ? "Stop blocking" : "Start blocking")
                        .font(.system(size: 13, weight: .medium)).lineLimit(1)
                }.frame(maxWidth: .infinity).frame(height: 34)
            }.buttonStyle(PrimaryButtonStyle(fill: accent)).disabled(model.busy || (!model.active && model.websites.isEmpty))
            Text(model.websites.isEmpty && !model.active ? "Add a website to start." : "macOS asks for administrator permission.")
                .font(.system(size: 11)).foregroundStyle(secondary).frame(maxWidth: .infinity)
        }
    }

    private var settings: some View {
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
                Text("Website blocking").font(.system(size: 12, weight: .semibold))
                Text(verbatim: "Each domain includes its www version. Add other subdomains separately.")
                    .font(.system(size: 12)).foregroundStyle(secondary).fixedSize(horizontal: false, vertical: true)
                Text("Uses your Mac’s hosts file. Restart your browser if a blocked website stays open. Secure DNS, VPNs, and proxies can bypass the block.")
                    .font(.system(size: 12)).foregroundStyle(secondary).fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Always on").font(.system(size: 12, weight: .semibold))
                Text("Stays active after quitting or restarting your Mac. Use Stop blocking to turn it off.")
                    .font(.system(size: 12)).foregroundStyle(secondary).fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Timed sessions").font(.system(size: 12, weight: .semibold))
                Text("End automatically, even with Still closed. Allow up to 15 seconds after the deadline, or after your Mac wakes from sleep.")
                    .font(.system(size: 12)).foregroundStyle(secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var footer: some View {
        HStack {
            if model.isDemo {
                Text("Preview · no system changes").font(.system(size: 10)).foregroundStyle(secondary)
            } else if model.active {
                Text("Blocking continues after quitting.").font(.system(size: 10)).foregroundStyle(secondary)
            }
            Spacer()
            Button("Quit") { NSApplication.shared.terminate(nil) }.buttonStyle(.borderless)
                .font(.system(size: 11)).disabled(model.busy)
                .help("Quitting leaves your active block in place. Timed blocks still expire automatically.")
        }.padding(.horizontal, 18).padding(.vertical, 10)
    }
}

private enum BlockDuration: Int, CaseIterable {
    case always = 0, minutes25 = 25, minutes50 = 50, minutes90 = 90
    var label: String { self == .always ? "Always on" : "\(rawValue) minutes" }
}

private struct PrimaryButtonStyle: ButtonStyle {
    let fill: Color
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 12).padding(.vertical, 3)
            .foregroundStyle(enabled ? (colorScheme == .dark ? Color(nsColor: .windowBackgroundColor) : Color(nsColor: .textBackgroundColor)) : Color.secondary)
            .background(enabled ? fill : Color(nsColor: .quaternaryLabelColor), in: RoundedRectangle(cornerRadius: 8))
            .opacity(configuration.isPressed ? 0.8 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 8))
    }
}
