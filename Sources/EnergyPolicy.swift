import Foundation

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
