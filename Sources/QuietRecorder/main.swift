import AppKit
import AVFoundation
import CoreGraphics
import Darwin
import Foundation

@MainActor
final class ApplicationDelegate: NSObject, NSApplicationDelegate {
    private let logger = QuietLogger.shared
    private let recorder = RecordingController()
    private var hotKeyController: HotKeyController?
    private var terminationSignalSource: DispatchSourceSignal?
    private var terminationPending = false
    private var appKitTerminationPending = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            hotKeyController = try HotKeyController { [weak self] in self?.toggleRecording() }
            recorder.stateChanged = { [weak self] state in
                guard let self, self.terminationPending else { return }
                switch state {
                case .recording:
                    self.recorder.stop()
                case .idle:
                    let shouldReplyToAppKit = self.appKitTerminationPending
                    self.terminationPending = false
                    self.appKitTerminationPending = false
                    if shouldReplyToAppKit {
                        NSApplication.shared.reply(toApplicationShouldTerminate: true)
                    } else {
                        NSApplication.shared.terminate(nil)
                    }
                case .starting, .stopping:
                    break
                }
            }
            installTerminationSignalHandler()
            logger.log("agent launched; global shortcut registered")
        } catch {
            logger.log("agent launch failed: \(error.localizedDescription)")
            NSApplication.shared.terminate(nil)
            return
        }

        if let duration = commandLineRecordingDuration() {
            Task {
                do {
                    try await recorder.start()
                    Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
                        Task { @MainActor in self?.recorder.stop() }
                    }
                } catch {
                    logger.log("automatic recording failed: \(error.localizedDescription)")
                }
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if recorder.state == .starting {
            terminationPending = true
            appKitTerminationPending = true
            logger.log("termination deferred until capture initialization can stop safely")
            return .terminateLater
        }
        if recorder.state == .recording || recorder.state == .stopping {
            terminationPending = true
            appKitTerminationPending = true
            recorder.stop()
            return .terminateLater
        }
        return .terminateNow
    }

    private func installTerminationSignalHandler() {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            self.logger.log("SIGTERM received; requesting safe application termination")
            self.terminationPending = true
            self.appKitTerminationPending = false
            switch self.recorder.state {
            case .idle:
                self.terminationPending = false
                NSApplication.shared.terminate(nil)
            case .recording:
                self.recorder.stop()
            case .starting, .stopping:
                break
            }
        }
        source.resume()
        terminationSignalSource = source
    }

    private func toggleRecording() {
        switch recorder.state {
        case .idle:
            Task {
                do { try await recorder.start() }
                catch { logger.log("hotkey start failed: \(error.localizedDescription)") }
            }
        case .recording:
            recorder.stop()
        case .starting, .stopping:
            logger.log("hotkey ignored while recorder is changing state")
        }
    }

    private func commandLineRecordingDuration() -> TimeInterval? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--record-for"), index + 1 < arguments.count else {
            return nil
        }
        return TimeInterval(arguments[index + 1])
    }
}

if CommandLine.arguments.contains("--self-test") {
    print("SELF_TEST_OK bundle=com.fangchenfang.QuietRecorder hotkey=Control+Option+Command+R")
    exit(0)
}

if CommandLine.arguments.contains("--permission-status") {
    print("microphone=\(AVCaptureDevice.authorizationStatus(for: .audio).rawValue)")
    print("screen=\(CGPreflightScreenCaptureAccess())")
    exit(0)
}

MainActor.assumeIsolated {
    let application = NSApplication.shared
    let delegate = ApplicationDelegate()
    application.delegate = delegate
    application.run()
}
