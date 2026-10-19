import Foundation
import BlockerCore

struct StatusPresentation: Equatable {
    let symbol: String
    let title: String
    let detail: String
    let countingDown: Bool

    init(active: Bool, session: FocusSession?, now: Date) {
        symbol = session != nil ? "timer" : active ? "shield.lefthalf.filled" : "shield"
        if let phase = session?.phase(at: now), phase.kind != .finished {
            let seconds = max(0, Int(ceil(phase.endsAt.timeIntervalSince(now))))
            let time = String(format: "%d:%02d", seconds / 60, seconds % 60)
            title = " \(time)"
            detail = "Still: \(phase.kind == .focus ? "Focus" : "Break") · \(time) remaining"
            countingDown = true
        } else {
            title = ""
            detail = active ? "Still: website blocking active" : "Still: website blocker"
            countingDown = false
        }
    }
}
