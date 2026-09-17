import AppKit
import Foundation

@main
struct SleepLifecycleTests {
    @MainActor
    static func main() async {
        let recorder = RecordingController()
        let center = NSWorkspace.shared.notificationCenter
        center.post(name: NSWorkspace.willSleepNotification, object: nil)
        do {
            try await recorder.start()
            fatalError("recording started while sleeping")
        } catch RecordingError.alreadyBusy {
        } catch {
            fatalError("unexpected error: \(error)")
        }
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        precondition(recorder.state == .idle, "wake automatically started recording")

        // Simulate sleep and wake while asynchronous initialization is pending.
        // Cancellation must survive wake and must happen before permission prompts.
        recorder.stateChanged = { state in
            if state == .starting {
                center.post(name: NSWorkspace.willSleepNotification, object: nil)
                center.post(name: NSWorkspace.didWakeNotification, object: nil)
            }
        }
        for _ in 0..<2 {
            do {
                try await recorder.start()
                fatalError("startup survived sleep")
            } catch is CancellationError {
            } catch {
                fatalError("unexpected startup error: \(error)")
            }
            precondition(recorder.state == .idle, "cancelled startup did not return to idle")
        }
        print("PASS: sleep blocks recording, wake stays idle, interrupted startup remains cancelled")
    }
}
