import AudioToolbox
import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit
import VideoToolbox

final class CapturePipeline: @unchecked Sendable {
    var failureHandler: (@Sendable (String) -> Void)?

    private static let minimumVideoSampleSpacing = CMTime(value: 3, timescale: 50)

    private final class TrackState {
        var lastPresentationTime = CMTime.invalid
        var backpressureStartTime = CMTime.invalid
        var nonMonotonicStartUptime: TimeInterval?
        var nonMonotonicSampleCount = 0

        func reset() {
            lastPresentationTime = .invalid
            backpressureStartTime = .invalid
            nonMonotonicStartUptime = nil
            nonMonotonicSampleCount = 0
        }
    }

    private let telemetry = AudioTelemetryAccumulator()
    private let health = CaptureHealthTracker()
    private let videoState = TrackState()
    private let systemAudioState = TrackState()
    private let microphoneState = TrackState()
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var systemAudioInput: AVAssetWriterInput?
    private var microphoneInput: AVAssetWriterInput?
    private var sessionStarted = false
    private var sessionStartTime = CMTime.invalid
    private var failureReported = false

    func prepare(outputURL: URL) throws {
        telemetry.reset()
        health.reset()
        sessionStarted = false
        sessionStartTime = .invalid
        videoState.reset()
        systemAudioState.reset()
        microphoneState.reset()
        failureReported = false

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: 1280,
            AVVideoHeightKey: 720,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 1_050_000,
                AVVideoExpectedSourceFrameRateKey: 15,
                AVVideoMaxKeyFrameIntervalKey: 150,
                AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main_AutoLevel
            ]
        ]
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true

        let systemAudioInput = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: Self.aacSettings(channels: 2, bitRate: 96_000)
        )
        systemAudioInput.expectsMediaDataInRealTime = true

        let microphoneInput = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: Self.aacSettings(channels: 1, bitRate: 64_000)
        )
        microphoneInput.expectsMediaDataInRealTime = true

        guard writer.canAdd(videoInput), writer.canAdd(systemAudioInput), writer.canAdd(microphoneInput) else {
            throw CapturePipelineError.inputsUnsupported
        }
        writer.add(videoInput)
        writer.add(systemAudioInput)
        writer.add(microphoneInput)
        guard writer.startWriting() else {
            throw writer.error ?? CapturePipelineError.writerStartFailed
        }

        self.writer = writer
        self.videoInput = videoInput
        self.systemAudioInput = systemAudioInput
        self.microphoneInput = microphoneInput
    }

    func append(_ sampleBuffer: CMSampleBuffer, type: SCStreamOutputType) {
        guard CMSampleBufferDataIsReady(sampleBuffer), let writer, writer.status == .writing else {
            if let writer, writer.status == .failed {
                reportFailure("capture writer failed: \(Self.describe(writer.error))")
            }
            return
        }

        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard presentationTime.isValid else { return }

        switch type {
        case .screen:
            guard Self.isEncodableScreenFrame(sampleBuffer) else { return }
            guard isStrictlyAfterLastSample(presentationTime, state: videoState, label: "video"),
                  isVideoSampleDue(presentationTime),
                  startSessionIfNeeded(at: presentationTime, writer: writer) else { return }
            append(
                sampleBuffer,
                at: presentationTime,
                to: videoInput,
                state: videoState,
                label: "video",
                maximumBackpressureSeconds: 5
            )
        case .audio:
            health.noteSystemAudio()
            let energy = Self.energy(in: sampleBuffer)
            telemetry.addSystem(sum: energy.sum, count: energy.count)
            guard isStrictlyAfterLastSample(presentationTime, state: systemAudioState, label: "system audio"),
                  startSessionIfNeeded(at: presentationTime, writer: writer) else { return }
            append(
                sampleBuffer,
                at: presentationTime,
                to: systemAudioInput,
                state: systemAudioState,
                label: "system audio",
                maximumBackpressureSeconds: 2
            )
        case .microphone:
            health.noteMicrophone()
            let energy = Self.energy(in: sampleBuffer)
            telemetry.addMicrophone(sum: energy.sum, count: energy.count)
            guard isStrictlyAfterLastSample(presentationTime, state: microphoneState, label: "microphone"),
                  startSessionIfNeeded(at: presentationTime, writer: writer) else { return }
            append(
                sampleBuffer,
                at: presentationTime,
                to: microphoneInput,
                state: microphoneState,
                label: "microphone",
                maximumBackpressureSeconds: 2
            )
        @unknown default:
            break
        }
    }

    func finish(completion: @escaping @Sendable (Result<Void, Error>) -> Void) {
        guard let writer else {
            completion(.failure(CapturePipelineError.writerMissing))
            return
        }
        videoInput?.markAsFinished()
        systemAudioInput?.markAsFinished()
        microphoneInput?.markAsFinished()
        guard sessionStarted else {
            writer.cancelWriting()
            completion(.failure(CapturePipelineError.noSamples))
            resetWriterReferences()
            return
        }
        let context = WriterFinishContext(writer: writer, completion: completion)
        writer.finishWriting { [weak self, context] in
            context.complete()
            self?.resetWriterReferences()
        }
    }

    func cancel() {
        writer?.cancelWriting()
        resetWriterReferences()
    }

    func telemetrySnapshot() -> AudioTelemetryAccumulator.Snapshot {
        telemetry.snapshot()
    }

    func markCaptureStarted() {
        health.markCaptureStarted()
    }

    func stalledTrack(maximumSilenceSeconds: TimeInterval) -> String? {
        health.stalledTrack(maximumSilenceSeconds: maximumSilenceSeconds)
    }

    private func startSessionIfNeeded(at presentationTime: CMTime, writer: AVAssetWriter) -> Bool {
        if !sessionStarted {
            writer.startSession(atSourceTime: presentationTime)
            sessionStartTime = presentationTime
            sessionStarted = true
        }
        return presentationTime >= sessionStartTime
    }

    private func isStrictlyAfterLastSample(
        _ presentationTime: CMTime,
        state: TrackState,
        label: String
    ) -> Bool {
        guard state.lastPresentationTime.isValid,
              CMTimeCompare(presentationTime, state.lastPresentationTime) <= 0 else {
            state.nonMonotonicStartUptime = nil
            state.nonMonotonicSampleCount = 0
            return true
        }

        let now = ProcessInfo.processInfo.systemUptime
        state.nonMonotonicSampleCount += 1
        if let started = state.nonMonotonicStartUptime {
            let duration = now - started
            if duration >= 2 {
                reportFailure(
                    "\(label) timestamps were non-increasing for \(String(format: "%.3f", duration)) seconds " +
                    "(\(state.nonMonotonicSampleCount) samples)"
                )
            }
        } else {
            state.nonMonotonicStartUptime = now
        }
        return false
    }

    private func isVideoSampleDue(_ presentationTime: CMTime) -> Bool {
        guard videoState.lastPresentationTime.isValid else { return true }
        let spacing = presentationTime - videoState.lastPresentationTime
        return CMTimeCompare(spacing, Self.minimumVideoSampleSpacing) >= 0
    }

    private func append(
        _ sampleBuffer: CMSampleBuffer,
        at presentationTime: CMTime,
        to input: AVAssetWriterInput?,
        state: TrackState,
        label: String,
        maximumBackpressureSeconds: Double
    ) {
        guard let input else { return }
        guard input.isReadyForMoreMediaData else {
            if !state.backpressureStartTime.isValid {
                state.backpressureStartTime = presentationTime
            } else {
                let duration = CMTimeGetSeconds(presentationTime - state.backpressureStartTime)
                if duration.isFinite, duration >= maximumBackpressureSeconds {
                    reportFailure("\(label) writer input was not ready for \(String(format: "%.3f", duration)) seconds")
                }
            }
            return
        }
        state.backpressureStartTime = .invalid
        guard input.append(sampleBuffer) else {
            reportFailure("\(label) append failed: \(Self.describe(writer?.error))")
            return
        }
        state.lastPresentationTime = presentationTime
    }

    private func reportFailure(_ message: String) {
        guard !failureReported else { return }
        failureReported = true
        failureHandler?(message)
    }

    private func resetWriterReferences() {
        writer = nil
        videoInput = nil
        systemAudioInput = nil
        microphoneInput = nil
        sessionStarted = false
    }

    private static func screenFrameStatus(_ sampleBuffer: CMSampleBuffer) -> SCFrameStatus? {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: false
        ) as? [[SCStreamFrameInfo: Any]],
        let rawValue = attachments.first?[.status] as? Int else {
            return nil
        }
        return SCFrameStatus(rawValue: rawValue)
    }

    private static func isEncodableScreenFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard CMSampleBufferGetImageBuffer(sampleBuffer) != nil,
              let status = screenFrameStatus(sampleBuffer) else { return false }
        return status == .complete || status == .idle
    }

    private static func describe(_ error: Error?) -> String {
        guard let error else { return "unknown error" }
        var descriptions: [String] = []
        var current: NSError? = error as NSError
        for _ in 0..<4 {
            guard let item = current else { break }
            descriptions.append("\(item.localizedDescription) [\(item.domain) \(item.code)]")
            current = item.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return descriptions.joined(separator: " <- ")
    }

    static func aacSettings(channels: Int, bitRate: Int) -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: bitRate
        ]
    }

    private static func energy(in sampleBuffer: CMSampleBuffer) -> (sum: Double, count: Int) {
        guard let format = CMSampleBufferGetFormatDescription(sampleBuffer),
              let description = CMAudioFormatDescriptionGetStreamBasicDescription(format),
              description.pointee.mFormatID == kAudioFormatLinearPCM else {
            return (0, 0)
        }

        var requiredSize = 0
        var retainedBlockBuffer: CMBlockBuffer?
        CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &requiredSize,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment),
            blockBufferOut: &retainedBlockBuffer
        )
        guard requiredSize > 0 else { return (0, 0) }

        let memory = UnsafeMutableRawPointer.allocate(
            byteCount: requiredSize,
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { memory.deallocate() }
        let audioBufferList = memory.bindMemory(to: AudioBufferList.self, capacity: 1)
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: audioBufferList,
            bufferListSize: requiredSize,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment),
            blockBufferOut: &retainedBlockBuffer
        )
        guard status == noErr else { return (0, 0) }

        let flags = description.pointee.mFormatFlags
        var sum = 0.0
        var count = 0
        for buffer in UnsafeMutableAudioBufferListPointer(audioBufferList) {
            guard let data = buffer.mData else { continue }
            let byteCount = Int(buffer.mDataByteSize)
            if flags & kAudioFormatFlagIsFloat != 0, description.pointee.mBitsPerChannel == 32 {
                let values = UnsafeRawBufferPointer(start: data, count: byteCount).bindMemory(to: Float.self)
                for value in values {
                    let finite = value.isFinite ? Double(value) : 0
                    sum += finite * finite
                    count += 1
                }
            } else if flags & kAudioFormatFlagIsSignedInteger != 0,
                      description.pointee.mBitsPerChannel == 16 {
                let values = UnsafeRawBufferPointer(start: data, count: byteCount).bindMemory(to: Int16.self)
                for value in values {
                    let normalized = Double(value) / Double(Int16.max)
                    sum += normalized * normalized
                    count += 1
                }
            }
        }
        return (sum, count)
    }
}

private final class WriterFinishContext: @unchecked Sendable {
    private let writer: AVAssetWriter
    private let completion: @Sendable (Result<Void, Error>) -> Void

    init(writer: AVAssetWriter, completion: @escaping @Sendable (Result<Void, Error>) -> Void) {
        self.writer = writer
        self.completion = completion
    }

    func complete() {
        if writer.status == .completed {
            completion(.success(()))
        } else {
            completion(.failure(writer.error ?? CapturePipelineError.writerFinishFailed))
        }
    }
}

private final class CaptureHealthTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var captureStartedUptime: TimeInterval?
    private var lastSystemAudioUptime: TimeInterval?
    private var lastMicrophoneUptime: TimeInterval?

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        captureStartedUptime = nil
        lastSystemAudioUptime = nil
        lastMicrophoneUptime = nil
    }

    func markCaptureStarted() {
        lock.lock()
        defer { lock.unlock() }
        if captureStartedUptime == nil {
            captureStartedUptime = ProcessInfo.processInfo.systemUptime
        }
    }

    func noteSystemAudio() {
        note { lastSystemAudioUptime = $0 }
    }

    func noteMicrophone() {
        note { lastMicrophoneUptime = $0 }
    }

    func stalledTrack(maximumSilenceSeconds: TimeInterval) -> String? {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        defer { lock.unlock() }
        guard let started = captureStartedUptime else { return nil }
        let tracks: [(String, TimeInterval?)] = [
            ("system audio", lastSystemAudioUptime),
            ("microphone", lastMicrophoneUptime)
        ]
        for (label, lastSample) in tracks where now - (lastSample ?? started) >= maximumSilenceSeconds {
            return label
        }
        return nil
    }

    private func note(_ update: (TimeInterval) -> Void) {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        update(now)
        lock.unlock()
    }
}

enum CapturePipelineError: LocalizedError {
    case inputsUnsupported
    case writerStartFailed
    case writerFinishFailed
    case writerMissing
    case noSamples

    var errorDescription: String? {
        switch self {
        case .inputsUnsupported: return "AVAssetWriter does not support the requested HEVC and AAC inputs."
        case .writerStartFailed: return "AVAssetWriter failed to start."
        case .writerFinishFailed: return "AVAssetWriter failed to finish."
        case .writerMissing: return "AVAssetWriter is missing during finalization."
        case .noSamples: return "No real capture samples were received."
        }
    }
}
