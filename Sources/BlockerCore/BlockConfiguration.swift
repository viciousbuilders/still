import Foundation

public struct BlockConfiguration: Codable, Equatable {
    public let domains: [String]
    public let startedAt: Date
    public let expiresAt: Date?
    public let groups: [ActiveBlockGroup]?

    public init(domains: [String], startedAt: Date = Date(), expiresAt: Date? = nil) throws {
        guard !domains.isEmpty, domains.count <= 500 else { throw BlockError.emptyList }
        for domain in domains { try Domain.validate(domain) }
        self.domains = Array(Set(domains)).sorted()
        self.startedAt = startedAt
        self.expiresAt = expiresAt
        self.groups = nil
    }

    public init(groups: [ActiveBlockGroup], startedAt: Date = Date()) throws {
        guard !groups.isEmpty, groups.count <= 50, Set(groups.map(\.id)).count == groups.count else { throw BlockError.invalidGroup }
        guard groups.reduce(0, { $0 + $1.domains.count }) <= 500 else { throw BlockError.emptyList }
        for group in groups {
            _ = try BlockGroup(id: group.id, name: group.name, domains: group.domains).validated()
            guard !group.domains.isEmpty else { throw BlockError.emptyList }
        }
        let domains = Array(Set(groups.flatMap(\.domains))).sorted()
        guard domains.count <= 500 else { throw BlockError.emptyList }
        self.domains = domains
        self.groups = groups
        self.startedAt = startedAt
        self.expiresAt = groups.contains(where: { $0.expiresAt == nil }) ? nil : groups.compactMap(\.expiresAt).max()
    }

    public func isExpired(at date: Date) -> Bool { expiresAt.map { date >= $0 } ?? false }

    public func validated() throws -> BlockConfiguration {
        if let groups {
            let result = try BlockConfiguration(groups: groups, startedAt: startedAt)
            guard domains == result.domains, expiresAt == result.expiresAt else { throw BlockError.invalidGroup }
            return result
        }
        return try BlockConfiguration(domains: domains, startedAt: startedAt, expiresAt: expiresAt)
    }

    public var activeGroups: [ActiveBlockGroup] {
        groups ?? [ActiveBlockGroup(id: BlockGroup.legacyID, name: "Websites", domains: domains, expiresAt: expiresAt)]
    }

    public func removingExpiredGroups(at date: Date) throws -> BlockConfiguration? {
        guard let groups else { return isExpired(at: date) ? nil : self }
        let remaining = groups.filter { !$0.isExpired(at: date) }
        return remaining.isEmpty ? nil : try BlockConfiguration(groups: remaining, startedAt: startedAt)
    }
}

public enum BlockError: LocalizedError {
    case emptyList, damagedHostsSection, invalidExpiry, invalidGroup
    public var errorDescription: String? {
        switch self {
        case .emptyList: return "Add between 1 and 500 websites before starting a block."
        case .damagedHostsSection: return "Still’s hosts-file section is damaged. No changes were made. See the recovery instructions in README.md."
        case .invalidExpiry: return "The session end time must be in the future."
        case .invalidGroup: return "Use a group name of 1-40 characters, up to 50 groups, and a supported duration."
        }
    }
}
