import CoreGraphics
import Foundation

guard CommandLine.arguments.count == 2, let pid = Int32(CommandLine.arguments[1]) else {
    fputs("FAIL: usage: accept_runtime_visibility.swift PID\n", stderr)
    exit(2)
}

let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
    fputs("FAIL: unable to read the on-screen window list\n", stderr)
    exit(1)
}

let ownedVisibleWindows = windows.filter { window in
    guard let ownerPID = window[kCGWindowOwnerPID as String] as? Int32, ownerPID == pid else {
        return false
    }
    let alpha = window[kCGWindowAlpha as String] as? Double ?? 1
    guard alpha > 0 else { return false }
    guard let boundsDictionary = window[kCGWindowBounds as String] as? [String: Any],
          let bounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary) else {
        return false
    }
    return bounds.width > 1 && bounds.height > 1
}

if !ownedVisibleWindows.isEmpty {
    fputs("FAIL: visible application window count=\(ownedVisibleWindows.count)\n", stderr)
    exit(1)
}

print("PASS: visible application window count=0")
