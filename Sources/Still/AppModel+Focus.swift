import Foundation
import BlockerCore

extension AppModel {
    func startFocus() async {
        guard !busy, focus.session == nil, let group = groups.first(where: { $0.id == focus.groupID }) else { return }
        busy = true; focus.error = nil
        defer { busy = false; refresh() }
        do {
            let plan = try FocusPlan(group: ActiveBlockGroup(id: group.id, name: group.name, domains: group.domains),
                                     ownerID: getuid(), focusMinutes: focus.preset.rawValue,
                                     breakMinutes: focus.preset.breakMinutes, rounds: focus.rounds).validated()
            if isDemo { try focus.beginDemo(plan) }
            else { try await TouchIDAuthorization.perform(helper: helperURL(), action: .startFocus, focusPlan: plan) }
            focus.savePreferences()
        } catch { focus.error = error.localizedDescription }
    }

    func endFocus() async {
        guard !busy, let session = focus.session else { return }
        busy = true; focus.error = nil
        defer { busy = false; refresh() }
        do {
            if isDemo {
                let others = configuration?.activeGroups.filter { $0.id != session.plan.group.id } ?? []
                configuration = others.isEmpty ? nil : try BlockConfiguration(groups: others)
                focus.endDemo()
            } else { try await TouchIDAuthorization.perform(helper: helperURL(), action: .endFocus, sessionID: session.plan.id) }
        } catch { focus.error = error.localizedDescription }
    }

    func groupIsManagedByTimer(_ id: UUID) -> Bool { focus.session?.plan.group.id == id }
}
