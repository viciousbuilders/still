import SwiftUI
import BlockerCore

struct FocusView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var focus: FocusModel
    @Environment(\.colorScheme) private var scheme
    private var accent: Color { StillStyle.accent(scheme) }
    private var secondary: Color { StillStyle.secondary(scheme) }
    private var phase: FocusPhase? { focus.session?.phase(at: model.now) }
    private var selected: BlockGroup? { model.groups.first { $0.id == focus.groupID } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                timer
                if let session = focus.session { runningCycle(session) }
                else if model.canCreateStudySetup { studySetup }
                else { setup }
                if let error = focus.error { InlineError(message: error) }
                gardenProgress
            }.padding(20)
        }
    }

    private var studySetup: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Split your blocklist").font(.system(size: 15, weight: .semibold))
            VStack(alignment: .leading, spacing: 12) {
                splitPreview("Always blocked", domains: model.studySetupPreview.always)
                Divider()
                splitPreview("Study", domains: model.studySetupPreview.study)
            }.padding(14).background(StillStyle.surface, in: RoundedRectangle(cornerRadius: 12))
            Button { Task { await model.createStudySetup() } } label: {
                Label("Create these two groups", systemImage: "square.stack")
            }.buttonStyle(StillPrimaryButton()).disabled(model.busy)
            Text(model.active ? "Study opens now. Your other websites stay blocked." : "After creating the groups, enable Always blocked in Groups.")
                .font(.system(size: 11)).foregroundStyle(secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func splitPreview(_ name: String, domains: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(name).font(.system(size: 12, weight: .semibold))
            Text(domains.joined(separator: ", ")).font(.system(size: 11)).foregroundStyle(secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var timer: some View {
        HStack(alignment: .center, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text(phase?.kind == .rest ? "Break" : phase?.kind == .finished ? "Complete" : "Focus")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(secondary)
                Text(timeRemaining).font(.system(size: 54, weight: .light, design: .rounded)).monospacedDigit()
                    .contentTransition(.identity).accessibilityLabel(focus.session == nil ? "\(focus.preset.rawValue) minute focus duration" : "\(timeRemaining) remaining")
                if focus.session != nil {
                    Text(phaseDescription).font(.system(size: 12)).foregroundStyle(secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            TreeProgressView(progress: focus.visibleGarden.saplingProgress)
                .frame(width: 82, height: 100)
        }.padding(20).frame(maxWidth: .infinity, minHeight: 164, alignment: .leading)
            .background(StillStyle.surface, in: RoundedRectangle(cornerRadius: 12))
    }

    private var setup: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Block during focus").font(.system(size: 12, weight: .medium))
                Spacer()
                Picker("Focus group", selection: $focus.groupID) {
                    ForEach(model.groups) { Text($0.name).tag($0.id) }
                }.labelsHidden().frame(maxWidth: 170).accessibilityLabel("Focus group")
            }
            HStack {
                Text("Focus / break").font(.system(size: 12, weight: .medium))
                Spacer()
                Picker("Focus and break duration", selection: $focus.preset) {
                    ForEach(FocusPreset.allCases, id: \.self) { Text($0.label).tag($0) }
                }.pickerStyle(.segmented).labelsHidden().frame(width: 170)
            }
            HStack {
                Text("Rounds").font(.system(size: 12, weight: .medium))
                Spacer()
                Picker("Number of rounds", selection: $focus.rounds) {
                    ForEach([1, 2, 4], id: \.self) { Text("\($0)").tag($0) }
                }.pickerStyle(.segmented).labelsHidden().frame(width: 170)
                    .help("Four rounds end with a \(focus.preset == .regular ? 15 : 20)-minute break.")
            }
            if let suggestion = focus.suggestedPreset {
                HStack(alignment: .top, spacing: 10) {
                    Text(suggestion == .deep ? "Three blocks completed. Try 50/10?" : "Try 25/5 for your next cycle?")
                        .font(.system(size: 12)).foregroundStyle(secondary)
                    Button(suggestion.label) { focus.preset = suggestion; focus.savePreferences() }.controlSize(.small)
                }
            }
            Button { Task { await model.startFocus() } } label: {
                if model.busy { ProgressView().controlSize(.small) }
                else { Label("Start focus cycle", systemImage: "touchid") }
            }.buttonStyle(StillPrimaryButton()).disabled(model.busy || selected?.domains.isEmpty != false)
            Text(selected?.domains.isEmpty != false ? "Add websites to this group in Groups first." : "One approval for focus and breaks.")
                .font(.system(size: 11)).foregroundStyle(secondary).fixedSize(horizontal: false, vertical: true)
            overlapNote
        }.disabled(model.busy)
            .onChange(of: focus.groupID) { _ in focus.savePreferences() }
            .onChange(of: focus.preset) { _ in focus.savePreferences() }
            .onChange(of: focus.rounds) { _ in focus.savePreferences() }
    }

    private func runningCycle(_ session: FocusSession) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Round \((phase?.round ?? 0) + 1) of \(session.plan.rounds)").font(.system(size: 13, weight: .semibold))
            }
            Text(phase?.kind == .rest ? (phase?.round == session.plan.rounds - 1 ? "Your cycle ends after this break. \(session.plan.group.name) stays open." : "\(session.plan.group.name) blocks again when this break ends.") : "\(session.plan.group.name) opens automatically when this focus ends.")
                .font(.system(size: 12)).foregroundStyle(secondary).fixedSize(horizontal: false, vertical: true)
            overlapNote
            Button { Task { await model.endFocus() } } label: {
                if model.busy { ProgressView().controlSize(.small) }
                else { Text("End cycle early") }
            }.disabled(model.busy).controlSize(.large)
        }
    }

    @ViewBuilder private var overlapNote: some View {
        let group = focus.session?.plan.group
        let domains = Set(group?.domains ?? selected?.domains ?? [])
        let overlap = model.configuration?.activeGroups.contains { $0.id != focus.groupID && !domains.isDisjoint(with: $0.domains) } ?? false
        if overlap {
            Text("Some websites are also in another blocked group. Those stay blocked during breaks.")
                .font(.system(size: 11)).foregroundStyle(secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var gardenProgress: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Next tree").font(.system(size: 12, weight: .medium))
                Spacer()
                Text("\(Int(focus.visibleGarden.focusSeconds.truncatingRemainder(dividingBy: 1500) / 60)) / 25 min")
                    .font(.system(size: 11)).monospacedDigit().foregroundStyle(secondary)
            }
            ProgressView(value: focus.visibleGarden.saplingProgress).tint(accent)
                .accessibilityLabel("Progress toward next tree")
        }
    }

    private var timeRemaining: String {
        let seconds = phase.map { max(0, Int(ceil($0.endsAt.timeIntervalSince(model.now)))) } ?? focus.preset.rawValue * 60
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
    private var phaseDescription: String {
        guard let session = focus.session, let phase else { return "\(selected?.name ?? "This group") blocks during focus." }
        let blocked = model.groupIsActive(session.plan.group.id)
        switch phase.kind {
        case .focus: return blocked ? "\(session.plan.group.name) is blocked" : "Applying protection…"
        case .rest: return blocked ? "Opening \(session.plan.group.name)…" : "\(session.plan.group.name) is open for your break"
        case .finished: return "Finishing your cycle…"
        }
    }
}
