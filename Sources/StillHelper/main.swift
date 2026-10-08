import Foundation
import Darwin
import BlockerCore
import BlockerSystem

do {
    guard geteuid() == 0 else {
        throw SystemError.commandFailed("StillHelper needs administrator permission. Enable or disable blocking from Still’s menu bar panel.")
    }
    let arguments = Array(CommandLine.arguments.dropFirst())
    let controller = SystemController(paths: .live)
    switch arguments.first {
    case "--apply":
        guard arguments.count == 4, let timestamp = Double(arguments[2]), timestamp.isFinite,
              timestamp == 0 || (timestamp > Date().timeIntervalSince1970 && timestamp < Date().addingTimeInterval(7 * 86400).timeIntervalSince1970)
        else { throw BlockError.invalidExpiry }
        let domains = arguments[3].components(separatedBy: ",")
        guard arguments[1] == "--until" else { throw BlockError.invalidExpiry }
        let configuration = try BlockConfiguration(domains: domains, expiresAt: timestamp == 0 ? nil : Date(timeIntervalSince1970: timestamp))
        try controller.apply(configuration, helperSource: URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL)
    case "--remove" where arguments.count == 1: try controller.remove()
    case "--tick" where arguments.count == 1: try controller.tick()
    default: throw SystemError.commandFailed("Usage: StillHelper --apply --until <epoch-or-0> <comma-separated-domains> | --remove | --tick")
    }
} catch {
    FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
    exit(1)
}
