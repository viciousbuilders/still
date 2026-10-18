import Foundation

public struct BlockGroup: Codable, Equatable, Identifiable {
    public static let legacyID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    public let id: UUID
    public var name: String
    public var domains: [String]
    public var durationMinutes: Int?

    public init(id: UUID = UUID(), name: String, domains: [String] = [], durationMinutes: Int? = nil) {
        self.id = id; self.name = name; self.domains = domains; self.durationMinutes = durationMinutes
    }

    public func validated() throws -> BlockGroup {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 40, !name.contains(where: { $0.isNewline }), domains.count <= 500,
              durationMinutes == nil || [25, 50, 90].contains(durationMinutes!) else { throw BlockError.invalidGroup }
        for domain in domains { try Domain.validate(domain) }
        return BlockGroup(id: id, name: name, domains: Array(Set(domains)).sorted(), durationMinutes: durationMinutes)
    }
}

/// The applied snapshot stays separate from editable group preferences.
public struct ActiveBlockGroup: Codable, Equatable, Identifiable {
    public let id: UUID
    public let name: String
    public let domains: [String]
    public let expiresAt: Date?

    public init(id: UUID, name: String, domains: [String], expiresAt: Date? = nil) {
        self.id = id; self.name = name; self.domains = domains; self.expiresAt = expiresAt
    }

    public func isExpired(at date: Date) -> Bool { expiresAt.map { date >= $0 } ?? false }
}
