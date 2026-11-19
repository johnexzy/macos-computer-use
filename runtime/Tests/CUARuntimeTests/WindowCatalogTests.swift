import CUAProtocol
@testable import CUARuntime
import CoreGraphics
import Darwin
import Foundation
import XCTest

private final class ProcessSnapshots: @unchecked Sendable {
    var calls = 0
    var requestedPids: [[UInt32]] = []
    var snapshots: [[UInt32: WindowProcessOwner]]
    init(_ snapshots: [[UInt32: WindowProcessOwner]]) { self.snapshots = snapshots }
    func read(_ pids: [UInt32]) -> [UInt32: WindowProcessOwner] {
        requestedPids.append(pids)
        let index = min(calls, snapshots.count - 1)
        calls += 1
        return snapshots[index]
    }
}

private struct WindowRows: @unchecked Sendable {
    let values: [[String: Any]]
    func read() -> [[String: Any]] { values }
}

private final class ResolverInputs: @unchecked Sendable {
    var generations: [UInt32: ProcessGeneration] = [:]
    var bundles: [UInt32: String] = [:]
    var reads = 0
    var requests: [[UInt32]] = []
    var time: UInt64 = 0
    var onMetadata: (@Sendable () -> Void)?
    func generation(_ pid: UInt32) -> ProcessGeneration? { reads += 1; return generations[pid] }
    func metadata(_ pids: [UInt32]) -> [UInt32: String] { requests.append(pids); onMetadata?(); return bundles }
    func now() -> UInt64 { time }
}

final class WindowCatalogTests: XCTestCase {
    private let imageA = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let imageB = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    private func row(_ windowId: UInt32, pid: UInt32 = 42, width: Double = 440, layer: Int = 0) -> [String: Any] {
        [kCGWindowNumber as String: windowId, kCGWindowOwnerPID as String: pid,
         kCGWindowLayer as String: layer, kCGWindowName as String: "Same title",
         kCGWindowOwnerName as String: "Window Fixture",
         kCGWindowBounds as String: ["X": -10.0, "Y": 20.0, "Width": width, "Height": 230.0]]
    }
    private func context() -> OperationContext { OperationContext(budgetMs: 1000) }
    private func owner(bundleId: String?, start: UInt64 = 10) -> WindowProcessOwner {
        WindowProcessOwner(generation: ProcessGeneration(startAbstime: start, executableUUID: imageA), bundleId: bundleId)
    }

    func testOneProcessMetadataSnapshotPreservesBothEquivalentSiblingRows() throws {
        let records = WindowRows(values: [row(7), row(8)])
        let snapshots = ProcessSnapshots([[42: owner(bundleId: "test.fixture")], [:]])
        let catalog = MacOSWindowCatalog(windowRecords: records.read, processOwners: snapshots.read)
        let targets = try catalog.processWindows(pid: 42, context: context())
        XCTAssertEqual(targets.map(\.key.windowId), [7, 8])
        XCTAssertEqual(targets.map(\.bundleId), ["test.fixture", "test.fixture"])
        XCTAssertEqual(snapshots.calls, 1)
        XCTAssertEqual(snapshots.requestedPids, [[42]])
        XCTAssertThrowsError(try catalog.processWindows(pid: 42, context: context())) {
            XCTAssertEqual(($0 as? NativeFailure)?.code, .nativeFailed)
        }
        XCTAssertEqual(snapshots.calls, 2)
    }

    func testExactCGAbsenceDiffersFromUnavailableProcessMetadata() throws {
        let records = WindowRows(values: [row(7)])
        let snapshots = ProcessSnapshots([[:]])
        let catalog = MacOSWindowCatalog(windowRecords: records.read, processOwners: snapshots.read)
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
        let owners: [UInt32: WindowProcessOwner] = [42: owner(bundleId: "test.fixture")]
        let catalog = MacOSWindowCatalog(windowRecords: records.read, processOwners: { _ in owners })
        XCTAssertThrowsError(try catalog.processWindows(pid: 42, context: context())) {
            XCTAssertEqual(($0 as? NativeFailure)?.code, .ambiguousTarget)
        }
    }

    func testDiscoveryUsesOneFreshProcessSnapshotPerCall() throws {
        let records = WindowRows(values: [row(7), row(8), row(9, pid: 43)])
        let snapshots = ProcessSnapshots([[42: owner(bundleId: "test.fixture")], [43: owner(bundleId: "test.other", start: 11)]])
        let catalog = MacOSWindowCatalog(windowRecords: records.read, processOwners: snapshots.read)
        XCTAssertEqual(try catalog.targets(bundleId: nil, context: context()).targets.map(\.key.windowId), [7, 8])
        XCTAssertEqual(snapshots.calls, 1)
        XCTAssertEqual(try catalog.targets(bundleId: nil, context: context()).targets.map(\.key.windowId), [9])
        XCTAssertEqual(snapshots.calls, 2)
        XCTAssertEqual(snapshots.requestedPids, [[42, 43], [42, 43]])
    }

    func testDiscoveryAndExactLookupAcceptOnlyVerifiedUnbundledOwners() throws {
        let records = WindowRows(values: [row(7), row(8, pid: 43), row(9, pid: 44)])
        let unbundled = owner(bundleId: nil, start: 11)
        let owners: [UInt32: WindowProcessOwner] = [42: owner(bundleId: "test.fixture"), 43: unbundled]
        let catalog = MacOSWindowCatalog(windowRecords: records.read, processOwners: { _ in owners })
        XCTAssertEqual(try catalog.targets(bundleId: nil, context: context()).targets.map(\.key.windowId), [7, 8])
        XCTAssertEqual(try catalog.targets(bundleId: "test.fixture", context: context()).targets.map(\.key.windowId), [7])
        let exact = try catalog.windowSnapshot(TargetKey(pid: 43, windowId: 8), context: context())
        XCTAssertEqual(exact.generation, unbundled.generation)
        XCTAssertNil(exact.target.bundleId)
        XCTAssertEqual(exact.target.ownerName, "Window Fixture")
        XCTAssertThrowsError(try catalog.window(TargetKey(pid: 44, windowId: 9), context: context())) {
            XCTAssertEqual(($0 as? NativeFailure)?.code, .nativeFailed)
        }
    }

    func testWindowProcessResolverReusesImmutableMetadataOnlyAfterFreshGenerationChecks() {
        let input = ResolverInputs()
        input.generations[42] = ProcessGeneration(startAbstime: 10, executableUUID: imageA)
        input.bundles[42] = "test.fixture"
        let resolver = WindowProcessResolver(generation: input.generation, metadata: input.metadata, now: input.now)
        XCTAssertEqual(resolver.resolve([42])[42]?.bundleId, "test.fixture")
        input.bundles = [:] // A repeated AppKit lookup would now be unavailable.
        XCTAssertEqual(resolver.resolve([42])[42]?.bundleId, "test.fixture")
        XCTAssertEqual(input.reads, 4)
        XCTAssertEqual(input.requests, [[42]])
    }

    func testPIDReuseInvalidatesPreviouslyKnownBundle() {
        let input = ResolverInputs()
        input.generations[42] = ProcessGeneration(startAbstime: 10, executableUUID: imageA)
        input.bundles[42] = "old.app"
        let resolver = WindowProcessResolver(generation: input.generation, metadata: input.metadata, now: input.now)
        XCTAssertEqual(resolver.resolve([42])[42]?.bundleId, "old.app")
        let replacement = ProcessGeneration(startAbstime: 20, executableUUID: imageA)
        input.generations[42] = replacement
        input.bundles = [:]
        let verified = resolver.resolve([42])[42]
        XCTAssertEqual(verified?.generation, replacement)
        XCTAssertNil(verified?.bundleId)
        XCTAssertEqual(input.requests, [[42], [42]])
    }

    func testChangedExecutableImageRequiresNewMetadataEvenAtSameBirthTime() {
        let input = ResolverInputs()
        input.generations[42] = ProcessGeneration(startAbstime: 10, executableUUID: imageA)
        input.bundles[42] = "old.app"
        let resolver = WindowProcessResolver(generation: input.generation, metadata: input.metadata, now: input.now)
        XCTAssertEqual(resolver.resolve([42])[42]?.bundleId, "old.app")
        input.generations[42] = ProcessGeneration(startAbstime: 10, executableUUID: imageB)
        input.bundles[42] = "new.app"
        XCTAssertEqual(resolver.resolve([42])[42]?.bundleId, "new.app")
        XCTAssertEqual(input.requests, [[42], [42]])
    }

    func testUnavailableGenerationEvictsMetadataWithoutCachedFallback() {
        let input = ResolverInputs()
        let generation = ProcessGeneration(startAbstime: 10, executableUUID: imageA)
        input.generations[42] = generation; input.bundles[42] = "old.app"
        let resolver = WindowProcessResolver(generation: input.generation, metadata: input.metadata, now: input.now)
        XCTAssertEqual(resolver.resolve([42])[42]?.bundleId, "old.app")
        input.generations = [:]
        XCTAssertNil(resolver.resolve([42])[42])
        input.generations[42] = generation; input.bundles = [:]
        let verified = resolver.resolve([42])[42]
        XCTAssertEqual(verified?.generation, generation)
        XCTAssertNil(verified?.bundleId)
        XCTAssertEqual(input.requests, [[42], [42]])
    }

    func testInitialMetadataMissIsNotCachedAndGenerationChangeDuringFillIsRejected() {
        let input = ResolverInputs()
        let initial = ProcessGeneration(startAbstime: 10, executableUUID: imageA)
        input.generations[42] = initial
        let resolver = WindowProcessResolver(generation: input.generation, metadata: input.metadata, now: input.now)
        let verified = resolver.resolve([42])[42]
        XCTAssertEqual(verified?.generation, initial)
        XCTAssertNil(verified?.bundleId)
        let replacement = ProcessGeneration(startAbstime: 20, executableUUID: imageB)
        input.onMetadata = { input.generations[42] = replacement }
        input.bundles[42] = "raced.app"
        XCTAssertNil(resolver.resolve([42])[42])
        input.onMetadata = nil; input.bundles[42] = "new.app"
        XCTAssertEqual(resolver.resolve([42])[42]?.bundleId, "new.app")
        XCTAssertEqual(input.requests, [[42], [42], [42]])
    }

    func testAbsoluteTTLAndCapacityEvictWithoutRefreshingOnCacheHits() {
        let input = ResolverInputs()
        input.generations[42] = ProcessGeneration(startAbstime: 10, executableUUID: imageA)
        input.bundles[42] = "test.fixture"
        let resolver = WindowProcessResolver(generation: input.generation, metadata: input.metadata, now: input.now, capacity: 2)
        XCTAssertEqual(resolver.resolve([42])[42]?.bundleId, "test.fixture")
        input.time = 30_000_000_000; input.bundles = [:]
        XCTAssertEqual(resolver.resolve([42])[42]?.bundleId, "test.fixture")
        input.time = 60_000_000_000
        XCTAssertNil(resolver.resolve([42])[42]?.bundleId)
        input.bundles = [42: "test.fixture", 43: "sibling.app", 44: "third.app"]
        input.generations[43] = ProcessGeneration(startAbstime: 11, executableUUID: imageA)
        input.generations[44] = ProcessGeneration(startAbstime: 12, executableUUID: imageA)
        XCTAssertEqual(resolver.resolve([42, 43]).count, 2)
        XCTAssertEqual(resolver.resolve([44])[44]?.bundleId, "third.app")
        input.bundles = [:]
        XCTAssertNil(resolver.resolve([42])[42]?.bundleId)
    }

    func testCachedMetadataExpiringDuringAnotherProcessLookupIsNotReturnedOrRetried() {
        let input = ResolverInputs()
        input.generations[42] = ProcessGeneration(startAbstime: 10, executableUUID: imageA)
        input.generations[43] = ProcessGeneration(startAbstime: 11, executableUUID: imageA)
        input.bundles[42] = "test.fixture"
        let resolver = WindowProcessResolver(generation: input.generation, metadata: input.metadata, now: input.now)
        XCTAssertEqual(resolver.resolve([42])[42]?.bundleId, "test.fixture")
        input.time = 59_000_000_000; input.bundles = [43: "other.app"]
        input.onMetadata = { input.time = 61_000_000_000 }
        let resolved = resolver.resolve([42, 43])
        XCTAssertNil(resolved[42])
        XCTAssertEqual(resolved[43]?.bundleId, "other.app")
        XCTAssertEqual(input.requests, [[42], [43]])
        input.onMetadata = nil; input.bundles = [:]
        XCTAssertNil(resolver.resolve([42])[42]?.bundleId)
        XCTAssertEqual(input.requests, [[42], [43], [42]])
    }

    func testNativeProcessSignatureRequiresSuccessfulLiveBirthAndNonzeroImageUUID() {
        var info = rusage_info_v0()
        info.ri_proc_start_abstime = 10
        XCTAssertNil(ProcessGeneration.live(info, status: 0))
        info.ri_uuid = imageA.uuid
        XCTAssertEqual(ProcessGeneration.live(info, status: 0), ProcessGeneration(startAbstime: 10, executableUUID: imageA))
        XCTAssertNil(ProcessGeneration.live(info, status: -1))
        info.ri_proc_exit_abstime = 20
        XCTAssertNil(ProcessGeneration.live(info, status: 0))
        info.ri_proc_exit_abstime = 0; info.ri_proc_start_abstime = 0
        XCTAssertNil(ProcessGeneration.live(info, status: 0))
    }
}
