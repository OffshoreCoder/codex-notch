import Foundation

@main
struct EnergyPolicyTests {
    static func main() {
        var checks = 0
        func expect(_ value: Bool, _ message: String) {
            precondition(value, message); checks += 1
        }
        for sleeping in [false, true] {
            for visible in [false, true] {
                for animated in [false, true] {
                    for reduced in [false, true] {
                        for low in [false, true] {
                            let schedule = CompanionRenderSchedule.resolve(visible: visible,
                                displaySleeping: sleeping, animated: animated, reducedMotion: reduced, lowPower: low)
                            if sleeping || !visible {
                                expect(schedule.timerInterval == nil && !schedule.drawsAnimation,
                                       "Hidden and sleeping surfaces schedule no rendering or pointer work")
                            } else if !animated || reduced {
                                expect(schedule.timerInterval == 0.25 && !schedule.drawsAnimation,
                                       "Static character checks pointer without redrawing")
                            } else {
                                expect(schedule.drawsAnimation && schedule.timerInterval == 1.0 / (low ? 6.0 : 12.0),
                                       "Animation respects the power budget")
                            }
                        }
                    }
                }
            }
        }
        let normal = CompanionRenderSchedule.resolve(visible: true, displaySleeping: false,
            animated: true, reducedMotion: false, lowPower: false)
        let low = CompanionRenderSchedule.resolve(visible: true, displaySleeping: false,
            animated: true, reducedMotion: false, lowPower: true)
        expect(low.timerInterval! > normal.timerInterval!, "Low power produces fewer wakes")
        expect(low.tolerance < low.timerInterval!, "Timer coalescing keeps responsiveness bounded")
        for reaction: CompanionReaction in [.finished, .needsAnswer, .needsReview] {
            var clock = CompanionReactionClock()
            expect(clock.progress(at: 100) == nil, "No animation is scheduled before an arrival")
            clock.transition(to: reaction, at: 100)
            expect(clock.progress(at: 100) == 0, "Semantic arrival starts at its first frame")
            let middle = 100 + reaction.duration / 2
            expect(abs(clock.progress(at: middle)! - 0.5) < 0.0001, "Progress follows monotonic elapsed time")
            clock.transition(to: reaction, at: middle)
            expect(abs(clock.progress(at: middle)! - 0.5) < 0.0001,
                   "Repeated same-state snapshots do not restart the deadline")
            expect(clock.progress(at: 99) == nil && clock.progress(at: .infinity) == nil,
                   "Invalid or regressing clocks never extend a reaction")
            let deadline = 100 + reaction.duration
            expect(clock.progress(at: deadline) == nil && clock.progress(at: deadline + 1) == nil,
                   "Arrival movement ends at its fixed deadline")
            clock.transition(to: reaction, at: deadline + 1)
            expect(clock.progress(at: deadline + 1) == nil, "Late same-state refresh stays settled")
            let settled = CompanionRenderSchedule.resolve(visible: true, displaySleeping: false,
                animated: clock.progress(at: deadline + 1) != nil, reducedMotion: false, lowPower: false)
            expect(!settled.drawsAnimation && settled.timerInterval == 0.25,
                   "An expired question or result returns to pointer-only work")
            clock.transition(to: reaction, at: 200, restart: true)
            expect(clock.progress(at: 200) == 0, "Explicit skin selection can replay a finite cue")
            let sleeping = CompanionRenderSchedule.resolve(visible: true, displaySleeping: true,
                animated: clock.progress(at: 200) != nil, reducedMotion: false, lowPower: false)
            expect(sleeping.timerInterval == nil, "Even a fresh reaction creates no sleeping-display timer")
            let hidden = CompanionRenderSchedule.resolve(visible: false, displaySleeping: false,
                animated: clock.progress(at: 200) != nil, reducedMotion: false, lowPower: false)
            expect(hidden.timerInterval == nil, "Hidden arrival needs no timer")
            let reduced = CompanionRenderSchedule.resolve(visible: true, displaySleeping: false,
                animated: clock.progress(at: 200) != nil, reducedMotion: true, lowPower: false)
            expect(!reduced.drawsAnimation, "Reduce Motion suppresses even fresh finite reactions")
            expect(clock.progress(at: 205) == nil, "Hidden time expires without a timer or restarting on wake")
            clock.transition(to: nil, at: 210)
            expect(clock.progress(at: 210) == nil, "Changing back to a quiet state cancels the cue")
            clock.transition(to: reaction, at: 220)
            expect(clock.progress(at: 220) == 0, "A later real state transition can react again")
            clock.cancel()
            expect(clock.progress(at: 220) == nil, "Sleep cancels a reaction even if uptime pauses")
            clock.transition(to: reaction, at: 221)
            expect(clock.progress(at: 221) == nil, "Waking into the same state never replays a stale cue")
        }
        print("PASS: Energy policy (\(checks) checks)")
    }
}
