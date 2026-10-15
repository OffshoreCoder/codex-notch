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
        print("PASS: Energy policy (\(checks) checks)")
    }
}
