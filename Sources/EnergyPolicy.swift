import Foundation

/// A reaction is an arrival cue, not an indefinitely pulsing request for attention.
/// Raw values deliberately match the state vocabulary without coupling this pure
/// scheduling policy to the event store or AppKit.
enum CompanionReaction: String {
    case finished, needsAnswer, needsReview

    var duration: TimeInterval {
        switch self {
        case .finished: return 1.5
        case .needsAnswer: return 1.4
        case .needsReview: return 1.25
        }
    }
}

struct CompanionReactionClock {
    private(set) var reaction: CompanionReaction?
    private var startedAt: TimeInterval?

    /// Call for a semantic state transition. Repeated snapshots leave the original
    /// deadline alone. An explicit skin choice may replay the current reaction.
    mutating func transition(to next: CompanionReaction?, at now: TimeInterval, restart: Bool = false) {
        guard next != reaction || restart else { return }
        reaction = next
        startedAt = next != nil && now.isFinite ? now : nil
    }

    /// Keep the semantic identity so a stale same-state refresh cannot replay it.
    mutating func cancel() { startedAt = nil }

    /// The caller supplies monotonic uptime. Hidden or sleeping views do not need
    /// a timer to expire a cue; its original deadline still applies when shown.
    func progress(at now: TimeInterval) -> Double? {
        guard let reaction, let startedAt, now.isFinite else { return nil }
        let elapsed = now - startedAt
        guard elapsed >= 0, elapsed < reaction.duration else { return nil }
        return elapsed / reaction.duration
    }
}

/// Rendering and pointer hit-testing have separate budgets: a quiet character does
/// not need new frames, but its small transparent corners must remain click-through.
struct CompanionRenderSchedule: Equatable {
    let timerInterval: TimeInterval?
    let drawsAnimation: Bool
    let tolerance: TimeInterval

    static func resolve(visible: Bool, displaySleeping: Bool, animated: Bool,
                        reducedMotion: Bool, lowPower: Bool) -> Self {
        guard visible, !displaySleeping else {
            return Self(timerInterval: nil, drawsAnimation: false, tolerance: 0)
        }
        let moving = animated && !reducedMotion
        let interval = moving ? 1.0 / (lowPower ? 6.0 : 12.0) : 0.25
        return Self(timerInterval: interval, drawsAnimation: moving,
                    tolerance: moving ? interval * 0.15 : 0.05)
    }
}
