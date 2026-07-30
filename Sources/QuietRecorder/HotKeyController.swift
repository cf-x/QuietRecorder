import Carbon
import Foundation

@MainActor
final class HotKeyController {
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: @MainActor () -> Void

    init(action: @escaping @MainActor () -> Void) throws {
        self.action = action
        var specification = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, pointer in
                guard let pointer else { return noErr }
                let controller = Unmanaged<HotKeyController>.fromOpaque(pointer).takeUnretainedValue()
                MainActor.assumeIsolated { controller.action() }
                return noErr
            },
            1,
            &specification,
            Unmanaged.passUnretained(self).toOpaque(),
            &handler
        )
        guard status == noErr else { throw HotKeyError.install(status) }

        let identifier = EventHotKeyID(signature: 0x51524543, id: 1)
        let modifiers = UInt32(controlKey | optionKey | cmdKey)
        let registerStatus = RegisterEventHotKey(
            UInt32(kVK_ANSI_R),
            modifiers,
            identifier,
            GetApplicationEventTarget(),
            0,
            &hotKey
        )
        guard registerStatus == noErr else { throw HotKeyError.register(registerStatus) }
    }

    isolated deinit {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
    }
}

enum HotKeyError: LocalizedError {
    case install(OSStatus)
    case register(OSStatus)

    var errorDescription: String? {
        switch self {
        case .install(let status): return "安装全局快捷键事件处理器失败：\(status)"
        case .register(let status): return "注册 Control+Option+Command+R 失败：\(status)"
        }
    }
}
