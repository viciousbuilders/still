import Foundation
import BlockerAuthorization
import BlockerSystem

final class AuthorizationServer: NSObject, NSXPCListenerDelegate {
    private let registration: AuthorizationRegistration

    init(registration: AuthorizationRegistration) {
        // The installer writes this file under a root-owned, non-writable directory.
        self.registration = registration
        super.init()
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard connection.effectiveUserIdentifier == registration.userID,
              let service = try? AuthorizedBlockService(publicKey: registration.publicKey, userID: registration.userID) else { return false }
        connection.exportedInterface = NSXPCInterface(with: BlockAuthorizationService.self)
        connection.exportedObject = service
        connection.resume()
        return true
    }

    static func run() throws {
        let registration = try JSONDecoder().decode(AuthorizationRegistration.self,
                                                    from: Data(contentsOf: BlockAuthorization.registrationURL))
        let server = AuthorizationServer(registration: registration)
        let listener = NSXPCListener(machServiceName: BlockAuthorization.service)
        listener.delegate = server
        listener.resume()
        withExtendedLifetime((server, listener)) { dispatchMain() }
    }
}

private final class AuthorizedBlockService: NSObject, BlockAuthorizationService {
    private let verifier: BlockRequestVerifier
    private let userID: UInt32
    private let queue = DispatchQueue(label: "com.viciousbuilders.still.block-change")

    init(publicKey: Data, userID: UInt32) throws {
        verifier = try BlockRequestVerifier(publicKey: publicKey)
        self.userID = userID
        super.init()
    }

    func challenge(reply: @escaping (Data) -> Void) { reply(verifier.challenge()) }

    func perform(request: Data, signature: Data, reply: @escaping (String?) -> Void) {
        queue.async { [self] in
            do {
                let change = try verifier.verify(request: request, signature: signature)
                if let plan = change.focusPlan, plan.ownerID != userID { throw AuthorizationFailure.invalidRequest }
                let controller = SystemController(paths: .live)
                try controller.performAuthorized(change, helperSource: SystemPaths.live.helper)
                reply(nil)
            } catch { reply(error.localizedDescription) }
        }
    }
}
