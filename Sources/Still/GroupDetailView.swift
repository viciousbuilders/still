import SwiftUI
import BlockerCore

struct GroupDetailView: View {
    @ObservedObject var model: AppModel
    let back: () -> Void
    let rename: () -> Void
    @Environment(\.colorScheme) private var scheme
    @FocusState private var websiteFieldFocused: Bool
    private var secondary: Color { StillStyle.secondary(scheme) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Button(action: back) { Image(systemName: "chevron.left").frame(width: 24, height: 28) }
                    .buttonStyle(.borderless).accessibilityLabel("Back to groups")
                Text(model.selectedGroup.name).font(.system(size: 17, weight: .semibold)).lineLimit(1).help(model.selectedGroup.name)
                Spacer()
                Button("Rename", action: rename).controlSize(.small)
            }.padding(.horizontal, 16).padding(.top, 18)
            if model.groupIsManagedByTimer(model.selectedGroupID) {
                Label("The focus timer controls this group. Edits apply next cycle.", systemImage: "timer")
                    .font(.system(size: 11)).foregroundStyle(secondary).fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 20).padding(.top, 10)
            }
            websiteEditor
            Divider()
            blockControls.padding(20)
        }
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
                if model.selectedGroupActive {
                    Text(model.selectedActiveGroup?.expiresAt == nil ? "Always on" : "Time remaining")
                        .font(.system(size: 12, weight: .medium))
                    Spacer()
                    if model.selectedActiveGroup?.expiresAt != nil {
                        TimelineView(.periodic(from: .now, by: 1)) {
                            Text(model.statusDetail(at: $0.date))
                        }.font(.system(size: 12)).monospacedDigit().foregroundStyle(secondary)
                    } else {
                        Text(model.statusDetail()).font(.system(size: 12)).foregroundStyle(secondary)
                    }
                } else {
                    Text("Duration").font(.system(size: 12, weight: .medium))
                    Spacer()
                    Picker("Blocking duration", selection: durationSelection) {
                        ForEach(BlockDuration.allCases, id: \.self) { Text($0.label).tag($0) }
                    }.labelsHidden().frame(width: 175).disabled(model.busy)
                }
            }
            if model.selectedGroupActive && model.hasChanges && !model.groupIsManagedByTimer(model.selectedGroupID) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(model.needsFirewallUpgrade ? "Apply changes to upgrade your active block." : "This group has unapplied changes.").font(.system(size: 12)).foregroundStyle(secondary)
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
            Button { Task { if model.selectedGroupActive { await model.stop() } else { await model.start() } } } label: {
                HStack(spacing: 8) {
                    if model.busy { ProgressView().controlSize(.small) }
                    Text(model.busy ? "Waiting for permission…" : model.groupIsManagedByTimer(model.selectedGroupID) ? "Controlled by focus timer" : model.selectedGroupActive ? "Unblock group" : "Block group")
                        .font(.system(size: 13, weight: .medium)).lineLimit(1)
                }.frame(maxWidth: .infinity).frame(height: 34)
            }.buttonStyle(StillPrimaryButton()).disabled(model.busy || model.groupIsManagedByTimer(model.selectedGroupID) || (!model.selectedGroupActive && model.websites.isEmpty))
                .accessibilityLabel(model.selectedGroupActive ? "Unblock \(model.selectedGroup.name) group" : "Block \(model.selectedGroup.name) group")
            Text(model.websites.isEmpty && !model.selectedGroupActive ? "Add a website to start." : "Touch ID or password · admin setup on first use")
                .font(.system(size: 11)).foregroundStyle(secondary).frame(maxWidth: .infinity)
        }
    }

}

private enum BlockDuration: Int, CaseIterable {
    case always = 0, minutes25 = 25, minutes50 = 50, minutes90 = 90
    var label: String { self == .always ? "Always on" : "\(rawValue) minutes" }
}
