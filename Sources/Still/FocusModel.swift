import Foundation
import SwiftUI
import BlockerCore

enum FocusPreset: Int, CaseIterable {
    case regular = 25, deep = 50
    var label: String { self == .regular ? "25 / 5" : "50 / 10" }
    var breakMinutes: Int { self == .regular ? 5 : 10 }
}

@MainActor
final class FocusModel: ObservableObject {
    @Published var groupID = BlockGroup.legacyID
    @Published var preset: FocusPreset = .regular
    @Published var rounds = 4
    @Published private(set) var session: FocusSession?
    @Published private(set) var garden = FocusGarden()
    @Published var error: String?
    private let demo: Bool
    private let defaults: UserDefaults
    private let directory = URL(fileURLWithPath: "/Library/Application Support/Still", isDirectory: true)

    init(demo: Bool, defaults: UserDefaults) {
        self.demo = demo; self.defaults = defaults
        groupID = defaults.string(forKey: "focusGroupID").flatMap(UUID.init(uuidString:)) ?? BlockGroup.legacyID
        preset = FocusPreset(rawValue: defaults.integer(forKey: "focusPreset")) ?? .regular
        rounds = [1, 2, 4].contains(defaults.integer(forKey: "focusRounds")) ? defaults.integer(forKey: "focusRounds") : 4
    }

    func refresh(groups: [BlockGroup]) {
        if !demo {
            session = (try? Data(contentsOf: directory.appendingPathComponent("focus.json")))
                .flatMap { try? JSONDecoder().decode(FocusSession.self, from: $0).validated() }
            garden = (try? Data(contentsOf: directory.appendingPathComponent("garden-\(getuid()).json")))
                .flatMap { try? JSONDecoder().decode(FocusGarden.self, from: $0) } ?? FocusGarden()
        }
        if let session { groupID = session.plan.group.id }
        else if !groups.contains(where: { $0.id == groupID }) || (groupID == BlockGroup.legacyID && !defaults.bool(forKey: "focusGroupChosen")) {
            groupID = groups.first { $0.name.localizedCaseInsensitiveCompare("Study") == .orderedSame }?.id ?? groups[0].id
        }
    }

    func savePreferences() {
        guard !demo else { return }
        defaults.set(groupID.uuidString, forKey: "focusGroupID")
        defaults.set(true, forKey: "focusGroupChosen")
        defaults.set(preset.rawValue, forKey: "focusPreset")
        defaults.set(rounds, forKey: "focusRounds")
    }

    var visibleGarden: FocusGarden {
        var result = garden
        if let session, session.plan.ownerID == getuid() { result.merge(session.records) }
        return result
    }

    var suggestedPreset: FocusPreset? {
        let recent = Array(garden.records.suffix(3))
        if recent.count == 3, recent.allSatisfy({ $0.completed && $0.targetSeconds <= 1500 }), preset == .regular { return .deep }
        if let last = recent.last, !last.completed, last.seconds >= 60, preset == .deep { return .regular }
        return nil
    }

    func beginDemo(_ plan: FocusPlan, at date: Date = Date(), uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) throws {
        session = try FocusSession(plan: plan, startedAt: date, uptime: uptime)
    }

    func endDemo() {
        if let session { garden.merge(session.records) }
        session = nil
    }

    func advanceDemo(configuration: BlockConfiguration?, now: Date, uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) -> BlockConfiguration? {
        guard var session else { return try? configuration?.removingExpiredGroups(at: now) }
        let protected = configuration?.activeGroups.contains { $0.id == session.plan.group.id } ?? false
        session.advance(to: now, uptime: uptime, isProtected: protected)
        let phase = session.phase(at: now)
        var groups = configuration?.activeGroups.filter { $0.id != session.plan.group.id && !$0.isExpired(at: now) } ?? []
        if phase.kind == .focus {
            groups.append(ActiveBlockGroup(id: session.plan.group.id, name: session.plan.group.name,
                                           domains: session.plan.group.domains, expiresAt: phase.endsAt))
        }
        if phase.kind == .finished { garden.merge(session.records); self.session = nil }
        else { self.session = session }
        return groups.isEmpty ? nil : try? BlockConfiguration(groups: groups)
    }
}
