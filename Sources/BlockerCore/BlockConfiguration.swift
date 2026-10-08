import Foundation

public struct BlockConfiguration: Codable, Equatable {
    public let domains: [String]
    public let startedAt: Date
    public let expiresAt: Date?

    public init(domains: [String], startedAt: Date = Date(), expiresAt: Date? = nil) throws {
        guard !domains.isEmpty, domains.count <= 500 else { throw BlockError.emptyList }
        for domain in domains { try Domain.validate(domain) }
        self.domains = Array(Set(domains)).sorted()
        self.startedAt = startedAt
        self.expiresAt = expiresAt
    }

    public func isExpired(at date: Date) -> Bool { expiresAt.map { date >= $0 } ?? false }

    public func validated() throws -> BlockConfiguration {
        try BlockConfiguration(domains: domains, startedAt: startedAt, expiresAt: expiresAt)
    }
}

public enum BlockError: LocalizedError {
    case emptyList, damagedHostsSection, invalidExpiry
    public var errorDescription: String? {
        switch self {
        case .emptyList: return "Add between 1 and 500 websites before starting a block."
        case .damagedHostsSection: return "Still’s hosts-file section is damaged. No changes were made. See the recovery instructions in README.md."
        case .invalidExpiry: return "The session end time must be in the future."
        }
    }
}
