import XCTest
@testable import BlockerCore

final class BlockGroupTests: XCTestCase {
    func testGroupsCombineAndExpireIndependently() throws {
        let now = Date(timeIntervalSince1970: 5000)
        let social = ActiveBlockGroup(id: UUID(), name: "Social", domains: ["reddit.com", "youtube.com"], expiresAt: now.addingTimeInterval(60))
        let news = ActiveBlockGroup(id: UUID(), name: "News", domains: ["reddit.com", "bbc.com"], expiresAt: now.addingTimeInterval(120))
        let configuration = try BlockConfiguration(groups: [social, news], startedAt: now)
        XCTAssertEqual(configuration.domains, ["bbc.com", "reddit.com", "youtube.com"])
        XCTAssertEqual(configuration.expiresAt, news.expiresAt)
        let afterSocial = try XCTUnwrap(configuration.removingExpiredGroups(at: now.addingTimeInterval(60)))
        XCTAssertEqual(afterSocial.groups?.map(\.id), [news.id])
        XCTAssertEqual(afterSocial.domains, ["bbc.com", "reddit.com"])
        XCTAssertNil(try configuration.removingExpiredGroups(at: now.addingTimeInterval(120)))
    }

    func testLegacyBlocksBecomeOneGroupWithoutChangingTheirTimer() throws {
        let end = Date(timeIntervalSince1970: 5000)
        let legacy = try BlockConfiguration(domains: ["reddit.com"], expiresAt: end)
        let restored = try JSONDecoder().decode(BlockConfiguration.self, from: JSONEncoder().encode(legacy)).validated()
        XCTAssertNil(restored.groups)
        XCTAssertEqual(restored.activeGroups[0].id, BlockGroup.legacyID)
        XCTAssertEqual(restored.activeGroups[0].expiresAt, end)
        XCTAssertEqual(restored.activeGroups[0].domains, legacy.domains)
    }

    func testAlwaysOnGroupSurvivesTimedGroupAndSerialization() throws {
        let permanent = ActiveBlockGroup(id: UUID(), name: "Work", domains: ["example.com"])
        let temporary = ActiveBlockGroup(id: UUID(), name: "News", domains: ["bbc.com"], expiresAt: Date(timeIntervalSince1970: 5000))
        let configuration = try BlockConfiguration(groups: [permanent, temporary])
        let restored = try JSONDecoder().decode(BlockConfiguration.self, from: JSONEncoder().encode(configuration)).validated()
        XCTAssertEqual(restored, configuration)
        XCTAssertNil(restored.expiresAt)
        let remaining = try XCTUnwrap(restored.removingExpiredGroups(at: .distantFuture))
        XCTAssertEqual(remaining.groups, [permanent])
        XCTAssertEqual(remaining.domains, ["example.com"])
    }

    func testForgedAggregateDuplicateGroupsAndEmptyActiveGroupsAreRejected() throws {
        let group = ActiveBlockGroup(id: UUID(), name: "Social", domains: ["reddit.com"])
        XCTAssertThrowsError(try BlockConfiguration(groups: [group, group]))
        XCTAssertThrowsError(try BlockConfiguration(groups: [ActiveBlockGroup(id: UUID(), name: "Empty", domains: [])]))
        let configuration = try BlockConfiguration(groups: [group])
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(configuration)) as? [String: Any])
        json["domains"] = ["other.com"]
        let forged = try JSONDecoder().decode(BlockConfiguration.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertThrowsError(try forged.validated())
        XCTAssertThrowsError(try BlockGroup(name: String(repeating: "x", count: 41)).validated())
        XCTAssertThrowsError(try BlockGroup(name: "Bad\nname").validated())
        XCTAssertThrowsError(try BlockGroup(name: "Social", durationMinutes: 2).validated())
    }
}
