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
}

/// The root helper only changes its marked hosts section and its own files.
/// The same implementation runs against a temporary filesystem in integration tests.
public final class SystemController {
    private let paths: SystemPaths
    private let fm = FileManager.default
    public init(paths: SystemPaths) { self.paths = paths }

    public func apply(_ configuration: BlockConfiguration, helperSource: URL, now: Date = Date()) throws {
        let configuration = try configuration.validated()
        guard !configuration.isExpired(at: now) else { throw BlockError.invalidExpiry }
        try withLock {
            try checkPath(paths.hosts)
            try checkPath(paths.state)
            try checkPath(paths.daemon)
            let original = try String(contentsOf: paths.hosts, encoding: .utf8)
            let replacement = try HostsFile.applying(configuration.domains, to: original)
            let previousState = try readStateData()
            let backup = paths.directory.appendingPathComponent("hosts-before-still")
            if !fm.fileExists(atPath: backup.path) { try write(Data(original.utf8), to: backup, mode: 0o644) }
            try installHelper(from: helperSource)
            do {
                try write(try JSONEncoder().encode(configuration), to: paths.state, mode: 0o644)
                try writeHosts(replacement)
                if configuration.expiresAt != nil { try installScheduler() }
                else { try stopScheduler() }
            } catch {
                // Return both files to their previous state if installation fails.
                try writeHosts(original)
                if let previousState { try write(previousState, to: paths.state, mode: 0o644) }
                else { try removeIfPresent(paths.state) }
                flushDNS()
                throw error
            }
            flushDNS()
        }
    }

    public func remove() throws {
        try withLock {
            let original = try String(contentsOf: paths.hosts, encoding: .utf8)
            try writeHosts(try HostsFile.removingBlock(from: original))
            try removeIfPresent(paths.state)
            try stopScheduler()
            flushDNS()
        }
    }

    public func tick(now: Date = Date()) throws {
        // No files need to be created if the app has never enabled a block.
        guard fm.fileExists(atPath: paths.state.path) else { return }
        try withLock {
            guard let data = try readStateData() else { return }
            let state = try JSONDecoder().decode(BlockConfiguration.self, from: data).validated()
            guard state.isExpired(at: now) else { return }
            let original = try String(contentsOf: paths.hosts, encoding: .utf8)
            try writeHosts(try HostsFile.removingBlock(from: original))
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

    private func withLock(_ operation: () throws -> Void) throws {
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

    private func checkPath(_ url: URL) throws {
        var info = stat()
        if lstat(url.path, &info) == 0 {
            guard info.st_mode & S_IFMT != S_IFLNK else { throw SystemError.unsafePath(url.path) }
            if !paths.isSandbox && info.st_uid != 0 { throw SystemError.unsafePath(url.path) }
        } else if errno != ENOENT { throw SystemError.unsafePath(url.path) }
    }

    private func readStateData() throws -> Data? {
        try checkPath(paths.state)
        return fm.fileExists(atPath: paths.state.path) ? try Data(contentsOf: paths.state) : nil
    }

    private func write(_ data: Data, to url: URL, mode: Int) throws {
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

    private func installHelper(from source: URL) throws {
        if paths.isSandbox { return }
        guard source.standardizedFileURL != paths.helper.standardizedFileURL else { return }
        try write(try Data(contentsOf: source), to: paths.helper, mode: 0o755)
    }

    private func installScheduler() throws {
        let plist: [String: Any] = [
            "Label": "com.viciousbuilders.still.expiry",
            "ProgramArguments": [paths.helper.path, "--tick"],
            "StartInterval": 15,
            "RunAtLoad": true,
            "ProcessType": "Background"
        ]
        try write(try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0), to: paths.daemon, mode: 0o644)
        if paths.isSandbox { return }
        // An existing scheduler already runs the installed helper at this path.
        // Keeping it loaded also preserves the previous timer if an update fails.
        if run("/bin/launchctl", ["print", "system/com.viciousbuilders.still.expiry"]).status == 0 { return }
        let result = run("/bin/launchctl", ["bootstrap", "system", paths.daemon.path])
        guard result.status == 0 else {
            throw SystemError.commandFailed("Could not schedule automatic unblocking: \(result.message)")
        }
    }

    private func stopScheduler() throws {
        if !paths.isSandbox {
            _ = run("/bin/launchctl", ["bootout", "system/com.viciousbuilders.still.expiry"])
        }
        try removeIfPresent(paths.daemon)
    }

    private func removeIfPresent(_ url: URL) throws {
        try checkPath(url)
        if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
    }

    private func flushDNS() {
        guard !paths.isSandbox else { return }
        _ = run("/usr/bin/dscacheutil", ["-flushcache"])
        _ = run("/usr/bin/killall", ["-HUP", "mDNSResponder"])
    }

    private func run(_ executable: String, _ arguments: [String]) -> (status: Int32, message: String) {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe; process.standardError = pipe
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
        } catch { return (-1, error.localizedDescription) }
    }
}
