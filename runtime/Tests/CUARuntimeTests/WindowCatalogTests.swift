import CUAProtocol
@testable import CUARuntime
import CoreGraphics
import Foundation
import XCTest

private final class ProcessSnapshots: @unchecked Sendable {
    var calls = 0
    var snapshots: [[UInt32: String]]
    init(_ snapshots: [[UInt32: String]]) { self.snapshots = snapshots }
    func read() -> [UInt32: String] {
        let index = min(calls, snapshots.count - 1)
        calls += 1
        return snapshots[index]
    }
}

private struct WindowRows: @unchecked Sendable {
    let values: [[String: Any]]
    func read() -> [[String: Any]] { values }
}

final class WindowCatalogTests: XCTestCase {
    private func row(_ windowId: UInt32, pid: UInt32 = 42, width: Double = 440, layer: Int = 0) -> [String: Any] {
        [kCGWindowNumber as String: windowId, kCGWindowOwnerPID as String: pid,
         kCGWindowLayer as String: layer, kCGWindowName as String: "Same title",
         kCGWindowBounds as String: ["X": -10.0, "Y": 20.0, "Width": width, "Height": 230.0]]
    }
    private func context() -> OperationContext { OperationContext(budgetMs: 1000) }

    func testOneProcessMetadataSnapshotPreservesBothEquivalentSiblingRows() throws {
        let records = WindowRows(values: [row(7), row(8)])
        let snapshots = ProcessSnapshots([[42: "test.fixture"], [:]])
        let catalog = MacOSWindowCatalog(windowRecords: records.read, processBundles: snapshots.read)
        let targets = try catalog.processWindows(pid: 42, context: context())
        XCTAssertEqual(targets.map(\.key.windowId), [7, 8])
        XCTAssertEqual(targets.map(\.bundleId), ["test.fixture", "test.fixture"])
        XCTAssertEqual(snapshots.calls, 1)
        XCTAssertThrowsError(try catalog.processWindows(pid: 42, context: context())) {
            XCTAssertEqual(($0 as? NativeFailure)?.code, .nativeFailed)
        }
        XCTAssertEqual(snapshots.calls, 2)
    }

    func testExactCGAbsenceDiffersFromUnavailableProcessMetadata() throws {
        let records = WindowRows(values: [row(7)])
        let snapshots = ProcessSnapshots([[:]])
        let catalog = MacOSWindowCatalog(windowRecords: records.read, processBundles: snapshots.read)
        XCTAssertThrowsError(try catalog.window(TargetKey(pid: 42, windowId: 7), context: context())) {
            XCTAssertEqual(($0 as? NativeFailure)?.code, .nativeFailed)
        }
        XCTAssertThrowsError(try catalog.window(TargetKey(pid: 42, windowId: 8), context: context())) {
            XCTAssertEqual(($0 as? NativeFailure)?.code, .targetNotFound)
        }
        XCTAssertEqual(snapshots.calls, 2)
    }

    func testInvalidOwnedSiblingMetadataRejectsIncompleteAssociationCatalog() throws {
        let records = WindowRows(values: [row(7), row(8, width: 0)])
        let catalog = MacOSWindowCatalog(windowRecords: records.read, processBundles: { [42: "test.fixture"] })
        XCTAssertThrowsError(try catalog.processWindows(pid: 42, context: context())) {
            XCTAssertEqual(($0 as? NativeFailure)?.code, .ambiguousTarget)
        }
    }

    func testDiscoveryUsesOneFreshProcessSnapshotPerCall() throws {
        let records = WindowRows(values: [row(7), row(8), row(9, pid: 43)])
        let snapshots = ProcessSnapshots([[42: "test.fixture"], [43: "test.other"]])
        let catalog = MacOSWindowCatalog(windowRecords: records.read, processBundles: snapshots.read)
        XCTAssertEqual(try catalog.targets(bundleId: nil, context: context()).targets.map(\.key.windowId), [7, 8])
        XCTAssertEqual(snapshots.calls, 1)
        XCTAssertEqual(try catalog.targets(bundleId: nil, context: context()).targets.map(\.key.windowId), [9])
        XCTAssertEqual(snapshots.calls, 2)
    }
}
