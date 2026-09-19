import Foundation
import CoreGraphics
import AppKit

func listWindows(targetApp: String? = nil, minSize: Double = 80.0, includeAll: Bool = false) {
    let options = CGWindowListOption(arrayLiteral: .optionAll)
    guard let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
        printJson(["windows": []])
        return
    }
    
    var results: [[String: Any]] = []
    let ignoredInternalOwners: Set<String> = [
        "Dock", "Window Server", "SystemUIServer", "Control Center",
        "Notification Center", "Spotlight", "TextInputMenuAgent", "AutoFill"
    ]
    
    for win in windowList {
        let owner = win[kCGWindowOwnerName as String] as? String ?? ""
        let rawName = win[kCGWindowName as String] as? String ?? ""
        let name = rawName.isEmpty ? owner : rawName
        let wid = win[kCGWindowNumber as String] as? Int ?? 0
        let pid = win[kCGWindowOwnerPID as String] as? pid_t ?? 0
        let layer = win[kCGWindowLayer as String] as? Int ?? -1
        let isOnScreen = win[kCGWindowIsOnscreen as String] as? Bool ?? true
        let boundsDict = win[kCGWindowBounds as String] as? [String: Any] ?? [:]
        
        let width = boundsDict["Width"] as? Double ?? 0
        let height = boundsDict["Height"] as? Double ?? 0
        let x = boundsDict["X"] as? Double ?? 0
        let y = boundsDict["Y"] as? Double ?? 0
        
        if layer == 0 {
            if !includeAll {
                // Must be on screen
                if !isOnScreen { continue }
                // Filter out system background clutter
                if ignoredInternalOwners.contains(owner) { continue }
                // Only include regular user applications
                if let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy != .regular {
                    continue
                }
                // Filter out tiny popovers and status items
                if width < 120 || height < 80 { continue }
            } else {
                if width < minSize || height < minSize { continue }
            }

            if let target = targetApp, !target.isEmpty {
                if !owner.localizedCaseInsensitiveContains(target) && !name.localizedCaseInsensitiveContains(target) {
                    continue
                }
            }
            results.append([
                "windowId": wid,
                "pid": pid,
                "appName": owner,
                "title": name,
                "isOnScreen": isOnScreen,
                "bounds": [
                    "x": x,
                    "y": y,
                    "width": width,
                    "height": height
                ]
            ])
        }
    }
    
    if let data = try? JSONSerialization.data(withJSONObject: results, options: []),
       let str = String(data: data, encoding: .utf8) {
        print(str)
    } else {
        print("[]")
    }
}

func findTargetWindowInfo(targetApp: String) -> (wid: Int, pid: pid_t, bounds: [String: Double], appName: String, title: String)? {
    let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    guard let windowList = (CGWindowListCopyWindowInfo(options, kCGNullWindowID) ?? CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID)) as? [[String: Any]] else {
        return nil
    }
    
    for win in windowList {
        let owner = win[kCGWindowOwnerName as String] as? String ?? ""
        let rawName = win[kCGWindowName as String] as? String ?? ""
        let name = rawName.isEmpty ? owner : rawName
        let wid = win[kCGWindowNumber as String] as? Int ?? 0
        let pid = win[kCGWindowOwnerPID as String] as? pid_t ?? 0
        let layer = win[kCGWindowLayer as String] as? Int ?? -1
        let boundsDict = win[kCGWindowBounds as String] as? [String: Any] ?? [:]
        let width = boundsDict["Width"] as? Double ?? 0
        let height = boundsDict["Height"] as? Double ?? 0
        let x = boundsDict["X"] as? Double ?? 0
        let y = boundsDict["Y"] as? Double ?? 0
        
        if layer == 0 && width >= 250 && height >= 250 {
            if owner.localizedCaseInsensitiveContains(targetApp) || name.localizedCaseInsensitiveContains(targetApp) {
                return (
                    wid: wid,
                    pid: pid,
                    bounds: ["x": x, "y": y, "width": width, "height": height],
                    appName: owner,
                    title: name
                )
            }
        }
    }
    
    return nil
}

func findWindow(targetApp: String) {
    if let target = findTargetWindowInfo(targetApp: targetApp) {
        printJson([
            "status": "ok",
            "windowId": target.wid,
            "pid": target.pid,
            "appName": target.appName,
            "title": target.title,
            "bounds": target.bounds
        ])
    } else {
        printJson(["error": "No window found matching \(targetApp)"])
    }
}

func getWindowBounds(windowId: Int) {
    let options = CGWindowListOption(arrayLiteral: .optionAll)
    guard let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
        printJson(["error": "Could not fetch window list"])
        return
    }
    
    for win in windowList {
        let wid = win[kCGWindowNumber as String] as? Int ?? 0
        if wid == windowId {
            let owner = win[kCGWindowOwnerName as String] as? String ?? ""
            let rawName = win[kCGWindowName as String] as? String ?? ""
            let name = rawName.isEmpty ? owner : rawName
            let pid = win[kCGWindowOwnerPID as String] as? pid_t ?? 0
            let boundsDict = win[kCGWindowBounds as String] as? [String: Any] ?? [:]
            let width = boundsDict["Width"] as? Double ?? 0
            let height = boundsDict["Height"] as? Double ?? 0
            let x = boundsDict["X"] as? Double ?? 0
            let y = boundsDict["Y"] as? Double ?? 0
            
            printJson([
                "status": "ok",
                "windowId": wid,
                "pid": pid,
                "appName": owner,
                "title": name,
                "bounds": [
                    "x": x,
                    "y": y,
                    "width": width,
                    "height": height
                ]
            ])
            return
        }
    }
    printJson(["error": "Window ID \(windowId) not found"])
}

func windowMetadata(windowId: Int) -> (pid: pid_t, bounds: CGRect, appName: String, title: String)? {
    let options = CGWindowListOption(arrayLiteral: .optionAll)
    guard let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
        return nil
    }

    for win in windowList {
        let wid = win[kCGWindowNumber as String] as? Int ?? 0
        guard wid == windowId else { continue }
        let owner = win[kCGWindowOwnerName as String] as? String ?? ""
        let rawName = win[kCGWindowName as String] as? String ?? ""
        let name = rawName.isEmpty ? owner : rawName
        let pid = win[kCGWindowOwnerPID as String] as? pid_t ?? 0
        let boundsDict = win[kCGWindowBounds as String] as? [String: Any] ?? [:]
        let width = boundsDict["Width"] as? Double ?? 0
        let height = boundsDict["Height"] as? Double ?? 0
        let x = boundsDict["X"] as? Double ?? 0
        let y = boundsDict["Y"] as? Double ?? 0
        return (
            pid: pid,
            bounds: CGRect(x: x, y: y, width: width, height: height),
            appName: owner,
            title: name
        )
    }

    return nil
}
