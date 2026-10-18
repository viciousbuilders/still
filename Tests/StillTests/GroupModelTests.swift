import XCTest
import BlockerCore
@testable import Still

final class GroupModelTests: XCTestCase {
    @MainActor func testFocusCycleControlsOnlyStudyAndCannotBeOverriddenByGroupToggle() async throws {
        let model = AppModel(demo: true)
        let permanent = model.selectedGroupID
        await model.start()
        let study = model.groups[1].id
        model.focus.groupID = study
        await model.startFocus()
        XCTAssertNotNil(model.focus.session)
        XCTAssertTrue(model.groupIsActive(permanent))
        XCTAssertTrue(model.groupIsActive(study))
        model.selectGroup(study)
        await model.stop()
        XCTAssertTrue(model.groupIsActive(study))
        let session = try XCTUnwrap(model.focus.session)
        let duringBreak = session.startedAt.addingTimeInterval(1500)
        model.configuration = model.focus.advanceDemo(configuration: model.configuration, now: duringBreak)
        XCTAssertTrue(model.groupIsActive(permanent))
        XCTAssertFalse(model.groupIsActive(study))
        let count = model.groups.count
        model.deleteSelectedGroup()
        XCTAssertEqual(model.groups.count, count)
        await model.endFocus()
        XCTAssertNil(model.focus.session)
        XCTAssertTrue(model.groupIsActive(permanent))
        XCTAssertFalse(model.groupIsActive(study))
    }

    func testLegacyPreferencesMigrateAndSavedGroupsKeepTheirIdentityAndDuration() throws {
        let suite = "still-group-tests-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["reddit.com", "youtube.com"], forKey: "websites")
        defaults.set("Timer", forKey: "mode")
        defaults.set(50, forKey: "duration")
        let migrated = GroupPreferences.load(from: defaults)
        XCTAssertEqual(migrated.count, 1)
        XCTAssertEqual(migrated[0].id, BlockGroup.legacyID)
        XCTAssertEqual(migrated[0].domains, ["reddit.com", "youtube.com"])
        XCTAssertEqual(migrated[0].durationMinutes, 50)
        let news = BlockGroup(name: "News", domains: ["bbc.com"], durationMinutes: 90)
        defaults.set(try JSONEncoder().encode(migrated + [news]), forKey: "groups")
        XCTAssertEqual(GroupPreferences.load(from: defaults), migrated + [news])
    }

    @MainActor func testGroupsBlockIndependentlyAndKeepOtherGroupsAppliedSnapshot() async throws {
        let model = AppModel(demo: true)
        model.input = "reddit.com"; model.addWebsites()
        let social = model.selectedGroupID
        await model.start()
        XCTAssertTrue(model.selectedGroupActive)
        model.removeWebsite("reddit.com") // An unapplied draft must not leak into another group's change.
        XCTAssertTrue(model.hasChanges)
        let news = model.groups[1].id
        model.selectGroup(news)
        XCTAssertFalse(model.selectedGroupActive)
        model.input = "reddit.com"
        model.addWebsites()
        model.duration = 25
        await model.start()
        XCTAssertEqual(model.activeGroupCount, 2)
        XCTAssertTrue(try XCTUnwrap(model.configuration).domains.contains("reddit.com"))
        let newsExpiry = model.selectedActiveGroup?.expiresAt
        model.input = "example.com"; model.addWebsites()
        await model.start(update: true)
        XCTAssertEqual(model.selectedActiveGroup?.expiresAt, newsExpiry)
        await model.stop()
        XCTAssertFalse(model.selectedGroupActive)
        XCTAssertTrue(model.active)
        XCTAssertEqual(model.activeGroupCount, 1)
        XCTAssertTrue(try XCTUnwrap(model.configuration).domains.contains("reddit.com"))
        XCTAssertFalse(try XCTUnwrap(model.configuration).domains.contains("example.com"))
        model.selectGroup(social)
        XCTAssertTrue(model.hasChanges)
        await model.start(update: true)
        XCTAssertFalse(try XCTUnwrap(model.configuration).domains.contains("reddit.com"))
        await model.stop()
        XCTAssertFalse(model.active)
        XCTAssertNil(model.configuration)
    }

    @MainActor func testCreatingRenamingAndDeletingGroupsPreservesActiveGroups() async {
        let model = AppModel(demo: true)
        let original = model.selectedGroupID
        XCTAssertFalse(model.saveGroup(name: " Always blocked ", creating: true))
        XCTAssertNotNil(model.groupError)
        XCTAssertFalse(model.saveGroup(name: "\n", creating: true))
        XCTAssertTrue(model.saveGroup(name: "Video", creating: true))
        XCTAssertEqual(model.selectedGroup.name, "Video")
        model.input = "youtube.com"; model.addWebsites()
        await model.start()
        let count = model.groups.count
        model.deleteSelectedGroup()
        XCTAssertEqual(model.groups.count, count)
        XCTAssertTrue(model.saveGroup(name: "Streaming", creating: false))
        XCTAssertTrue(model.hasChanges)
        await model.stop()
        model.deleteSelectedGroup()
        XCTAssertEqual(model.groups.count, count - 1)
        XCTAssertEqual(model.selectedGroupID, original)
    }

    @MainActor func testStopAllAndSelectionWhileBusy() async {
        let model = AppModel(demo: true)
        await model.start()
        let first = model.selectedGroupID
        model.busy = true
        model.selectGroup(model.groups[1].id)
        XCTAssertEqual(model.selectedGroupID, first)
        XCTAssertFalse(model.saveGroup(name: "Busy", creating: true))
        model.busy = false
        model.selectGroup(model.groups[1].id)
        await model.start()
        await model.stopAll()
        XCTAssertFalse(model.active)
        XCTAssertEqual(model.groups.count, 2)
    }
}
