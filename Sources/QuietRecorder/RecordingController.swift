import AppKit
import AVFoundation
import CoreAudio
import CoreMedia
import ScreenCaptureKit

enum RecordingError: LocalizedError {
    case alreadyBusy
    case mainDisplayUnavailable
    case builtInMicrophoneUnavailable
    case insufficientDiskSpace(Int64)
    case finalization(String)

    var errorDescription: String? {
        switch self {
        case .alreadyBusy: return "录制器正在启动、停止或录制。"
        case .mainDisplayUnavailable: return "ScreenCaptureKit 未返回主显示器。"
        case .builtInMicrophoneUnavailable: return "找不到已连接的 Mac 内置麦克风。"
        case .insufficientDiskSpace(let bytes): return "可用磁盘空间不足：\(bytes) 字节。"
        case .finalization(let detail): return "录像收尾失败：\(detail)"
        }
    }
}

@MainActor
final class RecordingController: NSObject {
    enum State {
        case idle
        case starting
        case recording
        case stopping
    }

    private(set) var state: State = .idle
    var stateChanged: ((State) -> Void)?

    private let logger = QuietLogger.shared
    private let sampleQueue = DispatchQueue(label: "com.fangchenfang.QuietRecorder.samples")
    private let capturePipeline = CapturePipeline()
    private var stream: SCStream?
    private var captureURL: URL?
    private var finalPartialURL: URL?
    private var telemetryPartialURL: URL?
    private var finalURL: URL?
    private var startedAt = Date()
    private var recordingID = UUID()
    private var abortReason: String?
    private var diskTimer: Timer?
    private var deviceTimer: Timer?
    private var stopWatchdog: Timer?
    private var selectedMicrophone: AVCaptureDevice?

    override init() {
        super.init()
        capturePipeline.failureHandler = { [weak self] reason in
            guard let self else { return }
            DispatchQueue.main.async { self.abortAndStop(reason) }
        }
    }

    func start() async throws {
        guard state == .idle else { throw RecordingError.alreadyBusy }
        transition(to: .starting)
        recordingID = UUID()
        startedAt = Date()
        abortReason = nil

        do {
            logger.log("permission check: microphone status=\(AVCaptureDevice.authorizationStatus(for: .audio).rawValue)")
            try await PermissionGate.requireMicrophone()
            logger.log("permission check: microphone authorized")
            let coreGraphicsPreflight = CGPreflightScreenCaptureAccess()
            logger.log("permission check: CoreGraphics screen preflight=\(coreGraphicsPreflight); ScreenCaptureKit remains authoritative")
            try checkDiskSpace(minimumBytes: 1_073_741_824)

            logger.log("requesting SCShareableContent")
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            logger.log("received SCShareableContent")
            guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) else {
                throw RecordingError.mainDisplayUnavailable
            }
            let ownApplications = content.applications.filter {
                $0.bundleIdentifier == "com.fangchenfang.QuietRecorder"
            }
            if ownApplications.isEmpty {
                logger.log("self is absent from shareable applications because the agent owns no windows; exclusion list is empty")
            }

            let filter = SCContentFilter(display: display, excludingApplications: ownApplications, exceptingWindows: [])
            let configuration = SCStreamConfiguration()
            configuration.width = 1280
            configuration.height = 720
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 15)
            configuration.queueDepth = 5
            configuration.pixelFormat = kCVPixelFormatType_32BGRA
            configuration.scalesToFit = true
            configuration.preservesAspectRatio = true
            configuration.showsCursor = true
            configuration.capturesAudio = true
            configuration.sampleRate = 48_000
            configuration.channelCount = 2
            configuration.excludesCurrentProcessAudio = true
            configuration.captureMicrophone = true

            let microphone = try selectBuiltInMicrophone()
            selectedMicrophone = microphone
            configuration.microphoneCaptureDeviceID = microphone.uniqueID
            logger.log("selected microphone: \(microphone.localizedName), transport=built-in")

            let urls = try makeOutputURLs()
            captureURL = urls.capture
            finalPartialURL = urls.finalPartial
            telemetryPartialURL = urls.telemetryPartial
            finalURL = urls.final
            try capturePipeline.prepare(outputURL: urls.capture)

            let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
            try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: sampleQueue)
            self.stream = stream

            try await stream.startCapture()
            capturePipeline.markCaptureStarted()
            transition(to: .recording)
            startMonitors()
            logger.log("recording started: \(urls.final.lastPathComponent), recorder=AVAssetWriter")
        } catch {
            cancelCapturePipeline()
            cleanupPartialFiles()
            stream = nil
            selectedMicrophone = nil
            transition(to: .idle)
            logger.log("recording start failed: \(error.localizedDescription)")
            throw error
        }
    }

    func stop() {
        guard state == .recording else { return }
        transition(to: .stopping)
        let stoppingRecordingID = recordingID
        stopMonitors()
        logger.log("recording stop requested")
        stream?.stopCapture { [weak self] error in
            guard let self else { return }
            if let error {
                DispatchQueue.main.async {
                    self.abortReason = "ScreenCaptureKit stop error: \(error.localizedDescription)"
                    self.logger.log(self.abortReason ?? "stop error")
                }
            }
            self.sampleQueue.async {
                self.capturePipeline.finish { result in
                    DispatchQueue.main.async {
                        self.captureFinished(result, recordingID: stoppingRecordingID)
                    }
                }
            }
        }
        stopWatchdog = Timer.scheduledTimer(withTimeInterval: 120, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self,
                      self.state == .stopping,
                      self.recordingID == stoppingRecordingID else { return }
                self.abortReason = "recording finalization timed out"
                self.failFinalization(self.abortReason ?? "timeout")
            }
        }
    }

    private func captureFinished(_ result: Result<Void, Error>, recordingID: UUID) {
        guard state == .stopping, self.recordingID == recordingID else { return }
        switch result {
        case .failure(let error):
            abortReason = abortReason ?? "capture writer finish failed: \(error.localizedDescription)"
            failFinalization(abortReason ?? error.localizedDescription)
        case .success:
            guard abortReason == nil, let captureURL, let finalPartialURL else {
                failFinalization(abortReason ?? "finalization URLs are missing")
                return
            }
            do {
                try checkDiskSpace(minimumBytes: try requiredFinalizationDiskReserve())
            } catch {
                failFinalization("finalization disk check failed: \(error.localizedDescription)")
                return
            }
            logger.log("temporary HEVC and two-track AAC capture finished; starting one-track audio mix")
            RecordingFinalizer.mix(captureURL: captureURL, outputURL: finalPartialURL) { [weak self] result in
                guard let self else { return }
                DispatchQueue.main.async { self.mixFinished(result, recordingID: recordingID) }
            }
        }
    }

    private func mixFinished(_ result: Result<Void, Error>, recordingID: UUID) {
        guard state == .stopping, self.recordingID == recordingID else { return }
        switch result {
        case .failure(let error):
            failFinalization("audio mix failed: \(error.localizedDescription)")
        case .success:
            publishFinalRecording()
        }
    }

    private func publishFinalRecording() {
        stopWatchdog?.invalidate()
        stopWatchdog = nil
        guard let captureURL, let finalPartialURL, let telemetryPartialURL, let finalURL else {
            failFinalization("output URLs are missing")
            return
        }
        do {
            guard FileManager.default.fileExists(atPath: finalPartialURL.path) else {
                throw RecordingError.finalization("mixed partial MP4 is missing")
            }
            guard !FileManager.default.fileExists(atPath: finalURL.path) else {
                throw RecordingError.finalization("destination already exists; refusing to overwrite")
            }
            let telemetryURL = finalURL.deletingPathExtension().appendingPathExtension("telemetry.json")
            guard !FileManager.default.fileExists(atPath: telemetryURL.path) else {
                throw RecordingError.finalization("telemetry destination already exists; refusing to overwrite")
            }

            try writeTelemetry(to: telemetryPartialURL)
            try FileManager.default.moveItem(at: telemetryPartialURL, to: telemetryURL)
            do {
                try FileManager.default.moveItem(at: finalPartialURL, to: finalURL)
            } catch {
                do { try FileManager.default.removeItem(at: telemetryURL) }
                catch { logger.log("telemetry rollback failed: \(error.localizedDescription)") }
                throw error
            }
            do { try FileManager.default.removeItem(at: captureURL) }
            catch { logger.log("published recording but capture scratch cleanup failed: \(error.localizedDescription)") }
            logger.log("recording finalized: \(finalURL.lastPathComponent)")
            resetAfterFinalization()
        } catch {
            failFinalization(error.localizedDescription)
        }
    }

    private func transition(to next: State) {
        state = next
        stateChanged?(next)
    }

    private func startMonitors() {
        diskTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                do { try self.checkDiskSpace(minimumBytes: try self.requiredFinalizationDiskReserve()) }
                catch { self.abortAndStop("disk monitor: \(error.localizedDescription)") }
            }
        }
        deviceTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.state == .recording else { return }
                if self.selectedMicrophone?.isConnected != true {
                    self.abortAndStop("selected built-in microphone disconnected while recording")
                } else if let track = self.capturePipeline.stalledTrack(maximumSilenceSeconds: 6) {
                    self.abortAndStop("\(track) samples stopped for at least 6 seconds")
                }
            }
        }
    }

    private func stopMonitors() {
        diskTimer?.invalidate()
        deviceTimer?.invalidate()
        diskTimer = nil
        deviceTimer = nil
    }

    private func abortAndStop(_ reason: String) {
        guard state == .recording else { return }
        abortReason = reason
        logger.log("recording aborted: \(reason)")
        stop()
    }

    private func checkDiskSpace(minimumBytes: Int64) throws {
        let values = try logger.outputDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        let available = values.volumeAvailableCapacityForImportantUsage ?? 0
        guard available >= minimumBytes else { throw RecordingError.insufficientDiskSpace(available) }
    }

    private func selectBuiltInMicrophone() throws -> AVCaptureDevice {
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone],
            mediaType: .audio,
            position: .unspecified
        )
        guard let microphone = session.devices.first(where: {
            $0.isConnected && UInt32(bitPattern: $0.transportType) == kAudioDeviceTransportTypeBuiltIn
        }) else {
            throw RecordingError.builtInMicrophoneUnavailable
        }
        return microphone
    }

    private func requiredFinalizationDiskReserve() throws -> Int64 {
        let captureBytes: Int64
        if let captureURL, FileManager.default.fileExists(atPath: captureURL.path) {
            let size = try captureURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            captureBytes = Int64(size)
        } else {
            captureBytes = 0
        }
        return max(268_435_456, captureBytes + 134_217_728)
    }

    private func makeOutputURLs() throws -> (
        capture: URL,
        finalPartial: URL,
        telemetryPartial: URL,
        final: URL
    ) {
        try FileManager.default.createDirectory(at: logger.outputDirectory, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let base = "QuietRecorder_\(formatter.string(from: Date()))"
        var suffix = 0
        while true {
            let name = suffix == 0 ? base : "\(base)_\(suffix)"
            let final = logger.outputDirectory.appendingPathComponent(name).appendingPathExtension("mp4")
            let telemetry = final.deletingPathExtension().appendingPathExtension("telemetry.json")
            let capture = logger.outputDirectory.appendingPathComponent(".\(name).capture.partial.mov")
            let finalPartial = logger.outputDirectory.appendingPathComponent(".\(name).mix.partial.mp4")
            let telemetryPartial = logger.outputDirectory.appendingPathComponent(".\(name).telemetry.partial.json")
            let candidates = [final, telemetry, capture, finalPartial, telemetryPartial]
            if candidates.allSatisfy({ !FileManager.default.fileExists(atPath: $0.path) }) {
                return (capture, finalPartial, telemetryPartial, final)
            }
            suffix += 1
        }
    }

    private func writeTelemetry(to url: URL) throws {
        let snapshot = capturePipeline.telemetrySnapshot()
        let telemetry = RecordingTelemetry(
            finalizationStatus: "completed",
            systemAudioSampleCount: snapshot.systemSampleCount,
            microphoneSampleCount: snapshot.microphoneSampleCount,
            systemAudioEnergy: snapshot.systemEnergy,
            microphoneAudioEnergy: snapshot.microphoneEnergy,
            recorder: "AVAssetWriter+AVAssetReaderAudioMixOutput",
            startedAt: startedAt,
            finishedAt: Date()
        )
        let data = try JSONEncoder.pretty.encode(telemetry)
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw RecordingError.finalization("telemetry partial destination already exists")
        }
        try data.write(to: url, options: .atomic)
    }

    private func failFinalization(_ reason: String) {
        stopWatchdog?.invalidate()
        stopWatchdog = nil
        logger.log("recording finalization failed: \(reason)")
        cancelCapturePipeline()
        cleanupPartialFiles()
        resetAfterFinalization()
    }

    private func cleanupPartialFiles() {
        for url in [captureURL, finalPartialURL, telemetryPartialURL].compactMap({ $0 }) where FileManager.default.fileExists(atPath: url.path) {
            do { try FileManager.default.removeItem(at: url) }
            catch { logger.log("partial cleanup failed: \(error.localizedDescription)") }
        }
    }

    private func resetAfterFinalization() {
        stream = nil
        selectedMicrophone = nil
        captureURL = nil
        finalPartialURL = nil
        telemetryPartialURL = nil
        finalURL = nil
        abortReason = nil
        transition(to: .idle)
    }

    private func cancelCapturePipeline() {
        sampleQueue.sync { capturePipeline.cancel() }
    }
}

extension RecordingController: SCStreamOutput {
    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        capturePipeline.append(sampleBuffer, type: type)
    }
}

extension RecordingController: SCStreamDelegate {
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        let stoppedStreamID = ObjectIdentifier(stream)
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.state != .idle,
                  self.stream.map(ObjectIdentifier.init) == stoppedStreamID else { return }
            self.abortReason = "ScreenCaptureKit stopped: \(error.localizedDescription)"
            self.logger.log(self.abortReason ?? "stream stopped")
            if self.state == .recording { self.stop() }
        }
    }
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}
