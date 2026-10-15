import Foundation
import CoreAudio

@main
struct AudioAccessoryTests {
    static func main() {
        var checks = 0
        func expect(_ value: Bool, _ message: String) { precondition(value, message); checks += 1 }
        func output(_ name: String, _ transport: AudioOutputDescriptor.Transport = .bluetooth,
                    source: UInt32? = nil, terminals: [UInt32] = []) -> AudioOutputDescriptor {
            AudioOutputDescriptor(transport: transport, dataSource: source, terminalTypes: terminals, name: name)
        }
        expect(!HeadphoneClassification.isHeadphones(nil), "Missing default output stays off")
        for name in ["AirPods Pro", "Anna’s AirPods", "Headphones", "Beats Fit Pro", "Sony WH-1000XM5", "Bose QuietComfort"] {
            expect(HeadphoneClassification.isHeadphones(output(name)), "Recognized Bluetooth headphones")
        }
        expect(HeadphoneClassification.isHeadphones(output("AirPods Pro", .bluetoothLE)), "Bluetooth LE headphones")
        for name in ["Living Room", "JBL speaker", "AirPods speaker", "HomePod", "Beats Pill", "Soundbar", "Колонка"] {
            expect(!HeadphoneClassification.isHeadphones(output(name)), "Unknown Bluetooth devices and speakers stay off")
        }
        expect(!HeadphoneClassification.isHeadphones(output("AirPods", .usb)), "Names alone cannot classify arbitrary USB devices")
        expect(HeadphoneClassification.isHeadphones(output("Built-in output", .builtIn, source: 0x6864706e)), "Wired port selection")
        expect(HeadphoneClassification.isHeadphones(output("USB audio", .usb, terminals: [kAudioStreamTerminalTypeHeadphones])),
               "Explicit headphone terminal works without a recognized brand")
        expect(!HeadphoneClassification.isHeadphones(output("MacBook Pro Speakers", .builtIn,
               terminals: [kAudioStreamTerminalTypeSpeaker])), "Built-in speakers are not headphones")

        let observer = FakeAudioOutputObserver()
        let controller = HeadphoneAccessoryController(observer: observer)
        var changes: [Bool] = []
        controller.onChange = { changes.append($0) }
        expect(observer.starts == 0 && !controller.isEnabled, "Default off does not touch CoreAudio")
        controller.setEnabled(true)
        controller.setEnabled(true)
        expect(observer.starts == 1, "Enabling twice attaches one observer")
        observer.callback?(output("AirPods Pro"))
        observer.callback?(output("AirPods Pro"))
        expect(changes == [true], "Unchanged output does not redraw the character")
        controller.setEnabled(false)
        expect(observer.stops == 1 && !controller.isWearingHeadphones && changes == [true, false],
               "Disabling detaches listeners and clears the decoration")
        observer.callback?(output("AirPods Pro"))
        expect(!controller.isWearingHeadphones, "A queued old notification cannot re-enable an off preference")
        controller.setEnabled(false)
        expect(observer.stops == 1, "Disable is idempotent")
        controller.setEnabled(true)
        observer.callback?(output("JBL speaker"))
        expect(!controller.isWearingHeadphones && observer.starts == 2, "Re-enable gets fresh output state")
        print("PASS: Audio accessory (\(checks) checks)")
    }
}

private final class FakeAudioOutputObserver: AudioOutputObserving {
    var starts = 0
    var stops = 0
    var callback: ((AudioOutputDescriptor?) -> Void)?
    func start(onChange: @escaping (AudioOutputDescriptor?) -> Void) { starts += 1; callback = onChange }
    func stop() { stops += 1 }
}
