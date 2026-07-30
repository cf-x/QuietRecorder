import AVFoundation
import CoreGraphics
import Foundation

enum PermissionError: LocalizedError {
    case microphoneDenied
    case screenDenied

    var errorDescription: String? {
        switch self {
        case .microphoneDenied:
            return "麦克风权限被拒绝；请在系统设置的隐私与安全性中允许 QuietRecorder。"
        case .screenDenied:
            return "屏幕与系统音频录制权限未授权；请在系统设置的隐私与安全性中允许 QuietRecorder 后重试。"
        }
    }
}

enum PermissionGate {
    static func requireMicrophone() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return
        case .notDetermined:
            let granted = await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { continuation.resume(returning: $0) }
            }
            guard granted else { throw PermissionError.microphoneDenied }
        default:
            throw PermissionError.microphoneDenied
        }
    }

}
