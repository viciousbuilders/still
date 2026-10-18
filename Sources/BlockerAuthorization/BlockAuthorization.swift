import Foundation
import Security
import BlockerCore

public enum BlockAuthorization {
    public static let service = "com.viciousbuilders.still.authorization"
    public static let registrationURL = URL(fileURLWithPath: "/Library/Application Support/Still/authorization.json")
    public static let daemonURL = URL(fileURLWithPath: "/Library/LaunchDaemons/\(service).plist")
    public static let algorithm = SecKeyAlgorithm.ecdsaSignatureMessageX962SHA256
}

@objc public protocol BlockAuthorizationService {
    func challenge(reply: @escaping (Data) -> Void)
    func perform(request: Data, signature: Data, reply: @escaping (String?) -> Void)
}

public struct AuthorizationRegistration: Codable, Equatable {
    public let publicKey: Data
    public let userID: UInt32
    public init(publicKey: Data, userID: UInt32) {
        self.publicKey = publicKey; self.userID = userID
    }
}

/// These exact bytes are signed, including the operation, domains and expiry.
public struct AuthorizedBlockRequest: Codable {
    public enum Action: String, Codable { case apply, remove, startFocus, endFocus }
    public let action: Action
    public let configuration: BlockConfiguration?
    public let nonce: Data
    public let focusPlan: FocusPlan?
    public let sessionID: UUID?

    public init(action: Action, configuration: BlockConfiguration? = nil, nonce: Data,
                focusPlan: FocusPlan? = nil, sessionID: UUID? = nil) {
        self.action = action; self.configuration = configuration; self.nonce = nonce
        self.focusPlan = focusPlan; self.sessionID = sessionID
    }

    public func validate() throws {
        switch action {
        case .apply:
            guard let configuration, focusPlan == nil, sessionID == nil else { throw AuthorizationFailure.invalidRequest }
            _ = try configuration.validated()
            for expiry in configuration.activeGroups.compactMap(\.expiresAt) {
                guard expiry > Date(), expiry < Date().addingTimeInterval(7 * 86400) else { throw BlockError.invalidExpiry }
            }
        case .remove:
            guard configuration == nil, focusPlan == nil, sessionID == nil else { throw AuthorizationFailure.invalidRequest }
        case .startFocus:
            guard let focusPlan, configuration == nil, sessionID == nil else { throw AuthorizationFailure.invalidRequest }
            _ = try focusPlan.validated()
        case .endFocus:
            guard sessionID != nil, configuration == nil, focusPlan == nil else { throw AuthorizationFailure.invalidRequest }
        }
    }
}

public enum AuthorizationFailure: LocalizedError {
    case invalidRequest, invalidSignature, expiredChallenge
    public var errorDescription: String? {
        switch self {
        case .invalidRequest: return "The block change was invalid. No changes were made."
        case .invalidSignature: return "Could not verify permission for this block change. No changes were made."
        case .expiredChallenge: return "Permission expired. Try the block change again."
        }
    }
}

/// One instance per connection. A challenge can authorize exactly one request.
public final class BlockRequestVerifier {
    private let publicKey: SecKey
    private var pending: (nonce: Data, date: Date)?
    private let lock = NSLock()

    public init(publicKey data: Data) throws {
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(data as CFData, [
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass: kSecAttrKeyClassPublic,
            kSecAttrKeySizeInBits: 256
        ] as CFDictionary, &error) else { throw AuthorizationFailure.invalidSignature }
        publicKey = key
    }

    public func challenge(now: Date = Date()) -> Data {
        lock.lock(); defer { lock.unlock() }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return Data() }
        let nonce = Data(bytes)
        pending = (nonce, now)
        return nonce
    }

    public func verify(request data: Data, signature: Data, now: Date = Date()) throws -> AuthorizedBlockRequest {
        lock.lock(); defer { lock.unlock() }
        let challenge = pending
        pending = nil // Consume even an invalid attempt; never replay an approval.
        guard let challenge, now.timeIntervalSince(challenge.date) >= 0,
              now.timeIntervalSince(challenge.date) < 120 else { throw AuthorizationFailure.expiredChallenge }
        guard data.count <= 256 * 1024, signature.count <= 256 else { throw AuthorizationFailure.invalidRequest }
        guard SecKeyVerifySignature(publicKey, BlockAuthorization.algorithm, data as CFData, signature as CFData, nil)
        else { throw AuthorizationFailure.invalidSignature }
        let request = try JSONDecoder().decode(AuthorizedBlockRequest.self, from: data)
        guard request.nonce == challenge.nonce else { throw AuthorizationFailure.invalidSignature }
        try request.validate()
        return request
    }
}
