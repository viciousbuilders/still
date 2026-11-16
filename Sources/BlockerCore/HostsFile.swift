import Foundation

public enum HostsFile {
    // Non-local destinations, explicitly rejected by Still's PF table.
    // Loopback/unspecified addresses can reach a local HTTPS development server.
    public static let blockedIPv4 = "192.0.2.1"
    public static let blockedIPv6 = "100::1"

    public static let begin = "# BEGIN STILL WEBSITE BLOCKER"
    public static let end = "# END STILL WEBSITE BLOCKER"

    public static func removingBlock(from original: String) throws -> String {
        let lines = original.components(separatedBy: "\n")
        let starts = lines.indices.filter { lines[$0] == begin }
        let ends = lines.indices.filter { lines[$0] == end }
        guard starts.count == ends.count, starts.count <= 1 else { throw BlockError.damagedHostsSection }
        guard let start = starts.first, let finish = ends.first else { return original }
        guard start < finish else { throw BlockError.damagedHostsSection }
        return lines.enumerated().filter { !(start...finish).contains($0.offset) }.map(\.element).joined(separator: "\n")
    }

    public static func applying(_ domains: [String], to original: String) throws -> String {
        let expanded = try Domain.expanded(domains)
        guard !expanded.isEmpty else { throw BlockError.emptyList }
        var output = try removingBlock(from: original)
        if !output.isEmpty && !output.hasSuffix("\n") { output += "\n" }
        output += begin + "\n"
        for host in expanded { output += "\(blockedIPv4) \(host)\n\(blockedIPv6) \(host)\n" }
        output += end + "\n"
        return output
    }

    public static func containsBlock(_ original: String) -> Bool {
        original.components(separatedBy: "\n").contains(begin)
    }
}
