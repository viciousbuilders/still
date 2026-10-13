import Foundation
import Darwin
import BlockerCore

struct FirewallState: Codable, Equatable {
    var hosts: [String: [String]]
    var refreshedAt: Date
    var addresses: [String] { Array(Set(hosts.values.flatMap { $0 })).sorted() }
}

protocol FirewallManaging {
    func savedState() throws -> FirewallState?
    func prepare(domains: [String], now: Date) throws -> FirewallState
    func apply(_ state: FirewallState) throws
    func restore(_ state: FirewallState?) throws
    func maintain(domains: [String], now: Date) throws
    func remove() throws
}

/// Uses the standard macOS wildcard anchor; never replaces the main ruleset
/// or flushes unrelated connections. The helper calls this under its file lock.
final class PacketFilter: FirewallManaging {
    static let anchor = "com.apple/000.com.viciousbuilders.still"
    private let paths: SystemPaths
    private let run: CommandRunner
    private var stateURL: URL { paths.directory.appendingPathComponent("firewall.json") }
    private var rulesURL: URL { paths.directory.appendingPathComponent("firewall.conf") }
    private var leaseURL: URL { paths.directory.appendingPathComponent("pf-lease.json") }
    private struct Lease: Codable { let token: String; let boot: Int64 }

    init(paths: SystemPaths, run: @escaping CommandRunner = runCommand) {
        self.paths = paths; self.run = run
    }

    func prepare(domains: [String], now: Date) throws -> FirewallState {
        let previous = try readState()
        let hosts = try Domain.expanded(domains)
        let queue = OperationQueue(), lock = NSLock()
        queue.maxConcurrentOperationCount = 8
        var resolved: [String: [String]] = [:]
        var failures: [String] = []
        for host in hosts {
            queue.addOperation {
                // dig queries DNS directly, bypassing Still's active hosts entries.
                var addresses: [String] = []
                for family in ["A", "AAAA"] {
                    let result = self.run("/usr/bin/dig", ["+short", "+time=2", "+tries=1", host, family])
                    if result.status == 0 {
                        addresses += result.message.components(separatedBy: .whitespacesAndNewlines).compactMap(Self.address)
                    }
                }
                // Retain older addresses for existing connections while the host
                // remains blocked; removed domains do not retain their addresses.
                addresses += previous?.hosts[host] ?? []
                lock.lock(); defer { lock.unlock() }
                if addresses.isEmpty { failures.append(host) }
                else { resolved[host] = Array(Set(addresses)).sorted() }
            }
        }
        queue.waitUntilAllOperationsAreFinished()
        guard failures.isEmpty else {
            throw SystemError.commandFailed("Could not resolve firewall addresses for \(failures.sorted().joined(separator: ", ")). Check your connection and try again; the existing block is unchanged.")
        }
        return FirewallState(hosts: resolved, refreshedAt: now)
    }

    func apply(_ state: FirewallState) throws {
        try validate(state)
        try ensureAnchorReachable()
        let rules = Self.rules(for: state.addresses)
        try write(Data(rules.utf8), to: rulesURL)
        try command(["-a", Self.anchor, "-n", "-f", rulesURL.path])
        try command(["-a", Self.anchor, "-f", rulesURL.path])
        try ensureEnabled()
        // -F states would disrupt every connection. Kill only states whose
        // destination is a blocked server, for both address families.
        for address in state.addresses {
            try command(["-k", address.contains(":") ? "::/0" : "0.0.0.0/0", "-k", address])
        }
        try write(try JSONEncoder().encode(state), to: stateURL)
    }

    func restore(_ state: FirewallState?) throws {
        if let state { try apply(state) }
        else { try remove() }
    }

    func maintain(domains: [String], now: Date) throws {
        guard let state = try readState() else { return } // Legacy hosts-only block.
        try ensureAnchorReachable()
        let rules = try command(["-a", Self.anchor, "-s", "rules"])
        if !rules.contains("still_blocked") { try apply(state) }
        else { try ensureEnabled() }
        if now.timeIntervalSince(state.refreshedAt) >= 300 {
            // A transient DNS failure must leave the installed rules in place.
            let next = try prepare(domains: domains, now: now)
            if next.addresses != state.addresses { try apply(next) }
            else { try write(try JSONEncoder().encode(next), to: stateURL) }
        }
    }

    func remove() throws {
        // Legacy installations have no firewall artifacts and need no PF access.
        guard FileManager.default.fileExists(atPath: stateURL.path)
            || FileManager.default.fileExists(atPath: rulesURL.path)
            || FileManager.default.fileExists(atPath: leaseURL.path) else { return }
        try command(["-a", Self.anchor, "-F", "rules"])
        try command(["-a", Self.anchor, "-F", "Tables"])
        if let lease = try readLease(), lease.boot == Self.bootTime() {
            let references = try command(["-s", "References"])
            if references.components(separatedBy: .whitespacesAndNewlines).contains(lease.token) {
                try command(["-X", lease.token])
            }
        }
        for url in [stateURL, rulesURL, leaseURL] {
            try checkPath(url)
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        }
    }

    func savedState() throws -> FirewallState? { try readState() }

    private func readState() throws -> FirewallState? {
        try checkPath(stateURL)
        guard FileManager.default.fileExists(atPath: stateURL.path) else { return nil }
        let state = try JSONDecoder().decode(FirewallState.self, from: Data(contentsOf: stateURL))
        try validate(state)
        return state
    }

    private func validate(_ state: FirewallState) throws {
        guard !state.hosts.isEmpty, state.hosts.count <= 1000 else {
            throw SystemError.commandFailed("Still's saved firewall state is invalid.")
        }
        for (host, addresses) in state.hosts {
            try Domain.validate(host)
            guard !addresses.isEmpty, addresses.allSatisfy({ Self.address($0) == $0 }) else {
                throw SystemError.commandFailed("Still's saved firewall addresses are invalid.")
            }
        }
    }

    private func ensureAnchorReachable() throws {
        func filteringRules(_ output: String) -> [String] {
            output.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !$0.hasPrefix("No ALTQ") && !$0.hasPrefix("ALTQ related") }
        }
        var rules = filteringRules(try command(["-s", "rules"]))
        if rules.isEmpty {
            // Only initialize the main ruleset if none is loaded. Never replace
            // another application's active rules with the on-disk defaults.
            try command(["-n", "-f", "/etc/pf.conf"])
            try command(["-f", "/etc/pf.conf"])
            rules = filteringRules(try command(["-s", "rules"]))
        }
        guard let anchorIndex = rules.firstIndex(where: {
            $0 == "anchor \"com.apple/*\" all" || $0 == "anchor \"com.apple/*\" quick all"
        }), !rules[..<anchorIndex].contains(where: {
            let tokens = $0.split(separator: " ")
            return tokens.contains("quick") && (tokens.first == "pass" || tokens.first == "anchor")
        }) else {
            throw SystemError.commandFailed("Your firewall configuration needs macOS's standard com.apple/* anchor before any quick pass rules. Still did not replace your firewall rules.")
        }
    }

    private func ensureEnabled() throws {
        if let lease = try readLease(), lease.boot == Self.bootTime() {
            let references = try command(["-s", "References"])
            if references.components(separatedBy: .whitespacesAndNewlines).contains(lease.token) { return }
        }
        let result = try command(["-E"])
        guard let token = result.components(separatedBy: "\n").first(where: { $0.hasPrefix("Token : ") })?
            .dropFirst("Token : ".count).trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty, token.allSatisfy(\.isNumber) else {
            throw SystemError.commandFailed("Could not obtain Still's firewall enable token: \(result)")
        }
        do { try write(try JSONEncoder().encode(Lease(token: token, boot: Self.bootTime())), to: leaseURL) }
        catch { _ = run("/sbin/pfctl", ["-X", token]); throw error }
    }

    private func readLease() throws -> Lease? {
        try checkPath(leaseURL)
        guard FileManager.default.fileExists(atPath: leaseURL.path) else { return nil }
        let lease = try JSONDecoder().decode(Lease.self, from: Data(contentsOf: leaseURL))
        guard !lease.token.isEmpty, lease.token.utf8.allSatisfy({ (48...57).contains($0) }) else {
            throw SystemError.commandFailed("Still's saved firewall token is invalid.")
        }
        return lease
    }

    @discardableResult private func command(_ arguments: [String]) throws -> String {
        let result = run("/sbin/pfctl", arguments)
        guard result.status == 0 else { throw SystemError.commandFailed("Could not update Still's firewall: \(result.message)") }
        return result.message
    }

    private func checkPath(_ url: URL) throws {
        var info = stat()
        if lstat(url.path, &info) == 0 {
            guard info.st_mode & S_IFMT == S_IFREG, paths.isSandbox || (info.st_uid == 0 && info.st_mode & 0o022 == 0)
            else { throw SystemError.unsafePath(url.path) }
        } else if errno != ENOENT { throw SystemError.unsafePath(url.path) }
    }

    private func write(_ data: Data, to url: URL) throws {
        try checkPath(url)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
    }

    static func rules(for addresses: [String]) -> String {
        "table <still_blocked> persist { \(addresses.joined(separator: ", ")) }\n"
        + "block return out quick proto { tcp, udp } from any to <still_blocked>\n"
        + "block return in quick proto { tcp, udp } from <still_blocked> to any\n"
    }

    static func address(_ text: String) -> String? {
        var ipv4 = in_addr(), ipv6 = in6_addr()
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        if inet_pton(AF_INET, text, &ipv4) == 1 {
            let bytes = withUnsafeBytes(of: ipv4) { Array($0) }
            guard bytes[0] != 0, bytes[0] != 127, bytes[0] < 224,
                  !(bytes[0] == 169 && bytes[1] == 254) else { return nil }
            inet_ntop(AF_INET, &ipv4, &buffer, socklen_t(buffer.count))
        } else if inet_pton(AF_INET6, text, &ipv6) == 1 {
            let bytes = withUnsafeBytes(of: ipv6) { Array($0) }
            guard bytes[0] & 0xe0 == 0x20 else { return nil } // Global unicast only.
            inet_ntop(AF_INET6, &ipv6, &buffer, socklen_t(buffer.count))
        } else { return nil }
        return String(cString: buffer)
    }

    private static func bootTime() -> Int64 {
        var boot = timeval(), size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &boot, &size, nil, 0) == 0 else { return -1 }
        return Int64(boot.tv_sec)
    }
}

/// Existing filesystem tests stay offline. Firewall behavior has its own tests
/// using a fake command runner rather than opening /dev/pf.
struct SandboxFirewall: FirewallManaging {
    func savedState() throws -> FirewallState? { nil }
    func prepare(domains: [String], now: Date) throws -> FirewallState { FirewallState(hosts: [:], refreshedAt: now) }
    func apply(_ state: FirewallState) throws {}
    func restore(_ state: FirewallState?) throws {}
    func maintain(domains: [String], now: Date) throws {}
    func remove() throws {}
}
