import XCTest
@testable import BlockerCore

final class BlockerCoreTests: XCTestCase {
    func testPastedURLsNormalizeAndDeduplicate() throws {
        XCTAssertEqual(try Domain.parseList("https://WWW.YouTube.com/watch?v=abc, reddit.com\nYOUTUBE.COM."), ["reddit.com", "youtube.com"])
        XCTAssertEqual(try Domain.normalize("https://old.reddit.com/r/swift"), "old.reddit.com")
    }

    func testInvalidDomainsCannotBecomeHostsEntriesOrShellCommands() {
        for entry in ["localhost", "127.0.0.1", "a..com", "-bad.com", "bad-.com", "example.com\n127.0.0.1 malicious.com", "foo.com;touch", "foo.com$(id)", "*.reddit.com", "foo.local", "https://user:password@reddit.com", "file://example.com"] {
            XCTAssertThrowsError(try Domain.normalize(entry), entry)
        }
        XCTAssertThrowsError(try Domain.validate("reddit.com\n::1 anything.com"))
        XCTAssertThrowsError(try Domain.validate("UPPERCASE.COM"))
    }

    func testBlockRoundTripPreservesExistingContent() throws {
        let original = "## Host Database\n127.0.0.1 localhost\n::1 localhost\n\n# Another tool\n10.0.0.2 intranet.company.com\n"
        let blocked = try HostsFile.applying(["reddit.com"], to: original)
        XCTAssertTrue(blocked.contains("0.0.0.0 www.reddit.com\n::1 www.reddit.com"))
        XCTAssertEqual(try HostsFile.removingBlock(from: blocked), original)
        XCTAssertEqual(try HostsFile.applying(["reddit.com"], to: blocked), blocked)
    }

    func testUpdateReplacesOnlyOurSectionAndPreservesLaterEdits() throws {
        let original = "127.0.0.1 localhost\n"
        let blocked = try HostsFile.applying(["youtube.com"], to: original) + "192.168.1.2 added.elsewhere.com\n"
        let updated = try HostsFile.applying(["reddit.com"], to: blocked)
        XCTAssertFalse(updated.contains("youtube.com"))
        XCTAssertTrue(updated.contains("added.elsewhere.com"))
        XCTAssertEqual(try HostsFile.removingBlock(from: updated), original + "192.168.1.2 added.elsewhere.com\n")
    }

    func testMalformedMarkersFailInsteadOfDeletingUnrelatedLines() {
        for contents in [HostsFile.begin + "\n127.0.0.1 localhost\n", HostsFile.end + "\n", HostsFile.end + "\n" + HostsFile.begin,
                         HostsFile.begin + "\n" + HostsFile.begin + "\n" + HostsFile.end + "\n" + HostsFile.end] {
            XCTAssertThrowsError(try HostsFile.removingBlock(from: contents))
            XCTAssertThrowsError(try HostsFile.applying(["reddit.com"], to: contents))
        }
    }

    func testAlwaysOnAndAbsoluteExpirySurviveSerialization() throws {
        let started = Date(timeIntervalSince1970: 1000)
        let end = started.addingTimeInterval(1500)
        let timed = try BlockConfiguration(domains: ["reddit.com"], startedAt: started, expiresAt: end)
        let restored = try JSONDecoder().decode(BlockConfiguration.self, from: JSONEncoder().encode(timed))
        XCTAssertFalse(restored.isExpired(at: end.addingTimeInterval(-1)))
        XCTAssertTrue(restored.isExpired(at: end))
        XCTAssertTrue(restored.isExpired(at: end.addingTimeInterval(86400)))
        XCTAssertFalse(try BlockConfiguration(domains: ["reddit.com"]).isExpired(at: .distantFuture))
    }

    func testDecodedStateMustBeRevalidated() throws {
        let invalid = Data("{\"domains\":[\"bad.com\\n127.0.0.1 foo.com\"],\"startedAt\":0}".utf8)
        let decoded = try JSONDecoder().decode(BlockConfiguration.self, from: invalid)
        XCTAssertThrowsError(try decoded.validated())
    }
}
