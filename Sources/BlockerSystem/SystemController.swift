import Foundation
import Darwin
import BlockerCore

public enum SystemError: LocalizedError {
    case unsafePath(String), commandFailed(String)
    public var errorDescription: String? {
        switch self {
        case .unsafePath(let path): return "Refusing to modify an unsafe filesystem path: \(path)"
        case .commandFailed(let message): return message
        }
    }
}

public struct SystemPaths {
    public let directory: URL
    public let hosts: URL
    public let daemon: URL
    public let isSandbox: Bool
    public static let live = SystemPaths(
        directory: URL(fileURLWithPath: "/Library/Application Support/Still", isDirectory: true),
        hosts: URL(fileURLWithPath: "/private/etc/hosts"),
        daemon: URL(fileURLWithPath: "/Library/LaunchDaemons/com.viciousbuilders.still.expiry.plist"),
        isSandbox: false
    )
    public static func sandbox(_ root: URL) -> SystemPaths {
        SystemPaths(directory: root.appendingPathComponent("Still"), hosts: root.appendingPathComponent("hosts"),
                    daemon: root.appendingPathComponent("expiry.plist"), isSandbox: true)
    }
    public var state: URL { directory.appendingPathComponent("active.json") }
    public var helper: URL { directory.appendingPathComponent("StillHelper") }
    public var focus: URL { directory.appendingPathComponent("focus.json") }
    public func garden(userID: UInt32) -> URL { directory.appendingPathComponent("garden-\(userID).json") }
}

/// The root helper changes its marked hosts section, its PF anchor, and its own files.
/// The same implementation runs against a temporary filesystem in integration tests.
public final class SystemController {
    let paths: SystemPaths
    private let fm = FileManager.default
    let firewall: FirewallManaging
    private var lastMaintenance: Date?
    public init(paths: SystemPaths) {
        self.paths = paths
        firewall = paths.isSandbox ? SandboxFirewall() : PacketFilter(paths: paths)
    }
    init(paths: SystemPaths, firewall: FirewallManaging) {
        self.paths = paths; self.firewall = firewall
    }

    public func apply(_ configuration: BlockConfiguration, helperSource: URL, now: Date = Date()) throws {
        let configuration = try configuration.validated()
        guard !configuration.isExpired(at: now) else { throw BlockError.invalidExpiry }
        try withLock { try applyLocked(configuration, helperSource: helperSource, now: now) }
    }

    func applyLocked(_ configuration: BlockConfiguration, helperSource: URL, now: Date, reloadScheduler: Bool = false) throws {
        try checkPath(paths.hosts)
        try checkPath(paths.state)
        try checkPath(paths.daemon)
        let original = try String(contentsOf: paths.hosts, encoding: .utf8)
        let replacement = try HostsFile.applying(configuration.domains, to: original)
        let previousState = try readStateData()
        let previousFirewall = try firewall.savedState()
        let nextFirewall = try firewall.prepare(domains: configuration.domains, now: now)
        let previousDaemon = fm.fileExists(atPath: paths.daemon.path) ? try Data(contentsOf: paths.daemon) : nil
        let backup = paths.directory.appendingPathComponent("hosts-before-still")
        if !fm.fileExists(atPath: backup.path) { try write(Data(original.utf8), to: backup, mode: 0o644) }
        try installHelper(from: helperSource)
        do {
            try firewall.apply(nextFirewall)
            try write(try JSONEncoder().encode(configuration), to: paths.state, mode: 0o644)
            try writeHosts(replacement)
            try installScheduler(forceReload: reloadScheduler)
        } catch {
            let failure = error
            var rollbackErrors: [String] = []
            func rollback(_ action: () throws -> Void) {
                do { try action() } catch { rollbackErrors.append(error.localizedDescription) }
            }
            rollback { try firewall.restore(previousFirewall) }
            rollback { try writeHosts(original) }
            rollback {
                if let previousState { try write(previousState, to: paths.state, mode: 0o644) }
                else { try removeIfPresent(paths.state) }
            }
            rollback {
                if let previousDaemon { try write(previousDaemon, to: paths.daemon, mode: 0o644) }
                else { try stopScheduler() }
            }
            flushDNS()
            guard rollbackErrors.isEmpty else {
                throw SystemError.commandFailed("\(failure.localizedDescription) Recovery also failed: \(rollbackErrors.joined(separator: "; ")). Use Unblock all groups to retry cleanup.")
            }
            throw failure
        }
        flushDNS()
    }

    public func remove() throws {
        try withLock {
            try removeBlocksLocked(keepScheduler: true)
            try archiveAndRemoveFocusLocked()
            try stopScheduler()
        }
    }

    func removeBlocksLocked(keepScheduler: Bool) throws {
        let original = try String(contentsOf: paths.hosts, encoding: .utf8)
        let replacement = try HostsFile.removingBlock(from: original)
        let previousFirewall = try firewall.savedState()
        try firewall.remove()
        do { try writeHosts(replacement) }
        catch { try firewall.restore(previousFirewall); throw error }
        try removeIfPresent(paths.state)
        flushDNS()
        if !keepScheduler { try stopScheduler() }
    }

    public func tick(now: Date = Date(), uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) throws {
        // No files need to be created if the app has never enabled a block.
        guard fm.fileExists(atPath: paths.state.path) || fm.fileExists(atPath: paths.focus.path) else { return }
        try withLock {
            if try advanceFocusLocked(now: now, uptime: uptime) { return }
            guard let data = try readStateData() else { return }
            let state = try JSONDecoder().decode(BlockConfiguration.self, from: data).validated()
            if let remaining = try state.removingExpiredGroups(at: now), remaining != state {
                // Already holding the operation lock: expire only the due groups
                // and keep the same transactional rollback as a manual update.
                try applyLocked(remaining, helperSource: paths.helper, now: now)
                return
            }
            guard state.isExpired(at: now) else {
                try maintainFirewall(domains: state.domains, now: now)
                return
            }
            let original = try String(contentsOf: paths.hosts, encoding: .utf8)
            let replacement = try HostsFile.removingBlock(from: original)
            try firewall.remove()
            try writeHosts(replacement)
            try removeIfPresent(paths.state)
            try removeIfPresent(paths.daemon)
            flushDNS()
            // This can terminate our own process. All writes and DNS flushing
            // are complete. Keep the lock until then so a new session cannot
            // start between removing the old state and unloading its job.
            // Process exit also releases the kernel-held flock.
            if !paths.isSandbox {
                _ = run("/bin/launchctl", ["bootout", "system/com.viciousbuilders.still.expiry"])
            }
        }
    }

    func maintainFirewall(domains: [String], now: Date) throws {
        if let lastMaintenance, now >= lastMaintenance, now.timeIntervalSince(lastMaintenance) < 15 { return }
        try firewall.maintain(domains: domains, now: now)
        lastMaintenance = now
    }

    func withLock(_ operation: () throws -> Void) throws {
        try ensureDirectory()
        let lockPath = paths.directory.appendingPathComponent("operation.lock").path
        let descriptor = open(lockPath, O_CREAT | O_RDWR | O_NOFOLLOW, 0o644)
        guard descriptor >= 0 else { throw SystemError.unsafePath(lockPath) }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw SystemError.commandFailed("Could not lock Still’s configuration.") }
        defer { flock(descriptor, LOCK_UN) }
        try operation()
    }

    private func ensureDirectory() throws {
        if !fm.fileExists(atPath: paths.directory.path) {
            try fm.createDirectory(at: paths.directory, withIntermediateDirectories: false,
                                   attributes: [.posixPermissions: 0o755])
        }
        try checkPath(paths.directory)
        let attributes = try fm.attributesOfItem(atPath: paths.directory.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory else { throw SystemError.unsafePath(paths.directory.path) }
        if !paths.isSandbox {
            guard (attributes[.ownerAccountID] as? NSNumber)?.intValue == 0,
                  ((attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o022 == 0
            else { throw SystemError.unsafePath(paths.directory.path) }
        }
    }

    func checkPath(_ url: URL) throws {
        var info = stat()
        if lstat(url.path, &info) == 0 {
            guard info.st_mode & S_IFMT != S_IFLNK else { throw SystemError.unsafePath(url.path) }
            if !paths.isSandbox && info.st_uid != 0 { throw SystemError.unsafePath(url.path) }
        } else if errno != ENOENT { throw SystemError.unsafePath(url.path) }
    }

    func readStateData() throws -> Data? {
        try checkPath(paths.state)
        return fm.fileExists(atPath: paths.state.path) ? try Data(contentsOf: paths.state) : nil
    }

    func write(_ data: Data, to url: URL, mode: Int) throws {
        try checkPath(url)
        try data.write(to: url, options: .atomic)
        try fm.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
    }

    private func writeHosts(_ contents: String) throws {
        try checkPath(paths.hosts)
        let attributes = try fm.attributesOfItem(atPath: paths.hosts.path)
        try write(Data(contents.utf8), to: paths.hosts,
                  mode: (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o644)
        try fm.setAttributes([.ownerAccountID: attributes[.ownerAccountID] ?? 0,
                              .groupOwnerAccountID: attributes[.groupOwnerAccountID] ?? 0], ofItemAtPath: paths.hosts.path)
    }

    func installHelper(from source: URL) throws {
        if paths.isSandbox { return }
        guard source.standardizedFileURL != paths.helper.standardizedFileURL else { return }
        try write(try Data(contentsOf: source), to: paths.helper, mode: 0o755)
    }

    private func installScheduler(forceReload: Bool = false) throws {
        let plist: [String: Any] = [
            "Label": "com.viciousbuilders.still.expiry",
            "ProgramArguments": [paths.helper.path, "--watch"],
            "StartInterval": 15,
            "RunAtLoad": true,
            "ProcessType": "Background"
        ]
        try write(try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0), to: paths.daemon, mode: 0o644)
        if paths.isSandbox { return }
        // An existing scheduler already runs the installed helper at this path.
        // Keeping it loaded also preserves the previous timer if an update fails.
        if run("/bin/launchctl", ["print", "system/com.viciousbuilders.still.expiry"]).status == 0 {
            if !forceReload { return }
            _ = run("/bin/launchctl", ["bootout", "system/com.viciousbuilders.still.expiry"])
        }
        let result = run("/bin/launchctl", ["bootstrap", "system", paths.daemon.path])
        guard result.status == 0 else {
            throw SystemError.commandFailed("Could not schedule automatic unblocking: \(result.message)")
        }
    }

    func stopScheduler() throws {
        if !paths.isSandbox {
            _ = run("/bin/launchctl", ["bootout", "system/com.viciousbuilders.still.expiry"])
        }
        try removeIfPresent(paths.daemon)
    }

    func removeIfPresent(_ url: URL) throws {
        try checkPath(url)
        if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
    }

    private func flushDNS() {
        guard !paths.isSandbox else { return }
        _ = run("/usr/bin/dscacheutil", ["-flushcache"])
        _ = run("/usr/bin/killall", ["-HUP", "mDNSResponder"])
    }

    func run(_ executable: String, _ arguments: [String]) -> CommandResult {
        runCommand(executable, arguments)
    }
}
