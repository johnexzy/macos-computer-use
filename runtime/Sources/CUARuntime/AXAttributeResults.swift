import ApplicationServices
import CUAProtocol
import Foundation

func checkAXRead(_ result: AXError, context: OperationContext, allowMissing: Bool = false) throws {
    try context.check()
    if result == .success { return }
    if allowMissing && (result == .attributeUnsupported || result == .noValue || result == .actionUnsupported) { return }
    if result == .invalidUIElement { throw NativeFailure(.staleElement, "AX object is invalid") }
    if result == .apiDisabled { throw NativeFailure(.permissionDenied, "Accessibility permission is unavailable") }
    throw NativeFailure(.nativeFailed, "AX read failed")
}

func decodeAXEnabled(_ result: AXError, value: CFTypeRef?, context: OperationContext) throws -> (value: Bool?, unsupported: Bool) {
    try checkAXRead(result, context: context, allowMissing: true)
    return (result == .success ? value as? Bool : nil, result == .attributeUnsupported)
}

func decodeAXDescription(_ result: AXError, value: CFTypeRef?, context: OperationContext) throws -> (value: String?, complete: Bool) {
    // TextEdit exposes a writable text area whose optional AXDescription returns kAXErrorFailure.
    // Keep that node, but disclose the missing metadata. Other native errors retain their meaning.
    if result == .failure { try context.check(); return (nil, false) }
    try checkAXRead(result, context: context, allowMissing: true)
    if result == .success {
        let text = value as? String
        return (text, text != nil)
    }
    return (nil, true)
}

func isWritableAXTextRole(_ role: String) -> Bool { role == kAXTextFieldRole as String || role == kAXTextAreaRole as String }
