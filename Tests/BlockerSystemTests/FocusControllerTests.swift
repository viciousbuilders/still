import XCTest
import BlockerCore
@testable import BlockerSystem

final class FocusControllerTests: XCTestCase {
    private var root: URL!
    private var paths: SystemPaths!
    private var controller: SystemController!
    private let start = Date(timeIntervalSince1970: 5000)
    private let hosts = "127.0.0.1 localhost\n::1 localhost\n"
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("still-focus-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        paths = .sandbox(root); controller = SystemController(paths: paths)
        try hosts.write(to: paths.hosts, atomically: true, encoding: .utf8)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    private func plan(rounds: Int = 2) -> FocusPlan {
        FocusPlan(group: ActiveBlockGroup(id: UUID(), name: "Study", domains: ["instagram.com"]), ownerID: 501, rounds: rounds)
    }
    private func readState() throws -> BlockConfiguration {
        try JSONDecoder().decode(BlockConfiguration.self, from: Data(contentsOf: paths.state))
    }

    func testAutomaticBreaksPreserveAlwaysOnAndReblockStudy() throws {
        let permanent = ActiveBlockGroup(id: UUID(), name: "Always blocked", domains: ["facebook.com", "tiktok.com"])
        try controller.apply(BlockConfiguration(groups: [permanent]), helperSource: root, now: start)
        let plan = plan()
        try controller.startFocus(plan, helperSource: root, now: start, uptime: 0)
        XCTAssertTrue(try readState().domains.contains("instagram.com"))
        XCTAssertThrowsError(try controller.startFocus(plan, helperSource: root, now: start, uptime: 0))
        try controller.tick(now: start.addingTimeInterval(1500), uptime: 1500)
        XCTAssertEqual(try readState().domains, ["facebook.com", "tiktok.com"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.focus.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.daemon.path))
        // A fresh controller stands in for the helper after app quit/restart.
        let fresh = SystemController(paths: paths)
        try fresh.tick(now: start.addingTimeInterval(1800), uptime: 1800)
        XCTAssertTrue(try readState().domains.contains("instagram.com"))
        try fresh.tick(now: start.addingTimeInterval(3600), uptime: 3600)
        XCTAssertEqual(try readState().domains, ["facebook.com", "tiktok.com"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.focus.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.daemon.path))
    }

    func testBreakWithNoOtherGroupsKeepsSchedulerAndFinishesCleanly() throws {
        let plan = plan(rounds: 1)
        try controller.startFocus(plan, helperSource: root, now: start, uptime: 0)
        try controller.tick(now: start.addingTimeInterval(1500), uptime: 1500)
        XCTAssertEqual(try String(contentsOf: paths.hosts), hosts)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.state.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.daemon.path))
        try controller.tick(now: start.addingTimeInterval(1800), uptime: 1800)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.focus.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.daemon.path))
    }

    func testEarlyEndSavesPartialGardenAndOnlyRemovesStudy() throws {
        let permanent = ActiveBlockGroup(id: UUID(), name: "Always blocked", domains: ["facebook.com"])
        try controller.apply(BlockConfiguration(groups: [permanent]), helperSource: root, now: start)
        let plan = plan()
        try controller.startFocus(plan, helperSource: root, now: start, uptime: 0)
        for second in 1...60 { try controller.tick(now: start.addingTimeInterval(Double(second)), uptime: Double(second)) }
        XCTAssertThrowsError(try controller.endFocus(sessionID: UUID(), now: start.addingTimeInterval(61), uptime: 61))
        try controller.endFocus(sessionID: plan.id, now: start.addingTimeInterval(61), uptime: 61)
        XCTAssertEqual(try readState().domains, ["facebook.com"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.focus.path))
        let garden = try JSONDecoder().decode(FocusGarden.self, from: Data(contentsOf: paths.garden(userID: 501)))
        XCTAssertEqual(garden.focusSeconds, 61, accuracy: 0.01)
        XCTAssertEqual(garden.treeCount, 0)
        XCTAssertGreaterThan(garden.saplingProgress, 0)
    }

    func testFailedStartRollsBackBlockAndNeverLeavesAnAutomaticSchedule() throws {
        let badPaths = SystemPaths(directory: paths.directory, hosts: paths.hosts,
                                   daemon: root.appendingPathComponent("missing/expiry.plist"), isSandbox: true)
        XCTAssertThrowsError(try SystemController(paths: badPaths).startFocus(plan(), helperSource: root, now: start, uptime: 0))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.focus.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.state.path))
        XCTAssertEqual(try String(contentsOf: paths.hosts), hosts)
    }

    func testStopAllCancelsFutureTransitions() throws {
        try controller.startFocus(plan(), helperSource: root, now: start, uptime: 0)
        try controller.remove()
        try controller.tick(now: start.addingTimeInterval(1800), uptime: 1800)
        XCTAssertEqual(try String(contentsOf: paths.hosts), hosts)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.focus.path))
    }

    func testCompletedFocusPlantsOneTreeAndBreakDoesNotAddTime() throws {
        try controller.startFocus(plan(rounds: 1), helperSource: root, now: start, uptime: 0)
        for second in stride(from: 5, through: 1500, by: 5) {
            try controller.tick(now: start.addingTimeInterval(Double(second)), uptime: Double(second))
        }
        let url = paths.garden(userID: 501)
        let first = try JSONDecoder().decode(FocusGarden.self, from: Data(contentsOf: url))
        XCTAssertEqual(first.focusSeconds, 1500, accuracy: 0.001)
        XCTAssertEqual(first.treeCount, 1)
        try SystemController(paths: paths).tick(now: start.addingTimeInterval(1800), uptime: 1800)
        let final = try JSONDecoder().decode(FocusGarden.self, from: Data(contentsOf: url))
        XCTAssertEqual(final, first)
    }

    func testUnknownExistingBlockCannotBeReplacedByAFocusCycle() throws {
        let existing = try HostsFile.applying(["facebook.com"], to: hosts)
        try existing.write(to: paths.hosts, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try controller.startFocus(plan(), helperSource: root, now: start, uptime: 0))
        XCTAssertEqual(try String(contentsOf: paths.hosts), existing)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.focus.path))
    }
}
