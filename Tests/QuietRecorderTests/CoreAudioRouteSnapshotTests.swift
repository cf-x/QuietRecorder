import CoreAudio
import Foundation

@main
struct CoreAudioRouteSnapshotTests {
    static func main() {
        currentRouteSnapshotCanBeRead()
        unchangedRouteDoesNotRequestRecovery()
        defaultInputBecomingActiveRequestsRecovery()
        defaultInputStoppingDoesNotRequestRecovery()
        outputDeviceChangeRequestsRecovery()
        outputSampleRateChangeRequestsRecovery()
        smallActualRateDriftDoesNotRequestRecovery()
        nonDefaultBluetoothInputActivationRequestsRecovery()
        bluetoothInputClientActivationRequestsRecovery()
        recoveryValidationRequiresBuffersAndMinus70DBFSSignal()
        recoveryValidationComputesWindowRMS()
        print("PASS: CoreAudio route recovery policy tests")
    }

    private static func currentRouteSnapshotCanBeRead() {
        let description = CoreAudioRouteSnapshot.current().description
        require(!description.isEmpty, "current CoreAudio route could not be described")
    }

    private static func unchangedRouteDoesNotRequestRecovery() {
        let route = makeRoute(inputRunning: false)
        require(route.recoveryReason(comparedTo: route) == nil, "unchanged route requested recovery")
    }

    private static func defaultInputBecomingActiveRequestsRecovery() {
        let previous = makeRoute(inputRunning: false)
        let current = makeRoute(inputRunning: true)
        require(
            current.recoveryReason(comparedTo: previous) == "default input became active",
            "input activation was not detected"
        )
    }

    private static func defaultInputStoppingDoesNotRequestRecovery() {
        let previous = makeRoute(inputRunning: true)
        let current = makeRoute(inputRunning: false)
        require(current.recoveryReason(comparedTo: previous) == nil, "input stop requested recovery")
    }

    private static func outputDeviceChangeRequestsRecovery() {
        let previous = makeRoute(outputID: 20)
        let current = makeRoute(outputID: 99)
        require(
            current.recoveryReason(comparedTo: previous) == "default output device 20->99",
            "output device change was not detected"
        )
    }

    private static func outputSampleRateChangeRequestsRecovery() {
        let previous = makeRoute(outputRate: 48_000)
        let current = makeRoute(outputRate: 24_000)
        require(
            current.recoveryReason(comparedTo: previous) ==
            "default output nominal rate 48000->24000, default output actual rate 48000->24000",
            "output rate change was not detected"
        )
    }

    private static func smallActualRateDriftDoesNotRequestRecovery() {
        let previous = makeRoute(outputActualRate: 47_999)
        let current = makeRoute(outputActualRate: 48_001)
        require(current.recoveryReason(comparedTo: previous) == nil, "small clock drift requested recovery")
    }

    private static func nonDefaultBluetoothInputActivationRequestsRecovery() {
        let idleDevice = bluetoothDevice(id: 42, isRunning: false)
        let activeDevice = bluetoothDevice(id: 42, isRunning: true)
        let previous = makeRoute(bluetoothDevices: [idleDevice])
        let current = makeRoute(bluetoothDevices: [activeDevice])
        require(
            current.recoveryReason(comparedTo: previous) == "Bluetooth device 42 became active",
            "non-default Bluetooth activation was not detected"
        )
    }

    private static func bluetoothInputClientActivationRequestsRecovery() {
        let client = CoreAudioRouteSnapshot.BluetoothInputClient(pid: 1234, deviceIDs: [42])
        let previous = makeRoute()
        let current = makeRoute(bluetoothInputClients: [client])
        require(
            current.recoveryReason(comparedTo: previous) ==
            "Bluetooth input client pid 1234 became active on 42",
            "Bluetooth input client activation was not detected"
        )
    }

    private static func recoveryValidationRequiresBuffersAndMinus70DBFSSignal() {
        require(
            !CaptureHealthTracker.SystemAudioValidation(sampleBufferCount: 0, rms: 1).hasUsableSignal,
            "empty validation window passed"
        )
        require(
            !CaptureHealthTracker.SystemAudioValidation(sampleBufferCount: 300, rms: 0.000_1).hasUsableSignal,
            "near-silent validation window passed"
        )
        require(
            CaptureHealthTracker.SystemAudioValidation(sampleBufferCount: 300, rms: 0.000_316).hasUsableSignal,
            "-70 dBFS validation boundary failed"
        )
    }

    private static func recoveryValidationComputesWindowRMS() {
        let tracker = CaptureHealthTracker()
        tracker.reset()
        tracker.beginSystemAudioRecoveryValidation()
        tracker.noteSystemAudio(sum: 0.000_004, count: 4)
        tracker.noteSystemAudio(sum: 0.000_004, count: 4)
        let validation = tracker.systemAudioRecoveryValidation()
        require(validation.sampleBufferCount == 2, "validation buffer count is wrong")
        require(abs(validation.rms - 0.001) < 0.000_000_1, "validation RMS is wrong")
    }

    private static func makeRoute(
        inputRunning: Bool = false,
        outputID: AudioDeviceID = 20,
        outputRate: Int = 48_000,
        outputActualRate: Int? = nil,
        bluetoothDevices: [CoreAudioRouteSnapshot.Device] = [],
        bluetoothInputClients: [CoreAudioRouteSnapshot.BluetoothInputClient] = []
    ) -> CoreAudioRouteSnapshot {
        let input = CoreAudioRouteSnapshot.Device(
            id: 10,
            nominalSampleRate: 48_000,
            actualSampleRate: 48_000,
            bufferFrameSize: 512,
            transportType: kAudioDeviceTransportTypeBluetooth,
            isRunning: inputRunning
        )
        let output = CoreAudioRouteSnapshot.Device(
            id: outputID,
            nominalSampleRate: outputRate,
            actualSampleRate: outputActualRate ?? outputRate,
            bufferFrameSize: 512,
            transportType: kAudioDeviceTransportTypeBluetooth,
            isRunning: nil
        )
        return CoreAudioRouteSnapshot(
            defaultInput: input,
            defaultOutput: output,
            defaultSystemOutput: output,
            nonDefaultBluetoothDevices: bluetoothDevices,
            bluetoothInputClients: bluetoothInputClients
        )
    }

    private static func bluetoothDevice(
        id: AudioDeviceID,
        isRunning: Bool
    ) -> CoreAudioRouteSnapshot.Device {
        CoreAudioRouteSnapshot.Device(
            id: id,
            nominalSampleRate: 24_000,
            actualSampleRate: 24_000,
            bufferFrameSize: 256,
            transportType: kAudioDeviceTransportTypeBluetooth,
            isRunning: isRunning
        )
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fputs("FAIL: \(message)\n", stderr)
            exit(1)
        }
    }
}
