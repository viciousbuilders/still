import XCTest
import Security
import CryptoKit
import BlockerCore
@testable import BlockerAuthorization

final class BlockAuthorizationTests: XCTestCase {
    func testFocusApprovalBindsTheExactGroupAndSchedule() throws {
        let key = try key(), verifier = try verifier(for: key)
        let group = ActiveBlockGroup(id: UUID(), name: "Study", domains: ["instagram.com"])
        let plan = FocusPlan(group: group, ownerID: 501, rounds: 2)
        let nonce = verifier.challenge()
        let approved = AuthorizedBlockRequest(action: .startFocus, nonce: nonce, focusPlan: plan)
        let signature = try sign(JSONEncoder().encode(approved), key: key)
        let altered = AuthorizedBlockRequest(action: .startFocus, nonce: nonce,
            focusPlan: FocusPlan(id: plan.id, group: group, ownerID: 501, focusMinutes: 50, breakMinutes: 10, rounds: 4))
        XCTAssertThrowsError(try verifier.verify(request: JSONEncoder().encode(altered), signature: signature))
        let fresh = AuthorizedBlockRequest(action: .startFocus, nonce: verifier.challenge(), focusPlan: plan)
        let bytes = try JSONEncoder().encode(fresh)
        XCTAssertEqual(try verifier.verify(request: bytes, signature: sign(bytes, key: key)).focusPlan, plan)
        XCTAssertThrowsError(try AuthorizedBlockRequest(action: .endFocus, nonce: Data()).validate())
    }

    func testCryptoKitSignaturesMatchTheHelpersSecurityVerifier() throws {
        let key = P256.Signing.PrivateKey()
        let verifier = try BlockRequestVerifier(publicKey: key.publicKey.x963Representation)
        let data = try JSONEncoder().encode(AuthorizedBlockRequest(action: .remove, nonce: verifier.challenge()))
        let signature = try key.signature(for: data).derRepresentation
        XCTAssertEqual(try verifier.verify(request: data, signature: signature).action, .remove)
    }

    private func key() throws -> SecKey {
        try XCTUnwrap(SecKeyCreateRandomKey([
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom, kSecAttrKeySizeInBits: 256
        ] as CFDictionary, nil))
    }

    private func verifier(for key: SecKey) throws -> BlockRequestVerifier {
        let publicKey = try XCTUnwrap(SecKeyCopyPublicKey(key))
        return try BlockRequestVerifier(publicKey: XCTUnwrap(SecKeyCopyExternalRepresentation(publicKey, nil)) as Data)
    }

    private func sign(_ data: Data, key: SecKey) throws -> Data {
        try XCTUnwrap(SecKeyCreateSignature(key, BlockAuthorization.algorithm, data as CFData, nil)) as Data
    }

    func testSignedStartAndStopAreAcceptedOnce() throws {
        let key = try key(), verifier = try verifier(for: key)
        for action in [AuthorizedBlockRequest.Action.apply, .remove] {
            let request = AuthorizedBlockRequest(action: action,
                configuration: action == .apply ? try BlockConfiguration(domains: ["example.com"]) : nil,
                nonce: verifier.challenge())
            let data = try JSONEncoder().encode(request), signature = try sign(data, key: key)
            XCTAssertEqual(try verifier.verify(request: data, signature: signature).action, action)
            XCTAssertThrowsError(try verifier.verify(request: data, signature: signature))
        }
    }

    func testChangingApprovedDomainsOrActionInvalidatesSignature() throws {
        let key = try key(), verifier = try verifier(for: key)
        for replacement in [AuthorizedBlockRequest.Action.apply, .remove] {
            let nonce = verifier.challenge()
            let original = AuthorizedBlockRequest(action: .apply,
                configuration: try BlockConfiguration(domains: ["example.com"]), nonce: nonce)
            let signature = try sign(JSONEncoder().encode(original), key: key)
            let tampered = AuthorizedBlockRequest(action: replacement,
                configuration: replacement == .apply ? try BlockConfiguration(domains: ["other.com"]) : nil, nonce: nonce)
            XCTAssertThrowsError(try verifier.verify(request: JSONEncoder().encode(tampered), signature: signature))
        }
    }

    func testOtherKeysConnectionsAndExpiredApprovalsAreRejected() throws {
        let key = try key(), verifier = try verifier(for: key), other = try self.verifier(for: key)
        let now = Date()
        let data = try JSONEncoder().encode(AuthorizedBlockRequest(action: .remove, nonce: verifier.challenge(now: now)))
        let signature = try sign(data, key: key)
        _ = other.challenge()
        XCTAssertThrowsError(try other.verify(request: data, signature: signature))
        XCTAssertThrowsError(try verifier.verify(request: data, signature: signature, now: now.addingTimeInterval(120)))
        let fresh = try JSONEncoder().encode(AuthorizedBlockRequest(action: .remove, nonce: verifier.challenge()))
        XCTAssertThrowsError(try verifier.verify(request: fresh, signature: sign(fresh, key: self.key())))
    }

    func testInvalidConfigurationIsRejectedEvenWhenSigned() throws {
        let key = try key(), verifier = try verifier(for: key)
        for configuration in [nil, try BlockConfiguration(domains: ["example.com"], expiresAt: .distantPast),
                              try BlockConfiguration(domains: ["example.com"], expiresAt: .distantFuture)] {
            let data = try JSONEncoder().encode(AuthorizedBlockRequest(action: .apply, configuration: configuration,
                                                                      nonce: verifier.challenge()))
            XCTAssertThrowsError(try verifier.verify(request: data, signature: sign(data, key: key)))
        }
    }

    func testAnInvalidAttemptConsumesTheChallenge() throws {
        let key = try key(), verifier = try verifier(for: key)
        let data = try JSONEncoder().encode(AuthorizedBlockRequest(action: .remove, nonce: verifier.challenge()))
        XCTAssertThrowsError(try verifier.verify(request: data, signature: Data()))
        XCTAssertThrowsError(try verifier.verify(request: data, signature: sign(data, key: key)))
    }
}
