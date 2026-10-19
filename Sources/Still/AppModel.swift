import AppKit
import Combine
import SwiftUI
import ServiceManagement
import BlockerCore
import BlockerAuthorization

enum BlockMode: String, CaseIterable { case timer = "Timer", always = "Always on" }

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var groups: [BlockGroup] = []
    @Published private(set) var selectedGroupID = BlockGroup.legacyID
    @Published var input = ""
    @Published var configuration: BlockConfiguration?
    @Published var hasHostsBlock = false
    @Published var busy = false
    @Published var error: String?
    @Published var inputError: String?
    @Published var groupError: String?
    @Published var settingsError: String?
    @Published var loginStatus = SMAppService.Status.notRegistered
    @Published var showSettings = false
    let isDemo: Bool
    let focus: FocusModel
    private var stateMonitor: StateMonitor?
    private var demoTimer: Timer?
    private var demoSubscription: AnyCancellable?
    private let defaults: UserDefaults
    private let stateDirectory: URL
    private let hostsURL: URL

    init(demo: Bool = false, defaults: UserDefaults = .standard,
         stateDirectory: URL = URL(fileURLWithPath: "/Library/Application Support/Still", isDirectory: true),
         hostsURL: URL = URL(fileURLWithPath: "/private/etc/hosts")) {
        isDemo = demo; self.defaults = defaults
        self.stateDirectory = stateDirectory; self.hostsURL = hostsURL
        focus = FocusModel(demo: demo, defaults: defaults, directory: stateDirectory)
        if demo {
            groups = [BlockGroup(id: BlockGroup.legacyID, name: "Always blocked", domains: ["facebook.com", "threads.com", "tiktok.com"]),
                      BlockGroup(name: "Study", domains: ["instagram.com", "linkedin.com", "x.com"])]
        } else {
            groups = GroupPreferences.load(from: defaults)
            refresh()
            if let savedID = defaults.string(forKey: "selectedGroupID").flatMap(UUID.init(uuidString:)),
               groups.contains(where: { $0.id == savedID }) { selectedGroupID = savedID }
            else { selectedGroupID = groups[0].id }
            savePreferences()
        }
        focus.refresh(groups: groups)
        if demo {
            demoSubscription = focus.$session.map { $0 != nil }.removeDuplicates().sink { [weak self] running in
                self?.updateDemoTimer(running: running)
            }
        } else {
            refreshLoginStatus()
            stateMonitor = StateMonitor(directories: [stateDirectory, hostsURL.deletingLastPathComponent()]) { [weak self] in
                self?.refresh()
            }
        }
    }

    deinit { demoTimer?.invalidate() }

    private func updateDemoTimer(running: Bool) {
        demoTimer?.invalidate(); demoTimer = nil
        guard running else { return }
        demoTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        demoTimer?.tolerance = 0.1
    }

    var selectedGroup: BlockGroup { groups.first { $0.id == selectedGroupID } ?? groups[0] }
    var websites: [String] { selectedGroup.domains }
    var mode: BlockMode {
        get { selectedGroup.durationMinutes == nil ? .always : .timer }
        set { editSelected { $0.durationMinutes = newValue == .always ? nil : 25 } }
    }
    var duration: Int {
        get { selectedGroup.durationMinutes ?? 25 }
        set { editSelected { $0.durationMinutes = newValue } }
    }
    var active: Bool { hasHostsBlock }
    var activeGroupCount: Int { active ? (configuration?.activeGroups.count ?? 1) : 0 }
    var selectedActiveGroup: ActiveBlockGroup? {
        guard active else { return nil }
        return configuration?.activeGroups.first { $0.id == selectedGroupID }
    }
    func groupIsActive(_ id: UUID) -> Bool {
        guard active else { return false }
        return configuration?.activeGroups.contains { $0.id == id } ?? (id == groups[0].id)
    }
    var selectedGroupActive: Bool { groupIsActive(selectedGroupID) }
    var needsFirewallUpgrade: Bool {
        active && !isDemo && !FileManager.default.fileExists(atPath: stateDirectory.appendingPathComponent("firewall.json").path)
    }
    var hasChanges: Bool {
        guard let applied = selectedActiveGroup else { return false }
        return needsFirewallUpgrade || websites.sorted() != applied.domains.sorted() || selectedGroup.name != applied.name
    }
    func statusDetail(at now: Date = Date()) -> String {
        guard selectedGroupActive else { return "\(websites.count) websites ready to block." }
        guard let end = selectedActiveGroup?.expiresAt else { return "Until you unblock it" }
        let seconds = max(0, Int(ceil(end.timeIntervalSince(now))))
        if seconds == 0 { return "Ending… allow up to 15 seconds" }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    func refresh() {
        guard !busy else { return }
        if isDemo {
            let next = focus.advanceDemo(configuration: configuration, now: Date())
            if configuration != next { configuration = next }
            if hasHostsBlock != (configuration != nil) { hasHostsBlock = configuration != nil }
            focus.refresh(groups: groups)
            return
        }
        let contents = try? String(contentsOf: hostsURL, encoding: .utf8)
        let blocked = contents.map(HostsFile.containsBlock) ?? false
        if hasHostsBlock != blocked { hasHostsBlock = blocked }
        let next = (try? Data(contentsOf: stateDirectory.appendingPathComponent("active.json")))
            .flatMap { try? JSONDecoder().decode(BlockConfiguration.self, from: $0).validated() }
        if configuration != next { configuration = next }
        // Recover active groups if local preferences were removed or this user
        // opens a block started by a previous version of the app.
        if active, let configuration {
            for applied in configuration.activeGroups where !groups.contains(where: { $0.id == applied.id }) {
                groups.append(BlockGroup(id: applied.id, name: applied.name, domains: applied.domains))
            }
            if configuration.groups == nil, groups.count == 1, groups[0].domains.isEmpty {
                groups[0].domains = configuration.domains
            }
        }
        focus.refresh(groups: groups)
    }

    func refreshLoginStatus() {
        guard !isDemo else { return }
        let status = SMAppService.mainApp.status
        if loginStatus != status { loginStatus = status }
    }

    func selectGroup(_ id: UUID) {
        guard !busy, groups.contains(where: { $0.id == id }) else { return }
        selectedGroupID = id; input = ""; inputError = nil; error = nil; groupError = nil
        savePreferences()
    }

    @discardableResult func saveGroup(name: String, creating: Bool) -> Bool {
        guard !busy else { return false }
        do {
            let candidate = try BlockGroup(name: name).validated()
            guard !groups.contains(where: { $0.name.localizedCaseInsensitiveCompare(candidate.name) == .orderedSame && (creating || $0.id != selectedGroupID) }) else {
                throw AdminError.failed("A group with that name already exists.")
            }
            if creating {
                guard groups.count < 50 else { throw BlockError.invalidGroup }
                groups.append(candidate)
                selectGroup(candidate.id)
            } else { editSelected { $0.name = candidate.name } }
            groupError = nil; savePreferences(); return true
        } catch { groupError = error.localizedDescription; return false }
    }

    func deleteSelectedGroup() {
        guard !busy, groups.count > 1, !selectedGroupActive, !groupIsManagedByTimer(selectedGroupID) else { return }
        groups.removeAll { $0.id == selectedGroupID }
        selectGroup(groups[0].id)
    }

    func addWebsites() {
        guard !busy else { return }
        do {
            let combined = Array(Set(websites + (try Domain.parseList(input)))).sorted()
            guard combined.count <= 500 else { throw BlockError.emptyList }
            editSelected { $0.domains = combined }
            input = ""; inputError = nil; error = nil; savePreferences()
        } catch { inputError = error.localizedDescription }
    }

    func removeWebsite(_ domain: String) {
        guard !busy else { return }
        editSelected { $0.domains.removeAll { $0 == domain } }
        savePreferences()
    }

    private func editSelected(_ edit: (inout BlockGroup) -> Void) {
        guard let index = groups.firstIndex(where: { $0.id == selectedGroupID }) else { return }
        edit(&groups[index])
    }

    func savePreferences() {
        guard !isDemo else { return }
        if let data = try? JSONEncoder().encode(groups) { defaults.set(data, forKey: "groups") }
        defaults.set(selectedGroupID.uuidString, forKey: "selectedGroupID")
    }

    private var studyDomains: [String] {
        guard groups.count == 1 else { return [] }
        let study = ["instagram.com", "linkedin.com", "x.com", "twitter.com"]
        return groups[0].domains.filter { domain in study.contains { domain == $0 || domain.hasSuffix("." + $0) } }
    }
    var canCreateStudySetup: Bool {
        groups.count == 1 && !studyDomains.isEmpty && studyDomains.count < groups[0].domains.count && focus.session == nil
    }
    var studySetupPreview: (always: [String], study: [String]) {
        (groups[0].domains.filter { !studyDomains.contains($0) }, studyDomains)
    }

    func createStudySetup() async {
        guard !busy, canCreateStudySetup else { return }
        busy = true; focus.error = nil
        defer { busy = false; refresh() }
        do {
            let original = groups[0]
            let preview = studySetupPreview
            let permanent = BlockGroup(name: "Always blocked", domains: preview.always)
            let study = BlockGroup(name: "Study", domains: preview.study)
            if groupIsActive(original.id) {
                guard configuration != nil else { throw AdminError.failed("Unblock the existing block first. Its saved groups could not be read.") }
                let others = configuration?.activeGroups.filter { $0.id != original.id && !$0.isExpired(at: Date()) } ?? []
                let next = try BlockConfiguration(groups: others + [ActiveBlockGroup(id: permanent.id, name: permanent.name, domains: permanent.domains)])
                if isDemo { configuration = next }
                else { try await TouchIDAuthorization.perform(helper: helperURL(), action: .apply, configuration: next) }
            }
            groups = [permanent, study]; selectedGroupID = permanent.id
            focus.groupID = study.id; focus.savePreferences(); savePreferences()
        } catch { focus.error = error.localizedDescription }
    }

    func start(update: Bool = false) async {
        guard !busy, !groupIsManagedByTimer(selectedGroupID) else { return }
        guard !active || configuration != nil else {
            error = "Unblock the existing block before starting a group. Its saved configuration could not be read."
            return
        }
        do {
            let expiry = update ? selectedActiveGroup?.expiresAt : (mode == .timer ? Date().addingTimeInterval(Double(duration * 60)) : nil)
            let group = ActiveBlockGroup(id: selectedGroupID, name: selectedGroup.name, domains: websites, expiresAt: expiry)
            let next = try BlockConfiguration(groups: otherActiveGroups + [group])
            try await apply(next)
        } catch { self.error = error.localizedDescription }
    }

    func stop() async {
        guard !busy, selectedGroupActive, !groupIsManagedByTimer(selectedGroupID) else { return }
        do {
            let others = otherActiveGroups
            try await apply(others.isEmpty ? nil : BlockConfiguration(groups: others))
        } catch { self.error = error.localizedDescription }
    }

    func stopAll() async {
        guard !busy else { return }
        do { try await apply(nil) } catch { self.error = error.localizedDescription }
    }

    private var otherActiveGroups: [ActiveBlockGroup] {
        guard active else { return [] }
        return configuration?.activeGroups.filter { $0.id != selectedGroupID && !$0.isExpired(at: Date()) } ?? []
    }

    private func apply(_ next: BlockConfiguration?) async throws {
        busy = true; error = nil
        defer { busy = false; refresh() }
        if isDemo {
            if next == nil { focus.endDemo() }
            configuration = next; hasHostsBlock = next != nil
        }
        else { try await TouchIDAuthorization.perform(helper: helperURL(), action: next == nil ? .remove : .apply, configuration: next) }
        savePreferences()
    }

    func setLogin(_ enabled: Bool) {
        guard !isDemo else { return }
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            refreshLoginStatus(); settingsError = nil
        } catch { settingsError = error.localizedDescription }
    }

    func helperURL() throws -> URL {
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/StillHelper")
        guard FileManager.default.isExecutableFile(atPath: bundled.path) else {
            throw AdminError.failed("The helper is missing. Build the app with ./scripts/build.sh, then open dist/Still.app.")
        }
        return bundled
    }
}
