import XCTest
import BlockerCore
@testable import BlockerSystem

final class PacketFilterTests: XCTestCase {
    var root: URL!
    var paths: SystemPaths!
    var pf: PacketFilter!
    private var commands: FakePF!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("still-pf-tests-" + UUID().uuidString)
        paths = .sandbox(root)
        try FileManager.default.createDirectory(at: paths.directory, withIntermediateDirectories: true)
        commands = FakePF()
        pf = PacketFilter(paths: paths, run: commands.run)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    func testDNSBypassesHostsAndExistingStatesAreClearedOnlyForBlockedIPv4AndIPv6Servers() throws {
        let state = try pf.prepare(domains: ["linkedin.com"], now: Date())
        XCTAssertEqual(state.hosts.keys.sorted(), ["linkedin.com", "www.linkedin.com"])
        XCTAssertEqual(state.addresses, ["104.18.41.41", "2606:4700::1"])
        try pf.apply(state)
        let rules = try String(contentsOf: paths.directory.appendingPathComponent("firewall.conf"))
        XCTAssertTrue(rules.contains("block return out quick proto { tcp, udp }"))
        XCTAssertTrue(rules.contains("block return in quick proto { tcp, udp }"))
        XCTAssertTrue(commands.calls.contains(["-k", "0.0.0.0/0", "-k", "104.18.41.41"]))
        XCTAssertTrue(commands.calls.contains(["-k", "::/0", "-k", "2606:4700::1"]))
        XCTAssertFalse(commands.calls.contains(where: { $0.contains("states") || $0.contains("-d") }))
        XCTAssertFalse(commands.calls.contains(["-f", "/etc/pf.conf"]))
    }

    func testUnresolvableNewHostLeavesPreviousFirewallUntouched() throws {
        try pf.apply(pf.prepare(domains: ["linkedin.com"], now: Date()))
        let before = try pf.savedState()
        commands.dns = "127.0.0.1\n::1\nCNAME.example.com.\n"
        let count = commands.calls.count
        XCTAssertThrowsError(try pf.prepare(domains: ["different.example.com"], now: Date()))
        XCTAssertEqual(try pf.savedState(), before)
        XCTAssertEqual(commands.calls.count, count) // DNS calls are counted separately.
    }

    func testRefreshRetainsAddressesForExistingConnectionsAndDropsRemovedDomains() throws {
        let now = Date()
        try pf.apply(pf.prepare(domains: ["linkedin.com"], now: now))
        commands.dns = "172.64.146.215\n"
        try pf.maintain(domains: ["linkedin.com"], now: now.addingTimeInterval(301))
        XCTAssertEqual(try pf.savedState()?.addresses, ["104.18.41.41", "172.64.146.215", "2606:4700::1"])
        let updated = try pf.prepare(domains: ["other.example.com"], now: now)
        XCTAssertEqual(updated.addresses, ["172.64.146.215"])
        XCTAssertEqual(updated.hosts.keys.sorted(), ["other.example.com", "www.other.example.com"])
    }

    func testMaintenanceRestoresRulesAfterRebootWithoutDNS() throws {
        let now = Date()
        try pf.apply(pf.prepare(domains: ["linkedin.com"], now: now))
        commands.anchorLoaded = false
        commands.references = ""
        commands.dns = ""
        try pf.maintain(domains: ["linkedin.com"], now: now.addingTimeInterval(15))
        XCTAssertTrue(commands.anchorLoaded)
        XCTAssertEqual(commands.enableCount, 2)
    }

    func testStopReleasesOnlyOurEnableTokenAndIsIdempotent() throws {
        let state = try pf.prepare(domains: ["linkedin.com"], now: Date())
        try pf.apply(state)
        try pf.apply(state)
        XCTAssertEqual(commands.enableCount, 1)
        try pf.remove()
        XCTAssertTrue(commands.calls.contains(["-X", "12345"]))
        XCTAssertTrue(commands.calls.contains(["-a", PacketFilter.anchor, "-F", "rules"]))
        XCTAssertFalse(commands.calls.contains(where: { $0.contains("-d") || $0.contains("all") }))
        XCTAssertNil(try pf.savedState())
        let count = commands.calls.count
        try pf.remove()
        XCTAssertEqual(commands.calls.count, count)
    }

    func testCustomRootWithoutStandardAnchorIsRejectedBeforeInstallingRules() throws {
        commands.rootRules = "pass out quick all\n"
        XCTAssertThrowsError(try pf.apply(pf.prepare(domains: ["linkedin.com"], now: Date())))
        XCTAssertFalse(commands.anchorLoaded)
        XCTAssertFalse(commands.calls.contains(["-f", "/etc/pf.conf"]))
        XCTAssertNil(try pf.savedState())
    }

    func testEarlierQuickPassCannotSilentlyBypassOurAnchor() throws {
        commands.rootRules = "pass out quick all\nanchor \"com.apple/*\" all\n"
        XCTAssertThrowsError(try pf.apply(pf.prepare(domains: ["linkedin.com"], now: Date())))
        XCTAssertFalse(commands.anchorLoaded)
    }

    func testEmptyMainRulesetIsInitializedButExistingRulesAreNeverReplaced() throws {
        commands.rootRules = "No ALTQ support in kernel\nALTQ related functions disabled\n"
        try pf.apply(pf.prepare(domains: ["linkedin.com"], now: Date()))
        XCTAssertEqual(commands.calls.filter { $0 == ["-f", "/etc/pf.conf"] }.count, 1)
        try pf.apply(pf.prepare(domains: ["linkedin.com"], now: Date()))
        XCTAssertEqual(commands.calls.filter { $0 == ["-f", "/etc/pf.conf"] }.count, 1)
    }

    func testForgedAddressesAndSymlinkStateCannotReachPF() throws {
        XCTAssertThrowsError(try pf.apply(FirewallState(hosts: ["linkedin.com": ["any\npass all"]], refreshedAt: Date())))
        XCTAssertTrue(commands.calls.isEmpty)
        let target = root.appendingPathComponent("outside.json")
        try Data("untouched".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: paths.directory.appendingPathComponent("firewall.json"), withDestinationURL: target)
        XCTAssertThrowsError(try pf.prepare(domains: ["linkedin.com"], now: Date()))
        XCTAssertEqual(try String(contentsOf: target), "untouched")
    }

    func testSchedulerFailureRollsBackActualFirewallFilesAndRules() throws {
        try "127.0.0.1 localhost\n".write(to: paths.hosts, atomically: true, encoding: .utf8)
        let controller = SystemController(paths: paths, firewall: pf)
        try controller.apply(BlockConfiguration(domains: ["linkedin.com"]), helperSource: root)
        let before = try pf.savedState()
        let hosts = try String(contentsOf: paths.hosts)
        let broken = SystemPaths(directory: paths.directory, hosts: paths.hosts,
                                 daemon: root.appendingPathComponent("missing/expiry.plist"), isSandbox: true)
        commands.dns = "172.64.146.215\n"
        XCTAssertThrowsError(try SystemController(paths: broken, firewall: pf).apply(
            BlockConfiguration(domains: ["other.example.com"]), helperSource: root))
        XCTAssertEqual(try pf.savedState(), before)
        XCTAssertEqual(try String(contentsOf: paths.hosts), hosts)
        XCTAssertTrue(commands.anchorLoaded)
    }

    func testFirstInstallFailureAndTimerExpiryCleanUpFirewall() throws {
        try "127.0.0.1 localhost\n".write(to: paths.hosts, atomically: true, encoding: .utf8)
        let broken = SystemPaths(directory: paths.directory, hosts: paths.hosts,
                                 daemon: root.appendingPathComponent("missing/expiry.plist"), isSandbox: true)
        XCTAssertThrowsError(try SystemController(paths: broken, firewall: pf).apply(
            BlockConfiguration(domains: ["linkedin.com"]), helperSource: root))
        XCTAssertNil(try pf.savedState())
        XCTAssertFalse(commands.anchorLoaded)
        let now = Date(), end = now.addingTimeInterval(60)
        let controller = SystemController(paths: paths, firewall: pf)
        try controller.apply(BlockConfiguration(domains: ["linkedin.com"], expiresAt: end), helperSource: root, now: now)
        try controller.tick(now: end)
        XCTAssertNil(try pf.savedState())
        XCTAssertFalse(commands.anchorLoaded)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.state.path))
    }
}

private final class FakePF {
    var calls: [[String]] = []
    var dns = "104.18.41.41\n2606:4700::1\n"
    var rootRules = "anchor \"com.apple/*\" all\n"
    var anchorLoaded = false
    var references = ""
    var enableCount = 0
    private let lock = NSLock()

    func run(_ executable: String, _ arguments: [String]) -> CommandResult {
        lock.lock(); defer { lock.unlock() }
        if executable == "/usr/bin/dig" { return CommandResult(status: 0, message: dns) }
        calls.append(arguments)
        switch arguments {
        case ["-s", "rules"]: return CommandResult(status: 0, message: rootRules)
        case ["-f", "/etc/pf.conf"]: rootRules = "anchor \"com.apple/*\" all\n"
        case ["-s", "References"]: return CommandResult(status: 0, message: references)
        case ["-E"]:
            enableCount += 1; references = "Token : 12345\n"
            return CommandResult(status: 0, message: references)
        case ["-a", PacketFilter.anchor, "-s", "rules"]:
            return CommandResult(status: 0, message: anchorLoaded ? "block return out quick to <still_blocked>\n" : "")
        case ["-a", PacketFilter.anchor, "-F", "rules"]: anchorLoaded = false
        default:
            if arguments.prefix(3) == ["-a", PacketFilter.anchor, "-f"] { anchorLoaded = true }
        }
        return CommandResult(status: 0, message: "")
    }
}
