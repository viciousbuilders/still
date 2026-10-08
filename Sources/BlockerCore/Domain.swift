import Foundation

public enum DomainError: LocalizedError {
    case invalid(String)
    public var errorDescription: String? {
        switch self {
        case .invalid(let value): return "“\(value)” isn’t a public website domain. Try example.com or an https:// URL."
        }
    }
}

public enum Domain {
    public static func normalize(_ input: String) throws -> String {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = text.contains("://") ? text : "https://" + text
        guard let url = URLComponents(string: source),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.user == nil, url.password == nil,
              var host = url.host?.lowercased() else { throw DomainError.invalid(text) }
        if host.hasSuffix(".") { host.removeLast() }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        try validate(host)
        return host
    }

    /// Used again at the privilege boundary; accepts only canonical ASCII domains.
    public static func validate(_ host: String) throws {
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard !host.isEmpty, host.utf8.count <= 253, labels.count >= 2,
              host == host.lowercased(), host.utf8.allSatisfy({
                  (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 46
              }),
              labels.allSatisfy({ !$0.isEmpty && $0.count <= 63 && !$0.hasPrefix("-") && !$0.hasSuffix("-") }),
              let last = labels.last, last.count >= 2,
              last.utf8.contains(where: { (97...122).contains($0) }),
              !["localhost", "local", "internal", "test", "invalid"].contains(String(last))
        else { throw DomainError.invalid(host) }
    }

    public static func parseList(_ input: String) throws -> [String] {
        let entries = input.components(separatedBy: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",")))
            .filter { !$0.isEmpty }
        guard !entries.isEmpty else { throw DomainError.invalid(input) }
        return try Array(Set(entries.map(normalize))).sorted()
    }

    public static func expanded(_ domains: [String]) throws -> [String] {
        for domain in domains { try validate(domain) }
        return Array(Set(domains.flatMap { [$0, "www." + $0] })).sorted()
    }
}
