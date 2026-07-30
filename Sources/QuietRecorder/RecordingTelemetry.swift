import Foundation

struct RecordingTelemetry: Codable {
    let finalizationStatus: String
    let systemAudioSampleCount: Int
    let microphoneSampleCount: Int
    let systemAudioEnergy: Double
    let microphoneAudioEnergy: Double
    let recorder: String
    let startedAt: Date
    let finishedAt: Date
}

final class AudioTelemetryAccumulator: @unchecked Sendable {
    struct Snapshot {
        let systemSampleCount: Int
        let microphoneSampleCount: Int
        let systemEnergy: Double
        let microphoneEnergy: Double
    }

    private let lock = NSLock()
    private var systemSampleCount = 0
    private var microphoneSampleCount = 0
    private var systemEnergySum = 0.0
    private var systemEnergyValueCount = 0
    private var microphoneEnergySum = 0.0
    private var microphoneEnergyValueCount = 0

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        systemSampleCount = 0
        microphoneSampleCount = 0
        systemEnergySum = 0
        systemEnergyValueCount = 0
        microphoneEnergySum = 0
        microphoneEnergyValueCount = 0
    }

    func addSystem(sum: Double, count: Int) {
        lock.lock()
        defer { lock.unlock() }
        systemSampleCount += 1
        systemEnergySum += sum
        systemEnergyValueCount += count
    }

    func addMicrophone(sum: Double, count: Int) {
        lock.lock()
        defer { lock.unlock() }
        microphoneSampleCount += 1
        microphoneEnergySum += sum
        microphoneEnergyValueCount += count
    }

    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(
            systemSampleCount: systemSampleCount,
            microphoneSampleCount: microphoneSampleCount,
            systemEnergy: systemEnergyValueCount == 0 ? 0 : sqrt(systemEnergySum / Double(systemEnergyValueCount)),
            microphoneEnergy: microphoneEnergyValueCount == 0 ? 0 : sqrt(microphoneEnergySum / Double(microphoneEnergyValueCount))
        )
    }
}
