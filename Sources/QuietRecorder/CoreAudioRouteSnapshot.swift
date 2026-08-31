import CoreAudio
import Foundation

/// A stable fingerprint of the physical audio route that ScreenCaptureKit
/// builds its system-audio tap around. Bluetooth voice-call transitions can
/// retain the same device ID while changing rate, buffer, or running state.
struct CoreAudioRouteSnapshot: Equatable, Sendable, CustomStringConvertible {
    struct Device: Equatable, Sendable {
        let id: AudioDeviceID
        let nominalSampleRate: Int?
        let actualSampleRate: Int?
        let bufferFrameSize: UInt32?
        let transportType: UInt32?
        let isRunning: Bool?
    }

    struct BluetoothInputClient: Equatable, Hashable, Sendable {
        let pid: Int32
        let deviceIDs: [AudioDeviceID]
    }

    let defaultInput: Device?
    let defaultOutput: Device?
    let defaultSystemOutput: Device?
    let nonDefaultBluetoothDevices: [Device]
    let bluetoothInputClients: [BluetoothInputClient]

    static func current() -> CoreAudioRouteSnapshot {
        let defaultInput = defaultDevice(
            for: kAudioHardwarePropertyDefaultInputDevice,
            includeRunningState: true
        )
        let defaultOutput = defaultDevice(
            for: kAudioHardwarePropertyDefaultOutputDevice,
            includeRunningState: false
        )
        let defaultSystemOutput = defaultDevice(
            for: kAudioHardwarePropertyDefaultSystemOutputDevice,
            includeRunningState: false
        )
        let defaultIDs = Set([defaultInput?.id, defaultOutput?.id, defaultSystemOutput?.id].compactMap { $0 })
        let bluetoothDevices = allDeviceIDs().compactMap { id -> Device? in
            guard !defaultIDs.contains(id),
                  let device = device(id: id, includeRunningState: true),
                  device.transportType == kAudioDeviceTransportTypeBluetooth ||
                    device.transportType == kAudioDeviceTransportTypeBluetoothLE else { return nil }
            return device
        }.sorted { $0.id < $1.id }
        return CoreAudioRouteSnapshot(
            defaultInput: defaultInput,
            defaultOutput: defaultOutput,
            defaultSystemOutput: defaultSystemOutput,
            nonDefaultBluetoothDevices: bluetoothDevices,
            bluetoothInputClients: runningBluetoothInputClients()
        )
    }

    /// Input stopping alone is ignored. Input becoming active is the Bluetooth
    /// HFP transition that can invalidate an existing ScreenCaptureKit tap.
    func recoveryReason(comparedTo previous: CoreAudioRouteSnapshot) -> String? {
        var changes: [String] = []
        Self.appendDeviceChanges(
            from: previous.defaultOutput,
            to: defaultOutput,
            label: "default output",
            includeRunningTransition: false,
            into: &changes
        )
        if previous.defaultSystemOutput?.id != previous.defaultOutput?.id ||
            defaultSystemOutput?.id != defaultOutput?.id {
            Self.appendDeviceChanges(
                from: previous.defaultSystemOutput,
                to: defaultSystemOutput,
                label: "system output",
                includeRunningTransition: false,
                into: &changes
            )
        }
        Self.appendDeviceChanges(
            from: previous.defaultInput,
            to: defaultInput,
            label: "default input",
            includeRunningTransition: true,
            into: &changes
        )
        Self.appendBluetoothDeviceChanges(
            from: previous.nonDefaultBluetoothDevices,
            to: nonDefaultBluetoothDevices,
            into: &changes
        )
        Self.appendBluetoothInputClientChanges(
            from: previous.bluetoothInputClients,
            to: bluetoothInputClients,
            into: &changes
        )
        return changes.isEmpty ? nil : changes.joined(separator: ", ")
    }

    var description: String {
        [
            "input=\(Self.describe(defaultInput))",
            "output=\(Self.describe(defaultOutput))",
            "systemOutput=\(Self.describe(defaultSystemOutput))",
            "otherBluetooth=[\(nonDefaultBluetoothDevices.map { Self.describe($0) }.joined(separator: ";"))]",
            "bluetoothInputPIDs=[\(bluetoothInputClients.map { String($0.pid) }.joined(separator: ","))]"
        ].joined(separator: " ")
    }

    private static func appendBluetoothInputClientChanges(
        from previous: [BluetoothInputClient],
        to current: [BluetoothInputClient],
        into changes: inout [String]
    ) {
        let previousSet = Set(previous)
        for client in current where !previousSet.contains(client) {
            let devices = client.deviceIDs.map(String.init).joined(separator: "+")
            changes.append("Bluetooth input client pid \(client.pid) became active on \(devices)")
        }
    }

    private static func appendBluetoothDeviceChanges(
        from previous: [Device],
        to current: [Device],
        into changes: inout [String]
    ) {
        let previousByID = Dictionary(uniqueKeysWithValues: previous.map { ($0.id, $0) })
        let currentByID = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0) })
        for id in previousByID.keys.sorted() where currentByID[id] == nil {
            changes.append("Bluetooth device \(id) disappeared")
        }
        for id in currentByID.keys.sorted() where previousByID[id] == nil {
            changes.append("Bluetooth device \(id) appeared")
        }
        for id in previousByID.keys.sorted() {
            guard let oldDevice = previousByID[id], let newDevice = currentByID[id] else { continue }
            appendDeviceChanges(
                from: oldDevice,
                to: newDevice,
                label: "Bluetooth device \(id)",
                includeRunningTransition: true,
                into: &changes
            )
        }
    }

    private static func appendDeviceChanges(
        from previous: Device?,
        to current: Device?,
        label: String,
        includeRunningTransition: Bool,
        into changes: inout [String]
    ) {
        guard let previous, let current else { return }
        if previous.id != current.id {
            changes.append("\(label) device \(previous.id)->\(current.id)")
            return
        }
        appendChange(previous.nominalSampleRate, current.nominalSampleRate, "\(label) nominal rate", into: &changes)
        appendRateChange(previous.actualSampleRate, current.actualSampleRate, "\(label) actual rate", into: &changes)
        appendChange(previous.bufferFrameSize, current.bufferFrameSize, "\(label) buffer", into: &changes)
        appendChange(previous.transportType, current.transportType, "\(label) transport", into: &changes)
        if includeRunningTransition, previous.isRunning == false, current.isRunning == true {
            changes.append("\(label) became active")
        }
    }

    private static func appendChange<T: Equatable>(
        _ previous: T?,
        _ current: T?,
        _ label: String,
        into changes: inout [String]
    ) {
        guard let previous, let current, previous != current else { return }
        changes.append("\(label) \(previous)->\(current)")
    }

    private static func appendRateChange(
        _ previous: Int?,
        _ current: Int?,
        _ label: String,
        into changes: inout [String]
    ) {
        guard let previous, let current, abs(previous - current) >= 100 else { return }
        changes.append("\(label) \(previous)->\(current)")
    }

    private static func describe(_ device: Device?) -> String {
        guard let device else { return "unavailable" }
        let nominal = device.nominalSampleRate.map(String.init) ?? "?"
        let actual = device.actualSampleRate.map(String.init) ?? "?"
        let buffer = device.bufferFrameSize.map(String.init) ?? "?"
        let running = device.isRunning.map(String.init) ?? "n/a"
        return "id:\(device.id)/nominal:\(nominal)/actual:\(actual)/buffer:\(buffer)/running:\(running)"
    }

    private static func defaultDevice(
        for selector: AudioObjectPropertySelector,
        includeRunningState: Bool
    ) -> Device? {
        guard let id = readDeviceID(selector: selector), id != kAudioObjectUnknown else { return nil }
        return device(id: id, includeRunningState: includeRunningState)
    }

    private static func device(id: AudioDeviceID, includeRunningState: Bool) -> Device? {
        return Device(
            id: id,
            nominalSampleRate: readFloat64(
                objectID: id,
                selector: kAudioDevicePropertyNominalSampleRate
            ).map { Int($0.rounded()) },
            actualSampleRate: readFloat64(
                objectID: id,
                selector: kAudioDevicePropertyActualSampleRate
            ).map { Int($0.rounded()) },
            bufferFrameSize: readUInt32(
                objectID: id,
                selector: kAudioDevicePropertyBufferFrameSize
            ),
            transportType: readUInt32(
                objectID: id,
                selector: kAudioDevicePropertyTransportType
            ),
            isRunning: includeRunningState ? readUInt32(
                objectID: id,
                selector: kAudioDevicePropertyDeviceIsRunningSomewhere
            ).map { $0 != 0 } : nil
        )
    }

    private static func allDeviceIDs() -> [AudioDeviceID] {
        readObjectIDs(
            objectID: AudioObjectID(kAudioObjectSystemObject),
            selector: kAudioHardwarePropertyDevices,
            scope: kAudioObjectPropertyScopeGlobal
        )
    }

    private static func runningBluetoothInputClients() -> [BluetoothInputClient] {
        let systemObject = AudioObjectID(kAudioObjectSystemObject)
        let processObjects = readObjectIDs(
            objectID: systemObject,
            selector: kAudioHardwarePropertyProcessObjectList,
            scope: kAudioObjectPropertyScopeGlobal
        )
        return processObjects.compactMap { processObject -> BluetoothInputClient? in
            guard readUInt32(
                objectID: processObject,
                selector: kAudioProcessPropertyIsRunningInput
            ) == 1,
            let pid = readInt32(objectID: processObject, selector: kAudioProcessPropertyPID) else {
                return nil
            }
            let bluetoothDeviceIDs = readObjectIDs(
                objectID: processObject,
                selector: kAudioProcessPropertyDevices,
                scope: kAudioObjectPropertyScopeInput
            ).filter { id in
                let transport = readUInt32(
                    objectID: id,
                    selector: kAudioDevicePropertyTransportType
                )
                return transport == kAudioDeviceTransportTypeBluetooth ||
                    transport == kAudioDeviceTransportTypeBluetoothLE
            }.sorted()
            guard !bluetoothDeviceIDs.isEmpty else { return nil }
            return BluetoothInputClient(pid: pid, deviceIDs: bluetoothDeviceIDs)
        }.sorted {
            $0.pid == $1.pid ? $0.deviceIDs.lexicographicallyPrecedes($1.deviceIDs) : $0.pid < $1.pid
        }
    }

    private static func readObjectIDs(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope
    ) -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(objectID, &address, 0, nil, &size) == noErr,
              size >= MemoryLayout<AudioObjectID>.size else { return [] }
        var devices = Array(
            repeating: AudioObjectID(kAudioObjectUnknown),
            count: Int(size) / MemoryLayout<AudioObjectID>.size
        )
        let status = devices.withUnsafeMutableBytes { bytes in
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, bytes.baseAddress!)
        }
        return status == noErr ? devices.filter { $0 != kAudioObjectUnknown } : []
    }

    private static func readInt32(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector
    ) -> Int32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(objectID, &address) else { return nil }
        var value: Int32 = 0
        var size = UInt32(MemoryLayout<Int32>.size)
        let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value)
        return status == noErr ? value : nil
    }

    private static func readDeviceID(selector: AudioObjectPropertySelector) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value = kAudioObjectUnknown
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &value
        )
        return status == noErr ? value : nil
    }

    private static func readUInt32(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector
    ) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(objectID, &address) else { return nil }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value)
        return status == noErr ? value : nil
    }

    private static func readFloat64(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector
    ) -> Float64? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(objectID, &address) else { return nil }
        var value: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value)
        return status == noErr && value.isFinite ? value : nil
    }
}
