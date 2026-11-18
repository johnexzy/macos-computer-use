import ApplicationServices
import CUAProtocol
import Foundation

private final class NotificationContext: @unchecked Sendable {
    let wake: @Sendable (String, UInt64) -> Void
    init(_ wake: @escaping @Sendable (String, UInt64) -> Void) { self.wake = wake }
}

/// Refcon storage remains alive until its runloop source is detached on main and its observer is released.
private final class ObserverStorage: @unchecked Sendable {
    let observer: AXObserver
    let context: NotificationContext
    init(observer: AXObserver, context: NotificationContext) {
        self.observer = observer; self.context = context
    }
    func remove() {
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        // Releasing the observer also removes its runloop source (AXUIElement.h).
        // Do not perform a sequence of remote AX removals on AppKit's main runloop.
    }
}

final class AXWindowNotifications: @unchecked Sendable {
    private var storage: ObserverStorage?
    private let lock = NSLock()

    static func install(handle: SemanticObservationHandle, context: OperationContext,
                        wake: @escaping @Sendable (String, UInt64) -> Void) throws -> AXWindowNotifications? {
        guard handle.retainedWindow is NativeAXObject else { return nil }
        try context.check()
        let token = NotificationContext(wake)
        var observer: AXObserver?
        let result = AXObserverCreate(pid_t(handle.target.key.pid), { _, _, name, raw in
            guard let raw else { return }
            let context = Unmanaged<NotificationContext>.fromOpaque(raw).takeUnretainedValue()
            context.wake(name as String, UInt64(Date().timeIntervalSince1970 * 1000))
        }, &observer)
        guard result == .success, let observer else { return nil }
        let objects = handle.notificationObjects().compactMap { ($0 as? NativeAXObject)?.element }
        let names = [kAXLayoutChangedNotification, kAXValueChangedNotification, kAXTitleChangedNotification,
                     kAXMovedNotification, kAXResizedNotification, kAXUIElementDestroyedNotification]
        var registrations = 0
        for object in objects {
            for name in names {
                try context.check()
                let timeout = try context.nativeTimeoutSeconds(maximum: 0.05)
                guard AXUIElementSetMessagingTimeout(object, timeout) == .success else { continue }
                if AXObserverAddNotification(observer, object, name as CFString, Unmanaged.passUnretained(token).toOpaque()) == .success {
                    registrations += 1
                }
            }
        }
        guard registrations > 0 else { return nil }
        let storage = ObserverStorage(observer: observer, context: token)
        let install = { CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(storage.observer), .commonModes) }
        if Thread.isMainThread { install() } else { DispatchQueue.main.sync(execute: install) }
        if context.interruption != nil {
            DispatchQueue.main.async { storage.remove() }
            try context.check()
        }
        return AXWindowNotifications(storage)
    }
    private init(_ storage: ObserverStorage) { self.storage = storage }
    func close() {
        lock.lock(); let storage = self.storage; self.storage = nil; lock.unlock()
        if let storage {
            if Thread.isMainThread { storage.remove() }
            else { DispatchQueue.main.async { storage.remove() } }
        }
    }
    deinit { close() }
}
