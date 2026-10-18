import Foundation

public struct FocusPlan: Codable, Equatable {
    public let id: UUID
    public let group: ActiveBlockGroup
    public let ownerID: UInt32
    public let focusMinutes: Int
    public let breakMinutes: Int
    public let rounds: Int

    public init(id: UUID = UUID(), group: ActiveBlockGroup, ownerID: UInt32,
                focusMinutes: Int = 25, breakMinutes: Int = 5, rounds: Int = 4) {
        self.id = id; self.group = group; self.ownerID = ownerID
        self.focusMinutes = focusMinutes; self.breakMinutes = breakMinutes; self.rounds = rounds
    }

    public func validated() throws -> FocusPlan {
        _ = try BlockConfiguration(groups: [group])
        guard ownerID > 0, group.expiresAt == nil, [1, 2, 4].contains(rounds),
              (focusMinutes == 25 && breakMinutes == 5) || (focusMinutes == 50 && breakMinutes == 10)
        else { throw FocusError.invalidPlan }
        return self
    }

    public func restMinutes(after round: Int) -> Int {
        rounds == 4 && round == 3 ? (focusMinutes == 50 ? 20 : 15) : breakMinutes
    }

    public var totalMinutes: Int { (0..<rounds).reduce(0) { $0 + focusMinutes + restMinutes(after: $1) } }
}

public struct FocusPhase: Equatable {
    public enum Kind: String { case focus, rest, finished }
    public let kind: Kind
    public let round: Int
    public let startedAt: Date
    public let endsAt: Date
}

public struct FocusSession: Codable, Equatable {
    public let plan: FocusPlan
    public let startedAt: Date
    public private(set) var observedAt: Date
    public private(set) var observedUptime: TimeInterval
    public private(set) var focusSeconds: [TimeInterval]

    public init(plan: FocusPlan, startedAt: Date = Date(), uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) throws {
        self.plan = try plan.validated(); self.startedAt = startedAt
        observedAt = startedAt; observedUptime = uptime
        focusSeconds = Array(repeating: 0, count: plan.rounds)
    }

    public func phase(at date: Date) -> FocusPhase {
        var start = startedAt
        for round in 0..<plan.rounds {
            let focusEnd = start.addingTimeInterval(Double(plan.focusMinutes * 60))
            if date < focusEnd { return FocusPhase(kind: .focus, round: round, startedAt: start, endsAt: focusEnd) }
            let restEnd = focusEnd.addingTimeInterval(Double(plan.restMinutes(after: round) * 60))
            if date < restEnd { return FocusPhase(kind: .rest, round: round, startedAt: focusEnd, endsAt: restEnd) }
            start = restEnd
        }
        return FocusPhase(kind: .finished, round: plan.rounds - 1, startedAt: start, endsAt: start)
    }

    /// Credit only short observed intervals with matching awake and wall clocks.
    /// Sleep, restart, clock jumps and gaps in enforcement never earn focus time.
    public mutating func advance(to date: Date, uptime: TimeInterval, isProtected: Bool = true) {
        let elapsed = date.timeIntervalSince(observedAt)
        let awake = uptime - observedUptime
        defer { observedAt = max(date, startedAt); observedUptime = uptime }
        guard isProtected, elapsed > 0, elapsed <= 10, awake >= 0, abs(awake - elapsed) < 1 else { return }
        var start = startedAt
        for round in 0..<plan.rounds {
            let end = start.addingTimeInterval(Double(plan.focusMinutes * 60))
            let overlap = min(date, end).timeIntervalSince(max(observedAt, start))
            if overlap > 0 { focusSeconds[round] = min(Double(plan.focusMinutes * 60), focusSeconds[round] + overlap) }
            start = end.addingTimeInterval(Double(plan.restMinutes(after: round) * 60))
        }
    }

    public func validated() throws -> FocusSession {
        _ = try plan.validated()
        guard focusSeconds.count == plan.rounds, focusSeconds.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= Double(plan.focusMinutes * 60) }),
              observedUptime.isFinite, observedAt >= startedAt else { throw FocusError.invalidPlan }
        return self
    }

    public var records: [FocusRecord] {
        var start = startedAt
        return (0..<plan.rounds).compactMap { round in
            defer { start = start.addingTimeInterval(Double((plan.focusMinutes + plan.restMinutes(after: round)) * 60)) }
            guard focusSeconds[round] >= 1 else { return nil }
            return FocusRecord(id: "\(plan.id.uuidString):\(round)", date: start,
                               seconds: focusSeconds[round], targetSeconds: Double(plan.focusMinutes * 60))
        }
    }
}

public struct FocusRecord: Codable, Equatable, Identifiable {
    public let id: String
    public let date: Date
    public let seconds: TimeInterval
    public let targetSeconds: TimeInterval
    public var completed: Bool { seconds >= targetSeconds - 1 }
}

public struct FocusGarden: Codable, Equatable {
    public private(set) var records: [FocusRecord] = []
    public init() {}
    public mutating func merge(_ incoming: [FocusRecord]) {
        for record in incoming {
            if let index = records.firstIndex(where: { $0.id == record.id }) {
                if record.seconds >= records[index].seconds { records[index] = record }
            }
            else { records.append(record) }
        }
        records.sort { $0.date < $1.date }
    }
    public var focusSeconds: TimeInterval { records.reduce(0) { $0 + $1.seconds } }
    public var treeCount: Int { Int(focusSeconds / 1500) }
    public var saplingProgress: Double { focusSeconds.truncatingRemainder(dividingBy: 1500) / 1500 }
    public func seconds(on date: Date, calendar: Calendar = .current) -> TimeInterval {
        records.filter { calendar.isDate($0.date, inSameDayAs: date) }.reduce(0) { $0 + $1.seconds }
    }
}

public enum FocusError: LocalizedError {
    case invalidPlan, alreadyRunning, notRunning
    public var errorDescription: String? {
        switch self {
        case .invalidPlan: return "Choose a 25/5 or 50/10 timer with 1, 2, or 4 rounds and a nonempty group."
        case .alreadyRunning: return "End the current focus cycle before starting another."
        case .notRunning: return "This focus cycle has already ended."
        }
    }
}
