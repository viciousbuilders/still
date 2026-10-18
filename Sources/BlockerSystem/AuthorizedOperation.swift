import Foundation
import BlockerAuthorization

extension SystemController {
    public func performAuthorized(_ request: AuthorizedBlockRequest, helperSource: URL) throws {
        try request.validate()
        switch request.action {
        case .apply:
            guard let configuration = request.configuration else { throw AuthorizationFailure.invalidRequest }
            try apply(configuration, helperSource: helperSource)
        case .remove: try remove()
        case .startFocus:
            guard let plan = request.focusPlan else { throw AuthorizationFailure.invalidRequest }
            try startFocus(plan, helperSource: helperSource)
        case .endFocus:
            guard let id = request.sessionID else { throw AuthorizationFailure.invalidRequest }
            try endFocus(sessionID: id)
        }
    }
}
