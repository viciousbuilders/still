import XCTest
@testable import BlockerCore

final class FocusSessionTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 5000)
    private func plan(rounds: Int = 4) -> FocusPlan {
        FocusPlan(group: ActiveBlockGroup(id: UUID(), name: "Study", domains: ["instagram.com"]), ownerID: 501, rounds: rounds)
    }

    func testExactFocusBreakAndLongBreakBoundaries() throws {
        let session = try FocusSession(plan: plan(), startedAt: start, uptime: 0)
        XCTAssertEqual(session.phase(at: start).kind, .focus)
        XCTAssertEqual(session.phase(at: start.addingTimeInterval(1499)).kind, .focus)
        XCTAssertEqual(session.phase(at: start.addingTimeInterval(1500)).kind, .rest)
        XCTAssertEqual(session.phase(at: start.addingTimeInterval(1800)).round, 1)
        XCTAssertEqual(session.phase(at: start.addingTimeInterval(1800)).kind, .focus)
        let finalBreak = session.phase(at: start.addingTimeInterval(6900))
        XCTAssertEqual(finalBreak.kind, .rest)
        XCTAssertEqual(finalBreak.round, 3)
        XCTAssertEqual(finalBreak.endsAt.timeIntervalSince(finalBreak.startedAt), 900)
        XCTAssertEqual(session.phase(at: start.addingTimeInterval(7800)).kind, .finished)
    }

    func testOnlyAwakeProtectedFocusCountsAndBreaksEarnNothing() throws {
        var session = try FocusSession(plan: plan(rounds: 2), startedAt: start, uptime: 0)
        for second in 1...1800 { session.advance(to: start.addingTimeInterval(Double(second)), uptime: Double(second)) }
        XCTAssertEqual(session.focusSeconds, [1500, 0])
        session.advance(to: start.addingTimeInterval(1801), uptime: 1801, isProtected: false)
        XCTAssertEqual(session.focusSeconds[1], 0)
        session.advance(to: start.addingTimeInterval(1802), uptime: 1802)
        XCTAssertEqual(session.focusSeconds[1], 1)
        var garden = FocusGarden(); garden.merge(session.records)
        XCTAssertEqual(garden.treeCount, 1)
        XCTAssertEqual(garden.focusSeconds, 1501)
    }

    func testSleepRestartAndClockJumpsNeverEarnFocus() throws {
        var session = try FocusSession(plan: plan(), startedAt: start, uptime: 100)
        session.advance(to: start.addingTimeInterval(5), uptime: 105)
        XCTAssertEqual(session.focusSeconds[0], 5)
        session.advance(to: start.addingTimeInterval(600), uptime: 106) // Sleep.
        session.advance(to: start.addingTimeInterval(605), uptime: 1) // Restart.
        session.advance(to: start.addingTimeInterval(620), uptime: 16) // Unobserved gap.
        session.advance(to: start.addingTimeInterval(-10), uptime: 17) // Clock rollback.
        XCTAssertEqual(session.focusSeconds[0], 5)
        _ = try session.validated()
    }

    func testPartialProgressCarriesForwardAndMergesAreIdempotent() {
        var garden = FocusGarden()
        let first = FocusRecord(id: "first", date: start, seconds: 600, targetSeconds: 1500)
        garden.merge([first]); garden.merge([first])
        XCTAssertEqual(garden.focusSeconds, 600)
        XCTAssertEqual(garden.saplingProgress, 0.4, accuracy: 0.001)
        garden.merge([FocusRecord(id: "second", date: start, seconds: 900, targetSeconds: 1500)])
        XCTAssertEqual(garden.treeCount, 1)
        XCTAssertEqual(garden.focusSeconds, 1500)
        garden.merge([FocusRecord(id: "first", date: start, seconds: 500, targetSeconds: 1500)])
        XCTAssertEqual(garden.focusSeconds, 1500)
    }

    func testInvalidAndForgedPlansAreRejected() throws {
        let group = ActiveBlockGroup(id: UUID(), name: "Study", domains: ["instagram.com"])
        for plan in [FocusPlan(group: group, ownerID: 0), FocusPlan(group: group, ownerID: 501, rounds: 99),
                     FocusPlan(group: group, ownerID: 501, focusMinutes: 1),
                     FocusPlan(group: group, ownerID: 501, focusMinutes: 50, breakMinutes: 5)] {
            XCTAssertThrowsError(try plan.validated())
        }
        let session = try FocusSession(plan: plan(), startedAt: start, uptime: 0)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(session)) as? [String: Any])
        json["focusSeconds"] = [9999999]
        let forged = try JSONDecoder().decode(FocusSession.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertThrowsError(try forged.validated())
    }
}
