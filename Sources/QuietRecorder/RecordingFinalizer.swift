import AudioToolbox
import AVFoundation
import CoreMedia

enum RecordingFinalizer {
    static func mix(
        captureURL: URL,
        outputURL: URL,
        completion: @escaping @Sendable (Result<Void, Error>) -> Void
    ) {
        Task.detached(priority: .userInitiated) {
            do {
                let asset = AVURLAsset(url: captureURL)
                guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
                    throw RecordingFinalizerError.missingVideo
                }
                let audioTracks = try await asset.loadTracks(withMediaType: .audio)
                guard audioTracks.count == 2 else {
                    throw RecordingFinalizerError.expectedTwoAudioTracks(audioTracks.count)
                }
                guard let videoFormat = try await videoTrack.load(.formatDescriptions).first else {
                    throw RecordingFinalizerError.missingVideoFormat
                }
                try mixSynchronously(
                    asset: asset,
                    videoTrack: videoTrack,
                    audioTracks: audioTracks,
                    videoFormat: videoFormat,
                    outputURL: outputURL,
                    completion: completion
                )
            } catch {
                completion(.failure(error))
            }
        }
    }

    private static func mixSynchronously(
        asset: AVURLAsset,
        videoTrack: AVAssetTrack,
        audioTracks: [AVAssetTrack],
        videoFormat: CMFormatDescription,
        outputURL: URL,
        completion: @escaping @Sendable (Result<Void, Error>) -> Void
    ) throws {
        let reader = try AVAssetReader(asset: asset)
        let videoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: nil)
        videoOutput.alwaysCopiesSampleData = false

        let pcmSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false
        ]
        let audioOutput = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: pcmSettings)
        let mix = AVMutableAudioMix()
        mix.inputParameters = audioTracks.map { track in
            let parameters = AVMutableAudioMixInputParameters(track: track)
            parameters.setVolume(0.7, at: .zero)
            return parameters
        }
        audioOutput.audioMix = mix

        guard reader.canAdd(videoOutput), reader.canAdd(audioOutput) else {
            throw RecordingFinalizerError.readerOutputsUnsupported
        }
        reader.add(videoOutput)
        reader.add(audioOutput)

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        let videoInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: nil,
            sourceFormatHint: videoFormat
        )
        let audioInput = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: CapturePipeline.aacSettings(channels: 2, bitRate: 96_000)
        )
        guard writer.canAdd(videoInput), writer.canAdd(audioInput) else {
            throw RecordingFinalizerError.writerInputsUnsupported
        }
        writer.add(videoInput)
        writer.add(audioInput)

        guard writer.startWriting() else {
            throw writer.error ?? RecordingFinalizerError.writerStartFailed
        }
        writer.startSession(atSourceTime: .zero)
        guard reader.startReading() else {
            writer.cancelWriting()
            throw reader.error ?? RecordingFinalizerError.readerStartFailed
        }

        MediaTransferCoordinator(
            reader: reader,
            writer: writer,
            videoOutput: videoOutput,
            audioOutput: audioOutput,
            videoInput: videoInput,
            audioInput: audioInput,
            completion: completion
        ).start()
    }

}

private final class MediaTransferCoordinator: @unchecked Sendable {
    // AVFoundation calls back concurrently, but all mutable transfer state is confined to queue.
    private let reader: AVAssetReader
    private let writer: AVAssetWriter
    private let videoOutput: AVAssetReaderTrackOutput
    private let audioOutput: AVAssetReaderAudioMixOutput
    private let videoInput: AVAssetWriterInput
    private let audioInput: AVAssetWriterInput
    private let completion: @Sendable (Result<Void, Error>) -> Void
    private let queue = DispatchQueue(label: "com.fangchenfang.QuietRecorder.finalizer")
    private var videoFinished = false
    private var audioFinished = false
    private var finalizationStarted = false

    init(
        reader: AVAssetReader,
        writer: AVAssetWriter,
        videoOutput: AVAssetReaderTrackOutput,
        audioOutput: AVAssetReaderAudioMixOutput,
        videoInput: AVAssetWriterInput,
        audioInput: AVAssetWriterInput,
        completion: @escaping @Sendable (Result<Void, Error>) -> Void
    ) {
        self.reader = reader
        self.writer = writer
        self.videoOutput = videoOutput
        self.audioOutput = audioOutput
        self.videoInput = videoInput
        self.audioInput = audioInput
        self.completion = completion
    }

    func start() {
        videoInput.requestMediaDataWhenReady(on: queue) { self.pumpVideo() }
        audioInput.requestMediaDataWhenReady(on: queue) { self.pumpAudio() }
    }

    private func pumpVideo() {
        guard !videoFinished, !finalizationStarted else { return }
        while videoInput.isReadyForMoreMediaData {
            guard let sample = videoOutput.copyNextSampleBuffer() else {
                guard reader.status != .failed, reader.status != .cancelled else {
                    fail(reader.error ?? RecordingFinalizerError.transferFailed)
                    return
                }
                videoInput.markAsFinished()
                videoFinished = true
                finishIfReady()
                return
            }
            guard videoInput.append(sample) else {
                fail(writer.error ?? RecordingFinalizerError.videoAppendFailed)
                return
            }
        }
    }

    private func pumpAudio() {
        guard !audioFinished, !finalizationStarted else { return }
        while audioInput.isReadyForMoreMediaData {
            guard let sample = audioOutput.copyNextSampleBuffer() else {
                guard reader.status != .failed, reader.status != .cancelled else {
                    fail(reader.error ?? RecordingFinalizerError.transferFailed)
                    return
                }
                audioInput.markAsFinished()
                audioFinished = true
                finishIfReady()
                return
            }
            guard audioInput.append(sample) else {
                fail(writer.error ?? RecordingFinalizerError.audioAppendFailed)
                return
            }
        }
    }

    private func finishIfReady() {
        guard videoFinished, audioFinished, !finalizationStarted else { return }
        finalizationStarted = true
        guard reader.status == .completed else {
            writer.cancelWriting()
            completion(.failure(reader.error ?? RecordingFinalizerError.readerDidNotComplete))
            return
        }
        writer.finishWriting { [self] in
            if writer.status == .completed {
                completion(.success(()))
            } else {
                completion(.failure(writer.error ?? RecordingFinalizerError.writerDidNotComplete))
            }
        }
    }

    private func fail(_ error: Error) {
        guard !finalizationStarted else { return }
        finalizationStarted = true
        reader.cancelReading()
        writer.cancelWriting()
        completion(.failure(error))
    }
}

enum RecordingFinalizerError: LocalizedError {
    case missingVideo
    case expectedTwoAudioTracks(Int)
    case readerOutputsUnsupported
    case missingVideoFormat
    case writerInputsUnsupported
    case writerStartFailed
    case readerStartFailed
    case transferFailed
    case videoAppendFailed
    case audioAppendFailed
    case readerDidNotComplete
    case writerDidNotComplete

    var errorDescription: String? {
        switch self {
        case .missingVideo: return "Temporary capture has no video track."
        case .expectedTwoAudioTracks(let count): return "Temporary capture has \(count) audio tracks; expected two real inputs."
        case .readerOutputsUnsupported: return "AVAssetReader cannot create video pass-through and audio mix outputs."
        case .missingVideoFormat: return "Temporary HEVC format description is missing."
        case .writerInputsUnsupported: return "Final MP4 writer does not support HEVC pass-through plus AAC."
        case .writerStartFailed: return "Final MP4 writer failed to start."
        case .readerStartFailed: return "Temporary capture reader failed to start."
        case .transferFailed: return "Media transfer failed during finalization."
        case .videoAppendFailed: return "HEVC pass-through append failed."
        case .audioAppendFailed: return "Mixed AAC append failed."
        case .readerDidNotComplete: return "Temporary capture reader did not complete."
        case .writerDidNotComplete: return "Final MP4 writer did not complete."
        }
    }
}
