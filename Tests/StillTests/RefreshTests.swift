import XCTest
import Combine
import BlockerCore
@testable import Still

final class RefreshTests: XCTestCase {
    @MainActor func testUnchangedDiskStateDoesNotPublishAnyModelUpdates() throws {
        let fixture = try StateFixture()
        defer { fixture.cleanUp() }
        let model = fixture.makeModel()
        var appUpdates = 0, focusUpdates = 0
        let app = model.objectWillChange.sink { appUpdates += 1 }
        let focus = model.focus.objectWillChange.sink { focusUpdates += 1 }
        withExtendedLifetime((app, focus)) {
            for _ in 0..<10 { model.refresh() }
            XCTAssertEqual(appUpdates, 0)
            XCTAssertEqual(focusUpdates, 0)
        }
        XCTAssertTrue(model.active)
        XCTAssertEqual(model.focus.session, fixture.session)
        XCTAssertEqual(model.focus.garden.records.count, 1)
    }

    @MainActor func testAtomicFocusCheckpointsAndRemovalReachTheModelWithoutPolling() async throws {
        let fixture = try StateFixture()
        defer { fixture.cleanUp() }
        let model = fixture.makeModel()
        var session = fixture.session
        // Two replacements verify that the watch survives an inode changing.
        for seconds in [5.0, 10.0] {
            session.advance(to: session.startedAt.addingTimeInterval(seconds), uptime: seconds)
            let updated = expectation(description: "Focus checkpoint \(seconds)")
            let observation = model.focus.$session.dropFirst().first().sink {
                XCTAssertEqual($0, session)
                updated.fulfill()
            }
            try fixture.write(session, to: "focus.json")
            await fulfillment(of: [updated], timeout: 3)
            withExtendedLifetime(observation) {}
            XCTAssertEqual(model.focus.session, session)
        }
        let removed = expectation(description: "Focus removal")
        let observation = model.focus.$session.dropFirst().first().sink {
            XCTAssertNil($0)
            removed.fulfill()
        }
        try FileManager.default.removeItem(at: fixture.directory.appendingPathComponent("focus.json"))
        await fulfillment(of: [removed], timeout: 3)
        withExtendedLifetime(observation) {}
        XCTAssertNil(model.focus.session)
    }

    @MainActor func testMonitorFindsANewStateDirectoryAndItsSubsequentWrites() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("Still")
        let file = directory.appendingPathComponent("active.json")
        let created = expectation(description: "New directory")
        let replaced = expectation(description: "New directory contents")
        var sawCreation = false, sawReplacement = false
        let monitor = StateMonitor(directories: [directory]) {
            if !sawCreation && FileManager.default.fileExists(atPath: directory.path) {
                sawCreation = true; created.fulfill()
            }
            if !sawReplacement && (try? String(contentsOf: file)) == "replacement" {
                sawReplacement = true; replaced.fulfill()
            }
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        await fulfillment(of: [created], timeout: 3)
        try "replacement".write(to: file, atomically: true, encoding: .utf8)
        await fulfillment(of: [replaced], timeout: 3)
        withExtendedLifetime(monitor) {}
    }

    func testStatusPresentationChangesOnlyWithVisibleCountdownOrBlockingState() throws {
        let start = Date()
        let idle = StatusPresentation(active: true, session: nil, now: start)
        XCTAssertEqual(idle, StatusPresentation(active: true, session: nil, now: start.addingTimeInterval(60)))
        XCTAssertFalse(idle.countingDown)
        XCTAssertNotEqual(idle, StatusPresentation(active: false, session: nil, now: start))
        let group = ActiveBlockGroup(id: UUID(), name: "Study", domains: ["example.com"])
        let plan = FocusPlan(group: group, ownerID: getuid(), rounds: 1)
        let session = try FocusSession(plan: plan, startedAt: start, uptime: 0)
        let initial = StatusPresentation(active: true, session: session, now: start)
        XCTAssertEqual(initial.title, " 25:00")
        XCTAssertEqual(initial, StatusPresentation(active: true, session: session, now: start.addingTimeInterval(0.1)))
        XCTAssertEqual(StatusPresentation(active: true, session: session, now: start.addingTimeInterval(1)).title, " 24:59")
        let rest = StatusPresentation(active: false, session: session, now: start.addingTimeInterval(1500))
        XCTAssertEqual(rest.title, " 5:00")
        XCTAssertTrue(rest.detail.contains("Break"))
        let finished = StatusPresentation(active: false, session: session, now: start.addingTimeInterval(1800))
        XCTAssertEqual(finished.title, "")
        XCTAssertFalse(finished.countingDown)
    }
}

private struct StateFixture {
    let directory: URL
    let defaults: UserDefaults
    let suite: String
    let session: FocusSession

    init() throws {
        suite = "still-refresh-tests-\(UUID())"
        defaults = UserDefaults(suiteName: suite)!
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let group = BlockGroup(name: "Study", domains: ["example.com"])
        defaults.set(try JSONEncoder().encode([group]), forKey: "groups")
        let active = ActiveBlockGroup(id: group.id, name: group.name, domains: group.domains)
        session = try FocusSession(plan: FocusPlan(group: active, ownerID: getuid()), uptime: 0)
        try write(BlockConfiguration(groups: [active]), to: "active.json")
        try write(session, to: "focus.json")
        var garden = FocusGarden()
        var previous = try FocusSession(plan: FocusPlan(group: active, ownerID: getuid()),
                                        startedAt: Date().addingTimeInterval(-3600), uptime: 0)
        previous.advance(to: previous.startedAt.addingTimeInterval(5), uptime: 5)
        garden.merge(previous.records)
        try write(garden, to: "garden-\(getuid()).json")
        try HostsFile.applying(group.domains, to: "127.0.0.1 localhost\n")
            .write(to: directory.appendingPathComponent("hosts"), atomically: true, encoding: .utf8)
    }

    @MainActor func makeModel() -> AppModel {
        AppModel(defaults: defaults, stateDirectory: directory, hostsURL: directory.appendingPathComponent("hosts"))
    }

    func write<T: Encodable>(_ value: T, to name: String) throws {
        try JSONEncoder().encode(value).write(to: directory.appendingPathComponent(name), options: .atomic)
    }

    func cleanUp() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
}
