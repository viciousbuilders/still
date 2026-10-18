import Foundation
import BlockerCore

enum GroupPreferences {
    static func load(from defaults: UserDefaults) -> [BlockGroup] {
        if let data = defaults.data(forKey: "groups"),
           let saved = try? JSONDecoder().decode([BlockGroup].self, from: data),
           !saved.isEmpty, saved.count <= 50, Set(saved.map(\.id)).count == saved.count,
           let validated = try? saved.map({ try $0.validated() }) { return validated }
        let duration = defaults.integer(forKey: "duration")
        let minutes = defaults.string(forKey: "mode") == BlockMode.timer.rawValue
            ? ([25, 50, 90].contains(duration) ? duration : 25) : nil
        return [BlockGroup(id: BlockGroup.legacyID, name: "Websites",
                           domains: defaults.stringArray(forKey: "websites") ?? [], durationMinutes: minutes)]
    }
}
