import AppKit
import SwiftUI
import ServiceManagement
import BlockerCore

enum BlockMode: String, CaseIterable { case timer = "Timer", always = "Always on" }

@MainActor
final class AppModel: ObservableObject {
    @Published var websites: [String] = []
    @Published var input = ""
    @Published var mode: BlockMode = .always
    @Published var duration = 25
    @Published var configuration: BlockConfiguration?
    @Published var hasHostsBlock = false
    @Published var busy = false
    @Published var error: String?
    @Published var inputError: String?
    @Published var settingsError: String?
    @Published var now = Date()
    @Published var loginStatus = SMAppService.mainApp.status
    @Published var showSettings = false
    let isDemo: Bool
    private var poller: Timer?
    private let defaults = UserDefaults.standard
    private static let stateURL = URL(fileURLWithPath: "/Library/Application Support/Still/active.json")

    init(demo: Bool = false) {
        isDemo = demo
        if demo { websites = ["instagram.com", "reddit.com", "youtube.com"] }
        else {
            websites = defaults.stringArray(forKey: "websites") ?? []
            mode = BlockMode(rawValue: defaults.string(forKey: "mode") ?? "") ?? .always
            duration = [25, 50, 90].contains(defaults.integer(forKey: "duration")) ? defaults.integer(forKey: "duration") : 25
            refresh()
            if websites.isEmpty, let configuration { websites = configuration.domains }
        }
        poller = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
    }

    var active: Bool { hasHostsBlock }
    var hasChanges: Bool {
        guard let configuration else { return false }
        return websites.sorted() != configuration.domains.sorted()
    }
    var statusDetail: String {
        guard active else { return websites.isEmpty ? "Add websites to your blocklist." : "\(websites.count) \(websites.count == 1 ? "website" : "websites") ready to block." }
        guard let configuration else { return "Stop the existing block below." }
        guard let end = configuration.expiresAt else { return "Always on · until you turn it off" }
        let seconds = max(0, Int(ceil(end.timeIntervalSince(now))))
        if seconds == 0 { return "Ending session… allow up to 15 seconds" }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    func refresh() {
        now = Date()
        guard !busy else { return }
        if isDemo {
            if configuration?.isExpired(at: now) == true { configuration = nil; hasHostsBlock = false }
            return
        }
        let contents = try? String(contentsOfFile: "/private/etc/hosts", encoding: .utf8)
        hasHostsBlock = contents.map(HostsFile.containsBlock) ?? false
        if let data = try? Data(contentsOf: Self.stateURL) {
            configuration = try? JSONDecoder().decode(BlockConfiguration.self, from: data).validated()
        } else { configuration = nil }
        loginStatus = SMAppService.mainApp.status
    }

    func addWebsites() {
        do {
            let added = try Domain.parseList(input)
            let combined = Array(Set(websites + added)).sorted()
            guard combined.count <= 500 else { throw BlockError.emptyList }
            websites = combined; input = ""; inputError = nil; error = nil
            savePreferences()
        } catch { self.inputError = error.localizedDescription }
    }

    func removeWebsite(_ domain: String) {
        websites.removeAll { $0 == domain }
        savePreferences()
    }

    func savePreferences() {
        guard !isDemo else { return }
        defaults.set(websites, forKey: "websites")
        defaults.set(mode.rawValue, forKey: "mode")
        defaults.set(duration, forKey: "duration")
    }

    func start(update: Bool = false) async {
        guard !busy else { return }
        do {
            let expiry = update ? configuration?.expiresAt : (mode == .timer ? Date().addingTimeInterval(Double(duration * 60)) : nil)
            let next = try BlockConfiguration(domains: websites, expiresAt: expiry)
            busy = true; error = nil
            defer { busy = false; refresh() }
            if isDemo { configuration = next; hasHostsBlock = true }
            else {
                let helper = try helperURL()
                try await Administrator.run(helper: helper, arguments: ["--apply", "--until", String(expiry?.timeIntervalSince1970 ?? 0), websites.joined(separator: ",")])
            }
            savePreferences()
        } catch { self.error = error.localizedDescription }
    }

    func stop() async {
        guard !busy else { return }
        busy = true; error = nil
        defer { busy = false; refresh() }
        do {
            if isDemo { configuration = nil; hasHostsBlock = false }
            else { try await Administrator.run(helper: helperURL(), arguments: ["--remove"]) }
        } catch { self.error = error.localizedDescription }
    }

    func setLogin(_ enabled: Bool) {
        guard !isDemo else { return }
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            loginStatus = SMAppService.mainApp.status
            settingsError = nil
        } catch { self.settingsError = error.localizedDescription }
    }

    private func helperURL() throws -> URL {
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/StillHelper")
        guard FileManager.default.isExecutableFile(atPath: bundled.path) else {
            throw AdminError.failed("The helper is missing. Build the app with ./scripts/build.sh, then open dist/Still.app.")
        }
        return bundled
    }
}
