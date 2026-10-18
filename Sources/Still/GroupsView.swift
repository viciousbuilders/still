import SwiftUI
import BlockerCore

struct GroupsView: View {
    @ObservedObject var model: AppModel
    @State private var showingDetail = false
    @State private var editingName = false
    @State private var creating = false
    @State private var name = ""
    @State private var deleteID: UUID?
    @FocusState private var nameFocused: Bool
    @Environment(\.colorScheme) private var scheme
    private var secondary: Color { StillStyle.secondary(scheme) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if editingName { nameEditor.padding(20); Divider() }
            if showingDetail {
                GroupDetailView(model: model, back: { showingDetail = false }, rename: { beginName(creating: false) })
                    .disabled(editingName || model.busy)
            } else {
                overview.disabled(editingName)
            }
        }.confirmationDialog("Delete this group and its website list?", isPresented: Binding(
            get: { deleteID != nil }, set: { if !$0 { deleteID = nil } }
        )) {
            Button("Delete group", role: .destructive) {
                if let id = deleteID { model.selectGroup(id); model.deleteSelectedGroup() }
                deleteID = nil
            }
            Button("Cancel", role: .cancel) { deleteID = nil }
        }
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Groups").font(.system(size: 20, weight: .semibold))
                }
                Spacer()
                Button { beginName(creating: true) } label: { Image(systemName: "plus").frame(width: 28, height: 28) }
                    .buttonStyle(.bordered).accessibilityLabel("New group").help("New group")
                    .disabled(model.busy || model.groups.count >= 50)
            }
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(model.groups) { group in groupRow(group) }
                }.padding(.vertical, 2)
            }
            if let error = model.error { InlineError(message: error) }
            Text("Shared websites stay blocked until all their groups are off.")
                .font(.system(size: 11)).foregroundStyle(secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(20)
    }

    private func groupRow(_ group: BlockGroup) -> some View {
        let active = model.groupIsActive(group.id)
        let managed = model.groupIsManagedByTimer(group.id)
        return HStack(spacing: 12) {
            Button {
                model.selectGroup(group.id); showingDetail = true
            } label: {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(group.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(.primary).lineLimit(1)
                        Text("\(group.domains.count) websites · \(managed ? (active ? "Focus" : "Break") : active ? "Blocked" : "Open")")
                            .font(.system(size: 11)).foregroundStyle(secondary)
                    }
                    Spacer(minLength: 0)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("Edit \(group.name) group")
            Toggle("Block \(group.name)", isOn: Binding(get: { active }, set: { enabled in
                model.selectGroup(group.id)
                Task { if enabled { await model.start() } else { await model.stop() } }
            })).labelsHidden().toggleStyle(.switch).controlSize(.mini)
                .disabled(model.busy || managed || (!active && group.domains.isEmpty))
                .accessibilityLabel("Block \(group.name) group")
            Menu {
                Button("Rename…") { model.selectGroup(group.id); beginName(creating: false) }
                Button("Delete…", role: .destructive) { deleteID = group.id }
                    .disabled(active || managed || model.groups.count == 1)
            } label: { Image(systemName: "ellipsis").frame(width: 16, height: 24) }
                .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Manage \(group.name)")
        }.padding(14).background(StillStyle.surface, in: RoundedRectangle(cornerRadius: 12))
            .disabled(model.busy)
    }

    private var nameEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(creating ? "New group" : "Rename group").font(.system(size: 13, weight: .semibold))
            TextField("Group name", text: $name).textFieldStyle(.roundedBorder).focused($nameFocused)
                .accessibilityLabel("Group name").onSubmit { saveName() }
                .onChange(of: name) { _ in model.groupError = nil }
            if let error = model.groupError { InlineError(message: error) }
            HStack {
                Spacer()
                Button("Cancel") { editingName = false; model.groupError = nil }
                Button(creating ? "Create group" : "Save name") { saveName() }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }
    private func beginName(creating: Bool) {
        self.creating = creating; name = creating ? "" : model.selectedGroup.name
        model.groupError = nil; editingName = true; nameFocused = true
    }
    private func saveName() {
        if model.saveGroup(name: name, creating: creating) { editingName = false; showingDetail = true }
    }
}
