import Foundation
import LocalAuthentication
import Security
import CryptoKit
import BlockerAuthorization
import BlockerCore

enum TouchIDAuthorization {
    static func perform(helper: URL, action: AuthorizedBlockRequest.Action,
                        configuration: BlockConfiguration? = nil, focusPlan: FocusPlan? = nil, sessionID: UUID? = nil) async throws {
        try await Task.detached(priority: .userInitiated) {
            let context = LAContext()
            _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
            // Macs without Touch ID retain the standard administrator flow.
            guard context.biometryType == .touchID, SecureEnclave.isAvailable else {
                let request = AuthorizedBlockRequest(action: action, configuration: configuration, nonce: Data(), focusPlan: focusPlan, sessionID: sessionID)
                let arguments = ["--perform", try JSONEncoder().encode(request).base64EncodedString()]
                try await Administrator.run(helper: helper, arguments: arguments)
                return
            }

            switch action {
            case .apply: context.localizedReason = "update your website block"
            case .remove: context.localizedReason = "turn off website blocking"
            case .startFocus: context.localizedReason = "start your focus cycle and automatically open its group during breaks"
            case .endFocus: context.localizedReason = "end your focus cycle and unblock its group"
            }
            context.touchIDAuthenticationAllowableReuseDuration = 0
            defer { context.invalidate() }
            let key = try signingKey(context: context)
            let representation = key.publicKey.x963Representation
            let registration = AuthorizationRegistration(publicKey: representation, userID: getuid())
            if !isInstalled(registration, helper: helper) {
                try await Administrator.run(helper: helper, arguments: [
                    "--install-authorization", representation.base64EncodedString(), String(getuid())
                ], prompt: "Still needs administrator permission to set up Touch ID for block changes.")
            }

            let connection = NSXPCConnection(machServiceName: BlockAuthorization.service, options: .privileged)
            connection.remoteObjectInterface = NSXPCInterface(with: BlockAuthorizationService.self)
            connection.resume()
            defer { connection.invalidate() }
            let nonce: Data = try await call(connection, timeout: 10) { service, finish in
                service.challenge { finish(.success($0)) }
            }
            guard nonce.count == 32 else { throw AuthorizationFailure.invalidRequest }
            let request = AuthorizedBlockRequest(action: action, configuration: configuration, nonce: nonce, focusPlan: focusPlan, sessionID: sessionID)
            let data = try JSONEncoder().encode(request)
            // Signing requires user presence in the Secure Enclave. The daemon
            // verifies the signature; a successful UI-only LAContext is insufficient.
            let signature: Data
            do { signature = try key.signature(for: data).derRepresentation }
            catch { throw permissionError(error) }
            let _: Bool = try await call(connection, timeout: 180) { service, finish in
                service.perform(request: data, signature: signature) { message in
                    if let message { finish(.failure(AdminError.failed(message))) }
                    else { finish(.success(true)) }
                }
            }
        }.value
    }

    private static func signingKey(context: LAContext) throws -> SecureEnclave.P256.Signing.PrivateKey {
        let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                    appropriateFor: nil, create: true).appendingPathComponent("Still", isDirectory: true)
        let url = directory.appendingPathComponent("block-approval.key")
        if FileManager.default.fileExists(atPath: url.path) {
            return try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: Data(contentsOf: url), authenticationContext: context)
        }
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                                                         [.privateKeyUsage, .userPresence], &error)
        else { throw permissionError(error?.takeRetainedValue() as Error?) }
        let key = try SecureEnclave.P256.Signing.PrivateKey(accessControl: access, authenticationContext: context)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        // CryptoKit's representation is an encrypted, device-bound key blob,
        // never the private key. It works with local ad-hoc builds without
        // requiring provisioned access to the data-protection keychain.
        try key.dataRepresentation.write(to: url, options: [.atomic, .completeFileProtection])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return key
    }

    private static func isInstalled(_ registration: AuthorizationRegistration, helper: URL) -> Bool {
        guard let data = try? Data(contentsOf: BlockAuthorization.registrationURL),
              (try? JSONDecoder().decode(AuthorizationRegistration.self, from: data)) == registration,
              FileManager.default.fileExists(atPath: BlockAuthorization.daemonURL.path),
              let bundled = try? Data(contentsOf: helper),
              let installed = try? Data(contentsOf: URL(fileURLWithPath: "/Library/Application Support/Still/StillHelper"))
        else { return false }
        guard bundled == installed else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["print", "system/\(BlockAuthorization.service)"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run(); process.waitUntilExit(); return process.terminationStatus == 0 }
        catch { return false }
    }

    private static func permissionError(_ error: Error?) -> Error {
        guard let error else { return AdminError.failed("Touch ID permission was not granted. Try again.") }
        let value = error as NSError
        if value.code == Int(errSecUserCanceled) ||
            (value.domain == LAError.errorDomain && [LAError.userCancel.rawValue, LAError.appCancel.rawValue,
                                                   LAError.systemCancel.rawValue].contains(value.code)) {
            return AdminError.cancelled
        }
        return AdminError.failed(value.localizedDescription)
    }

    private static func call<T>(_ connection: NSXPCConnection, timeout: TimeInterval,
                                send: (BlockAuthorizationService, @escaping (Result<T, Error>) -> Void) -> Void) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            let reply = XPCReply(continuation)
            let failed = { reply.finish(.failure(AdminError.failed("Could not reach Still’s helper. Try again or rebuild Still to repair it."))) }
            connection.interruptionHandler = failed
            connection.invalidationHandler = failed
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { failed() }
            guard let service = connection.remoteObjectProxyWithErrorHandler({ _ in failed() }) as? BlockAuthorizationService
            else { failed(); return }
            send(service, reply.finish)
        }
    }
}

/// XPC errors, timeouts and replies may race. Resume the caller only once.
private final class XPCReply<T> {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    init(_ continuation: CheckedContinuation<T, Error>) { self.continuation = continuation }
    func finish(_ result: Result<T, Error>) {
        lock.lock()
        let pending = continuation; continuation = nil
        lock.unlock()
        pending?.resume(with: result)
    }
}
