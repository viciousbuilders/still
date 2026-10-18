import Foundation
import BlockerAuthorization

extension SystemController {
    /// Called only through the existing administrator prompt, never over XPC.
    public func installAuthorization(_ registration: AuthorizationRegistration, helperSource: URL) throws {
        _ = try BlockRequestVerifier(publicKey: registration.publicKey)
        guard registration.userID != 0 else { throw AuthorizationFailure.invalidRequest }
        try withLock {
            let registrationURL = paths.isSandbox ? paths.directory.appendingPathComponent("authorization.json") : BlockAuthorization.registrationURL
            let daemonURL = paths.isSandbox ? paths.daemon.deletingLastPathComponent().appendingPathComponent("authorization.plist") : BlockAuthorization.daemonURL
            try checkPath(registrationURL)
            try checkPath(daemonURL)
            try installHelper(from: helperSource)
            try write(try JSONEncoder().encode(registration), to: registrationURL, mode: 0o644)
            let plist: [String: Any] = [
                "Label": BlockAuthorization.service,
                "ProgramArguments": [paths.helper.path, "--serve"],
                "MachServices": [BlockAuthorization.service: true],
                "ProcessType": "Interactive"
            ]
            try write(try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0),
                      to: daemonURL, mode: 0o644)
            if paths.isSandbox { return }
            _ = run("/bin/launchctl", ["bootout", "system/\(BlockAuthorization.service)"])
            let result = run("/bin/launchctl", ["bootstrap", "system", daemonURL.path])
            guard result.status == 0 else {
                // Force the next attempt through administrator setup again.
                try? FileManager.default.removeItem(at: registrationURL)
                throw SystemError.commandFailed("Could not start Touch ID support: \(result.message)")
            }
        }
    }
}
