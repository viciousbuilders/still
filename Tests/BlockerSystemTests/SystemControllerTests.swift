import XCTest
import BlockerCore
@testable import BlockerSystem

final class SystemControllerTests: XCTestCase {
    var root: URL!
    var paths: SystemPaths!
    var controller: SystemController!
    let initialHosts = "127.0.0.1 localhost\n::1 localhost\n# Keep this custom rule\n10.0.0.1 private.company.com\n"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("still-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        paths = .sandbox(root)
        try initialHosts.write(to: paths.hosts, atomically: true, encoding: .utf8)
        controller = SystemController(paths: paths)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    func testAlwaysOnEnableUpdateAndDisable() throws {
        try controller.apply(BlockConfiguration(domains: ["youtube.com"]), helperSource: root)
        let blocked = try String(contentsOf: paths.hosts)
        XCTAssertTrue(blocked.contains("www.youtube.com"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.daemon.path))
        try (blocked + "10.0.0.2 new.company.com\n").write(to: paths.hosts, atomically: true, encoding: .utf8)
        try controller.apply(BlockConfiguration(domains: ["reddit.com"]), helperSource: root)
        let changed = try String(contentsOf: paths.hosts)
        XCTAssertFalse(changed.contains("youtube.com"))
        XCTAssertTrue(changed.contains("reddit.com"))
        try controller.tick(now: .distantFuture)
        XCTAssertEqual(try String(contentsOf: paths.hosts), changed)
        try controller.remove()
        XCTAssertEqual(try String(contentsOf: paths.hosts), initialHosts + "10.0.0.2 new.company.com\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.state.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.daemon.path))
        try controller.remove() // Stopping again is safe.
    }

    func testTimerExpiresWithoutTheMenuBarApp() throws {
        let now = Date(timeIntervalSince1970: 5000), end = now.addingTimeInterval(1500)
        try controller.apply(BlockConfiguration(domains: ["reddit.com"], startedAt: now, expiresAt: end), helperSource: root, now: now)
        // A fresh instance stands in for a launchd invocation after restart.
        let fresh = SystemController(paths: paths)
        try fresh.tick(now: end.addingTimeInterval(-1))
        XCTAssertTrue(HostsFile.containsBlock(try String(contentsOf: paths.hosts)))
        try fresh.tick(now: end.addingTimeInterval(90))
        XCTAssertEqual(try String(contentsOf: paths.hosts), initialHosts)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.state.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.daemon.path))
        try fresh.tick(now: end.addingTimeInterval(100))
    }

    func testMalformedHostsAndExpiredSessionsDoNotWrite() throws {
        let malformed = initialHosts + HostsFile.begin + "\n"
        try malformed.write(to: paths.hosts, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try controller.apply(BlockConfiguration(domains: ["reddit.com"]), helperSource: root))
        XCTAssertEqual(try String(contentsOf: paths.hosts), malformed)
        XCTAssertThrowsError(try controller.remove())
        XCTAssertEqual(try String(contentsOf: paths.hosts), malformed)
        try initialHosts.write(to: paths.hosts, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try controller.apply(BlockConfiguration(domains: ["reddit.com"], expiresAt: .distantPast), helperSource: root))
        XCTAssertEqual(try String(contentsOf: paths.hosts), initialHosts)
    }

    func testFailedSchedulerInstallRollsBackHostsAndState() throws {
        // A missing parent makes writing the plist fail after writing the block.
        let brokenPaths = SystemPaths(directory: paths.directory, hosts: paths.hosts,
                                      daemon: root.appendingPathComponent("missing/expiry.plist"), isSandbox: true)
        let broken = SystemController(paths: brokenPaths)
        XCTAssertThrowsError(try broken.apply(BlockConfiguration(domains: ["reddit.com"], expiresAt: Date().addingTimeInterval(60)), helperSource: root))
        XCTAssertEqual(try String(contentsOf: paths.hosts), initialHosts)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.state.path))
    }

    func testFailedUpdateRestoresThePreviousBlock() throws {
        let previous = try BlockConfiguration(domains: ["youtube.com"])
        try controller.apply(previous, helperSource: root)
        let previousHosts = try String(contentsOf: paths.hosts)
        let brokenPaths = SystemPaths(directory: paths.directory, hosts: paths.hosts,
                                      daemon: root.appendingPathComponent("missing/expiry.plist"), isSandbox: true)
        XCTAssertThrowsError(try SystemController(paths: brokenPaths).apply(
            BlockConfiguration(domains: ["reddit.com"], expiresAt: Date().addingTimeInterval(60)), helperSource: root))
        XCTAssertEqual(try String(contentsOf: paths.hosts), previousHosts)
        XCTAssertEqual(try JSONDecoder().decode(BlockConfiguration.self, from: Data(contentsOf: paths.state)), previous)
    }

    func testSymlinkHostsAreRejectedWithoutChangingTheTarget() throws {
        let target = root.appendingPathComponent("target-hosts")
        try initialHosts.write(to: target, atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: paths.hosts)
        try FileManager.default.createSymbolicLink(at: paths.hosts, withDestinationURL: target)
        XCTAssertThrowsError(try controller.apply(BlockConfiguration(domains: ["reddit.com"]), helperSource: root))
        XCTAssertEqual(try String(contentsOf: target), initialHosts)
    }

    func testSchedulerUsesAnAbsoluteHelperPathAndFifteenSecondInterval() throws {
        try controller.apply(BlockConfiguration(domains: ["reddit.com"], expiresAt: Date().addingTimeInterval(60)), helperSource: root)
        let data = try Data(contentsOf: paths.daemon)
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        XCTAssertEqual(plist["ProgramArguments"] as? [String], [paths.helper.path, "--tick"])
        XCTAssertEqual(plist["StartInterval"] as? Int, 15)
        XCTAssertEqual(plist["RunAtLoad"] as? Bool, true)
    }
}
