import Foundation
import AppKit
import ApplicationServices
import CoreGraphics

func printFrontmostApplication() {
    guard let application = NSWorkspace.shared.frontmostApplication else {
        printJson(["status": "error", "code": "FRONTMOST_APP_UNAVAILABLE"])
        return
    }
    printJson([
        "status": "ok",
        "pid": application.processIdentifier,
        "appName": application.localizedName ?? "",
        "bundleIdentifier": application.bundleIdentifier ?? ""
    ])
}

func printCapabilities() {
    let application = NSWorkspace.shared.frontmostApplication

    #if arch(arm64)
    let architecture = "arm64"
    #elseif arch(x86_64)
    let architecture = "x86_64"
    #else
    let architecture = "unknown"
    #endif

    printJson([
        "status": "ok",
        "permissionPromptRequested": false,
        "permissions": [
            "accessibility": AXIsProcessTrusted(),
            "screenRecording": CGPreflightScreenCaptureAccess(),
            "inputPosting": CGPreflightPostEventAccess()
        ],
        "system": [
            "osVersion": ProcessInfo.processInfo.operatingSystemVersionString,
            "architecture": architecture,
            "frontmostApplication": [
                "pid": application?.processIdentifier ?? 0,
                "appName": application?.localizedName ?? "",
                "bundleIdentifier": application?.bundleIdentifier ?? "",
                "isLoginWindow": application?.bundleIdentifier == "com.apple.loginwindow"
            ]
        ]
    ])
}

func requireScreenCaptureAccess() -> Bool {
    guard CGPreflightScreenCaptureAccess() else {
        printJson([
            "status": "error",
            "code": "SCREEN_RECORDING_PERMISSION_REQUIRED",
            "error": "Screen Recording permission is required. Inspect get_capabilities before retrying."
        ])
        return false
    }
    return true
}
