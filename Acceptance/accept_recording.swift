import AVFoundation
import AudioToolbox
import CoreMedia
import Foundation

struct Telemetry: Decodable {
    let finalizationStatus: String
    let systemAudioSampleCount: Int
    let microphoneSampleCount: Int
    let systemAudioEnergy: Double
    let microphoneAudioEnergy: Double
}

func fail(_ message: String) -> Never {
    fputs("FAIL: \(message)\n", stderr)
    exit(1)
}

guard CommandLine.arguments.count == 2 else {
    fail("usage: accept_recording.swift RECORDING.mp4")
}

let recordingURL = URL(fileURLWithPath: CommandLine.arguments[1])
let telemetryURL = recordingURL.deletingPathExtension().appendingPathExtension("telemetry.json")

Task {
    do {
        let asset = AVURLAsset(url: recordingURL)
        let duration = try await asset.load(.duration).seconds
        guard duration >= 58 else { fail("duration \(duration)s is below 58s") }

        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard videoTracks.count == 1, let video = videoTracks.first else {
            fail("expected exactly one video track")
        }
        let naturalSize = try await video.load(.naturalSize)
        let transform = try await video.load(.preferredTransform)
        let displayed = naturalSize.applying(transform)
        let width = Int(abs(displayed.width).rounded())
        let height = Int(abs(displayed.height).rounded())
        guard width == 1280, height == 720 else {
            fail("display dimensions are \(width)x\(height), expected 1280x720")
        }
        let frameRate = try await video.load(.nominalFrameRate)
        guard frameRate >= 14, frameRate <= 16 else {
            fail("nominal frame rate \(frameRate) is outside 14...16 FPS")
        }
        let videoFormats = try await video.load(.formatDescriptions)
        guard videoFormats.contains(where: { CMFormatDescriptionGetMediaSubType($0) == kCMVideoCodecType_HEVC }) else {
            fail("video codec is not HEVC/H.265")
        }

        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard audioTracks.count == 1, let audio = audioTracks.first else {
            fail("expected exactly one mixed audio track, found \(audioTracks.count)")
        }
        let audioFormats = try await audio.load(.formatDescriptions)
        guard audioFormats.contains(where: { CMFormatDescriptionGetMediaSubType($0) == kAudioFormatMPEG4AAC }) else {
            fail("mixed audio codec is not AAC")
        }

        guard FileManager.default.fileExists(atPath: telemetryURL.path) else {
            fail("telemetry sidecar is missing")
        }
        let telemetry = try JSONDecoder().decode(Telemetry.self, from: Data(contentsOf: telemetryURL))
        guard telemetry.finalizationStatus == "completed" else {
            fail("recording was not finalized successfully")
        }
        guard telemetry.systemAudioSampleCount > 0, telemetry.microphoneSampleCount > 0 else {
            fail("both real ScreenCaptureKit audio output types must contain samples")
        }
        guard telemetry.systemAudioEnergy > 0.000001, telemetry.microphoneAudioEnergy > 0.000001 else {
            fail("both real audio inputs must contain non-silent PCM energy")
        }

        let values = try recordingURL.resourceValues(forKeys: [.fileSizeKey])
        guard let fileSize = values.fileSize else { fail("unable to read file size") }
        let projectedBytesPerHour = Double(fileSize) * 3600 / duration
        let limit = 650.0 * 1024 * 1024
        guard projectedBytesPerHour <= limit else {
            fail("projected size \(projectedBytesPerHour) B/hour exceeds 650 MiB/hour")
        }

        print("PASS: duration=\(String(format: "%.3f", duration))s")
        print("PASS: video=1280x720 HEVC nominalFPS=\(String(format: "%.3f", frameRate))")
        print("PASS: audioTracks=1 codec=AAC systemSamples=\(telemetry.systemAudioSampleCount) microphoneSamples=\(telemetry.microphoneSampleCount)")
        print("PASS: systemEnergy=\(telemetry.systemAudioEnergy) microphoneEnergy=\(telemetry.microphoneAudioEnergy)")
        print("PASS: fileBytes=\(fileSize) projectedMiBPerHour=\(String(format: "%.3f", projectedBytesPerHour / 1024 / 1024))")
        exit(0)
    } catch {
        fail("inspection error: \(error)")
    }
}

dispatchMain()
