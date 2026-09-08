import AudioToolbox
import AVFoundation
import CoreMedia

enum RecordingFinalizer {
    static let mixedTrackTitle = "mixed"
    static let systemTrackTitle = "system"
    static let microphoneTrackTitle = "microphone"

    static func finalize(
        captureURL: URL,
        mixedURL: URL,
        outputURL: URL,
        completion: @escaping @Sendable (Result<Void, Error>) -> Void
    ) {
        mix(captureURL: captureURL, outputURL: mixedURL) { result in
            switch result {
            case .success:
                packageTracks(
                    captureURL: captureURL,
                    mixedURL: mixedURL,
                    outputURL: outputURL,
                    completion: completion
                )
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    private static func mix(
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
        setTrackTitle(mixedTrackTitle, on: audioInput)
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
            throw reader.error ?? RecordingFinalizerError.readerStartFailed("audio mix")
        }

        MediaTransferCoordinator(
            readers: [reader],
            writer: writer,
            transfers: [
                MediaTransfer(label: "video", reader: reader, output: videoOutput, input: videoInput),
                MediaTransfer(label: "mixed audio", reader: reader, output: audioOutput, input: audioInput)
            ],
            completion: completion
        ).start()
    }

    private static func packageTracks(
        captureURL: URL,
        mixedURL: URL,
        outputURL: URL,
        completion: @escaping @Sendable (Result<Void, Error>) -> Void
    ) {
        Task.detached(priority: .userInitiated) {
            do {
                let mixedAsset = AVURLAsset(url: mixedURL)
                let captureAsset = AVURLAsset(url: captureURL)
                guard let videoTrack = try await mixedAsset.loadTracks(withMediaType: .video).first else {
                    throw RecordingFinalizerError.missingVideo
                }
                let mixedAudioTracks = try await mixedAsset.loadTracks(withMediaType: .audio)
                guard mixedAudioTracks.count == 1, let mixedAudioTrack = mixedAudioTracks.first else {
                    throw RecordingFinalizerError.expectedOneMixedAudioTrack(mixedAudioTracks.count)
                }
                let sourceAudioTracks = try await captureAsset.loadTracks(withMediaType: .audio)
                guard sourceAudioTracks.count == 2 else {
                    throw RecordingFinalizerError.expectedTwoAudioTracks(sourceAudioTracks.count)
                }
                let systemAudioTrack = sourceAudioTracks[0]
                let microphoneTrack = sourceAudioTracks[1]

                guard let videoFormat = try await videoTrack.load(.formatDescriptions).first else {
                    throw RecordingFinalizerError.missingVideoFormat
                }
                guard let mixedAudioFormat = try await mixedAudioTrack.load(.formatDescriptions).first else {
                    throw RecordingFinalizerError.missingAudioFormat(mixedTrackTitle)
                }
                guard let systemAudioFormat = try await systemAudioTrack.load(.formatDescriptions).first else {
                    throw RecordingFinalizerError.missingAudioFormat(systemTrackTitle)
                }
                guard let microphoneFormat = try await microphoneTrack.load(.formatDescriptions).first else {
                    throw RecordingFinalizerError.missingAudioFormat(microphoneTrackTitle)
                }

                try packageSynchronously(
                    mixedAsset: mixedAsset,
                    captureAsset: captureAsset,
                    videoTrack: videoTrack,
                    mixedAudioTrack: mixedAudioTrack,
                    systemAudioTrack: systemAudioTrack,
                    microphoneTrack: microphoneTrack,
                    videoFormat: videoFormat,
                    mixedAudioFormat: mixedAudioFormat,
                    systemAudioFormat: systemAudioFormat,
                    microphoneFormat: microphoneFormat,
                    outputURL: outputURL,
                    completion: completion
                )
            } catch {
                completion(.failure(error))
            }
        }
    }

    private static func packageSynchronously(
        mixedAsset: AVURLAsset,
        captureAsset: AVURLAsset,
        videoTrack: AVAssetTrack,
        mixedAudioTrack: AVAssetTrack,
        systemAudioTrack: AVAssetTrack,
        microphoneTrack: AVAssetTrack,
        videoFormat: CMFormatDescription,
        mixedAudioFormat: CMFormatDescription,
        systemAudioFormat: CMFormatDescription,
        microphoneFormat: CMFormatDescription,
        outputURL: URL,
        completion: @escaping @Sendable (Result<Void, Error>) -> Void
    ) throws {
        let mixedReader = try AVAssetReader(asset: mixedAsset)
        let videoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: nil)
        let mixedAudioOutput = AVAssetReaderTrackOutput(track: mixedAudioTrack, outputSettings: nil)
        videoOutput.alwaysCopiesSampleData = false
        mixedAudioOutput.alwaysCopiesSampleData = false
        guard mixedReader.canAdd(videoOutput), mixedReader.canAdd(mixedAudioOutput) else {
            throw RecordingFinalizerError.packagingReaderOutputsUnsupported("mixed recording")
        }
        mixedReader.add(videoOutput)
        mixedReader.add(mixedAudioOutput)

        let captureReader = try AVAssetReader(asset: captureAsset)
        let systemAudioOutput = AVAssetReaderTrackOutput(track: systemAudioTrack, outputSettings: nil)
        let microphoneOutput = AVAssetReaderTrackOutput(track: microphoneTrack, outputSettings: nil)
        systemAudioOutput.alwaysCopiesSampleData = false
        microphoneOutput.alwaysCopiesSampleData = false
        guard captureReader.canAdd(systemAudioOutput), captureReader.canAdd(microphoneOutput) else {
            throw RecordingFinalizerError.packagingReaderOutputsUnsupported("source recording")
        }
        captureReader.add(systemAudioOutput)
        captureReader.add(microphoneOutput)

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        let videoInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: nil,
            sourceFormatHint: videoFormat
        )
        let mixedAudioInput = passthroughAudioInput(format: mixedAudioFormat, title: mixedTrackTitle)
        let systemAudioInput = passthroughAudioInput(format: systemAudioFormat, title: systemTrackTitle)
        let microphoneInput = passthroughAudioInput(format: microphoneFormat, title: microphoneTrackTitle)
        let inputs = [videoInput, mixedAudioInput, systemAudioInput, microphoneInput]
        guard inputs.allSatisfy(writer.canAdd) else {
            throw RecordingFinalizerError.packagingWriterInputsUnsupported
        }
        inputs.forEach(writer.add)

        let audioGroup = AVAssetWriterInputGroup(
            inputs: [mixedAudioInput, systemAudioInput, microphoneInput],
            defaultInput: mixedAudioInput
        )
        guard writer.canAdd(audioGroup) else {
            throw RecordingFinalizerError.audioInputGroupUnsupported
        }
        writer.add(audioGroup)

        guard writer.startWriting() else {
            throw writer.error ?? RecordingFinalizerError.writerStartFailed
        }
        writer.startSession(atSourceTime: .zero)
        guard mixedReader.startReading() else {
            writer.cancelWriting()
            throw mixedReader.error ?? RecordingFinalizerError.readerStartFailed("mixed recording")
        }
        guard captureReader.startReading() else {
            mixedReader.cancelReading()
            writer.cancelWriting()
            throw captureReader.error ?? RecordingFinalizerError.readerStartFailed("source recording")
        }

        MediaTransferCoordinator(
            readers: [mixedReader, captureReader],
            writer: writer,
            transfers: [
                MediaTransfer(label: "video", reader: mixedReader, output: videoOutput, input: videoInput),
                MediaTransfer(label: "mixed audio", reader: mixedReader, output: mixedAudioOutput, input: mixedAudioInput),
                MediaTransfer(label: "system audio", reader: captureReader, output: systemAudioOutput, input: systemAudioInput),
                MediaTransfer(label: "microphone", reader: captureReader, output: microphoneOutput, input: microphoneInput)
            ],
            completion: completion
        ).start()
    }

    private static func passthroughAudioInput(
        format: CMFormatDescription,
        title: String
    ) -> AVAssetWriterInput {
        let input = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: nil,
            sourceFormatHint: format
        )
        setTrackTitle(title, on: input)
        return input
    }

    private static func setTrackTitle(_ title: String, on input: AVAssetWriterInput) {
        let commonTitle = AVMutableMetadataItem()
        commonTitle.identifier = .commonIdentifierTitle
        commonTitle.value = title as NSString

        let displayName = AVMutableMetadataItem()
        displayName.identifier = .quickTimeMetadataDisplayName
        displayName.value = title as NSString

        let trackName = AVMutableMetadataItem()
        trackName.identifier = .quickTimeUserDataTrackName
        trackName.value = title as NSString
        input.metadata = [commonTitle, displayName, trackName]
    }
}

private struct MediaTransfer {
    let label: String
    let reader: AVAssetReader
    let output: AVAssetReaderOutput
    let input: AVAssetWriterInput
}

private final class MediaTransferCoordinator: @unchecked Sendable {
    // AVFoundation calls back concurrently, but all mutable transfer state is confined to queue.
    private let readers: [AVAssetReader]
    private let writer: AVAssetWriter
    private let transfers: [MediaTransfer]
    private let completion: @Sendable (Result<Void, Error>) -> Void
    private let queue = DispatchQueue(label: "com.fangchenfang.QuietRecorder.finalizer")
    private var finished: [Bool]
    private var finalizationStarted = false

    init(
        readers: [AVAssetReader],
        writer: AVAssetWriter,
        transfers: [MediaTransfer],
        completion: @escaping @Sendable (Result<Void, Error>) -> Void
    ) {
        self.readers = readers
        self.writer = writer
        self.transfers = transfers
        self.completion = completion
        finished = Array(repeating: false, count: transfers.count)
    }

    func start() {
        for index in transfers.indices {
            transfers[index].input.requestMediaDataWhenReady(on: queue) { [self] in
                pump(index)
            }
        }
    }

    private func pump(_ index: Int) {
        guard !finished[index], !finalizationStarted else { return }
        let transfer = transfers[index]
        while transfer.input.isReadyForMoreMediaData {
            guard let sample = transfer.output.copyNextSampleBuffer() else {
                guard transfer.reader.status != .failed, transfer.reader.status != .cancelled else {
                    fail(transfer.reader.error ?? RecordingFinalizerError.transferFailed(transfer.label))
                    return
                }
                transfer.input.markAsFinished()
                finished[index] = true
                finishIfReady()
                return
            }
            guard transfer.input.append(sample) else {
                fail(writer.error ?? RecordingFinalizerError.sampleAppendFailed(transfer.label))
                return
            }
        }
    }

    private func finishIfReady() {
        guard finished.allSatisfy({ $0 }), !finalizationStarted else { return }
        finalizationStarted = true
        let incompleteReaders = readers.filter { $0.status != .completed }
        guard incompleteReaders.isEmpty else {
            writer.cancelWriting()
            let detail = incompleteReaders.map { "status=\($0.status.rawValue) error=\($0.error?.localizedDescription ?? "none")" }
                .joined(separator: "; ")
            completion(.failure(RecordingFinalizerError.readersDidNotComplete(detail)))
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
        readers.forEach { $0.cancelReading() }
        writer.cancelWriting()
        completion(.failure(error))
    }
}

enum RecordingFinalizerError: LocalizedError {
    case missingVideo
    case expectedTwoAudioTracks(Int)
    case expectedOneMixedAudioTrack(Int)
    case readerOutputsUnsupported
    case packagingReaderOutputsUnsupported(String)
    case missingVideoFormat
    case missingAudioFormat(String)
    case writerInputsUnsupported
    case packagingWriterInputsUnsupported
    case audioInputGroupUnsupported
    case writerStartFailed
    case readerStartFailed(String)
    case transferFailed(String)
    case sampleAppendFailed(String)
    case readersDidNotComplete(String)
    case writerDidNotComplete

    var errorDescription: String? {
        switch self {
        case .missingVideo: return "Recording has no video track."
        case .expectedTwoAudioTracks(let count): return "Source recording has \(count) audio tracks; expected system and microphone tracks."
        case .expectedOneMixedAudioTrack(let count): return "Mixed recording has \(count) audio tracks; expected one."
        case .readerOutputsUnsupported: return "AVAssetReader cannot create video pass-through and audio mix outputs."
        case .packagingReaderOutputsUnsupported(let source): return "AVAssetReader cannot package tracks from \(source)."
        case .missingVideoFormat: return "HEVC format description is missing."
        case .missingAudioFormat(let title): return "Audio format description is missing for \(title)."
        case .writerInputsUnsupported: return "Audio mix writer does not support HEVC pass-through plus AAC."
        case .packagingWriterInputsUnsupported: return "Final MP4 writer does not support video plus three AAC tracks."
        case .audioInputGroupUnsupported: return "Final MP4 writer cannot mark the mixed audio track as the default."
        case .writerStartFailed: return "AVAssetWriter failed to start."
        case .readerStartFailed(let source): return "AVAssetReader failed to start for \(source)."
        case .transferFailed(let label): return "Media transfer failed for \(label)."
        case .sampleAppendFailed(let label): return "Sample append failed for \(label)."
        case .readersDidNotComplete(let detail): return "Media readers did not complete: \(detail)"
        case .writerDidNotComplete: return "AVAssetWriter did not complete."
        }
    }
}
