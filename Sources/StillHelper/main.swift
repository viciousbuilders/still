import Foundation
import Darwin
import BlockerCore
import BlockerSystem
import BlockerAuthorization

do {
    guard geteuid() == 0 else {
        throw SystemError.commandFailed("StillHelper needs administrator permission. Enable or disable blocking from Still’s menu bar panel.")
    }
    let arguments = Array(CommandLine.arguments.dropFirst())
    let controller = SystemController(paths: .live)
    switch arguments.first {
    case "--perform" where arguments.count == 2:
        guard let data = Data(base64Encoded: arguments[1]), data.count <= 256 * 1024 else { throw AuthorizationFailure.invalidRequest }
        let request = try JSONDecoder().decode(AuthorizedBlockRequest.self, from: data)
        try controller.performAuthorized(request, helperSource: URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL)
    case "--watch" where arguments.count == 1:
        repeat {
            try controller.tick()
            Thread.sleep(forTimeInterval: 1)
        } while FileManager.default.fileExists(atPath: SystemPaths.live.state.path) || FileManager.default.fileExists(atPath: SystemPaths.live.focus.path)
    case "--apply-configuration" where arguments.count == 2:
        guard let data = Data(base64Encoded: arguments[1]), data.count <= 256 * 1024 else { throw AuthorizationFailure.invalidRequest }
        let configuration = try JSONDecoder().decode(BlockConfiguration.self, from: data).validated()
        try AuthorizedBlockRequest(action: .apply, configuration: configuration, nonce: Data()).validate()
        try controller.apply(configuration, helperSource: URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL)
    case "--serve" where arguments.count == 1: try AuthorizationServer.run()
    case "--install-authorization" where arguments.count == 3:
        guard let key = Data(base64Encoded: arguments[1]), let userID = UInt32(arguments[2]) else {
            throw AuthorizationFailure.invalidRequest
        }
        try controller.installAuthorization(AuthorizationRegistration(publicKey: key, userID: userID),
                                            helperSource: URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL)
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
