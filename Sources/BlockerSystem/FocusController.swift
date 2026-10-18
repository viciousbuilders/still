import Foundation
import BlockerCore

extension SystemController {
    public func startFocus(_ plan: FocusPlan, helperSource: URL, now suppliedDate: Date? = nil,
                           uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) throws {
        let plan = try plan.validated()
        let now = suppliedDate ?? Date()
        try withLock {
            guard try readFocusLocked() == nil else { throw FocusError.alreadyRunning }
            let session = try FocusSession(plan: plan, startedAt: now, uptime: uptime)
            let previous = try currentConfigurationLocked()
            if previous == nil, HostsFile.containsBlock(try String(contentsOf: paths.hosts, encoding: .utf8)) {
                throw SystemError.commandFailed("Unblock the existing block before starting a focus cycle. Its saved groups could not be read.")
            }
            let others = previous?.activeGroups.filter { $0.id != plan.group.id && !$0.isExpired(at: now) } ?? []
            let phase = session.phase(at: now)
            let group = ActiveBlockGroup(id: plan.group.id, name: plan.group.name, domains: plan.group.domains, expiresAt: phase.endsAt)
            try write(try JSONEncoder().encode(session), to: paths.focus, mode: 0o644)
            do {
                try applyLocked(BlockConfiguration(groups: others + [group], startedAt: now),
                                helperSource: helperSource, now: now, reloadScheduler: true)
                // DNS and firewall setup can take time. Start the real timer
                // after enforcement is installed, not while permission/setup runs.
                let installedAt = suppliedDate ?? Date()
                let installed = try FocusSession(plan: plan, startedAt: installedAt,
                                                  uptime: suppliedDate == nil ? ProcessInfo.processInfo.systemUptime : uptime)
                let applied = ActiveBlockGroup(id: group.id, name: group.name, domains: group.domains,
                                               expiresAt: installed.phase(at: installedAt).endsAt)
                try write(try JSONEncoder().encode(BlockConfiguration(groups: others + [applied], startedAt: installedAt)), to: paths.state, mode: 0o644)
                try write(try JSONEncoder().encode(installed), to: paths.focus, mode: 0o644)
            } catch {
                try? removeIfPresent(paths.focus)
                let failure = error
                do {
                    if let previous { try applyLocked(previous, helperSource: helperSource, now: now) }
                    else { try removeBlocksLocked(keepScheduler: false) }
                } catch {
                    throw SystemError.commandFailed("\(failure.localizedDescription) Could not restore the previous block: \(error.localizedDescription)")
                }
                throw failure
            }
        }
    }

    public func endFocus(sessionID: UUID, now: Date = Date(),
                         uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) throws {
        try withLock {
            guard var session = try readFocusLocked(), session.plan.id == sessionID else { throw FocusError.notRunning }
            session.advance(to: now, uptime: uptime)
            let others = try currentConfigurationLocked()?.activeGroups.filter {
                $0.id != session.plan.group.id && !$0.isExpired(at: now)
            } ?? []
            // Commit the block change first. A failed stop keeps its schedule.
            if !others.isEmpty { try applyLocked(BlockConfiguration(groups: others), helperSource: paths.helper, now: now) }
            else { try removeBlocksLocked(keepScheduler: true) }
            try saveGardenLocked(session)
            try removeIfPresent(paths.focus)
            if others.isEmpty { try stopScheduler() }
        }
    }

    /// Returns true when a focus schedule handled this tick, including final cleanup.
    func advanceFocusLocked(now: Date, uptime: TimeInterval) throws -> Bool {
        guard var session = try readFocusLocked() else { return false }
        let current = try currentConfigurationLocked()
        let lastObserved = session.observedAt
        let previousPhase = session.phase(at: session.observedAt)
        // An observed interval counts only while the planned group was applied.
        if current?.activeGroups.contains(where: { $0.id == session.plan.group.id && $0.domains == session.plan.group.domains }) == true {
            session.advance(to: now, uptime: uptime)
        } else { session.advance(to: now, uptime: uptime, isProtected: false) }
        let phase = session.phase(at: now)
        let others = current?.activeGroups.filter { $0.id != session.plan.group.id && !$0.isExpired(at: now) } ?? []
        var groups = others
        if phase.kind == .focus {
            groups.append(ActiveBlockGroup(id: session.plan.group.id, name: session.plan.group.name,
                                           domains: session.plan.group.domains, expiresAt: phase.endsAt))
        }
        let desired = groups.isEmpty ? nil : try BlockConfiguration(groups: groups, startedAt: current?.startedAt ?? now)
        if let desired {
            if current != desired { try applyLocked(desired, helperSource: paths.helper, now: now) }
            else { try maintainFirewall(domains: desired.domains, now: now) }
        } else if current != nil { try removeBlocksLocked(keepScheduler: true) }

        if phase != previousPhase || phase.kind == .finished { try saveGardenLocked(session) }
        if phase.kind == .finished {
            try removeIfPresent(paths.focus)
            if desired == nil { try stopScheduler() }
        } else if phase != previousPhase || now.timeIntervalSince(lastObserved) >= 5 || now < lastObserved {
            try write(try JSONEncoder().encode(session), to: paths.focus, mode: 0o644)
        }
        return true
    }

    func archiveAndRemoveFocusLocked() throws {
        // Explicit Unblock all is also the recovery path for damaged timer data.
        if let session = try? readFocusLocked() { try? saveGardenLocked(session) }
        try removeIfPresent(paths.focus)
    }

    private func currentConfigurationLocked() throws -> BlockConfiguration? {
        guard let data = try readStateData() else { return nil }
        return try JSONDecoder().decode(BlockConfiguration.self, from: data).validated()
    }

    private func readFocusLocked() throws -> FocusSession? {
        try checkPath(paths.focus)
        guard FileManager.default.fileExists(atPath: paths.focus.path) else { return nil }
        return try JSONDecoder().decode(FocusSession.self, from: Data(contentsOf: paths.focus)).validated()
    }

    private func saveGardenLocked(_ session: FocusSession) throws {
        let url = paths.garden(userID: session.plan.ownerID)
        try checkPath(url)
        var garden = FileManager.default.fileExists(atPath: url.path)
            ? try JSONDecoder().decode(FocusGarden.self, from: Data(contentsOf: url)) : FocusGarden()
        garden.merge(session.records)
        try write(try JSONEncoder().encode(garden), to: url, mode: 0o644)
    }
}
