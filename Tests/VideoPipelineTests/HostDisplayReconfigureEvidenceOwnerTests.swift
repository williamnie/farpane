@testable import VideoPipeline
import Foundation
import XCTest

final class HostDisplayReconfigureEvidenceOwnerTests: XCTestCase {
  func testExactMarkerControlsAndRouteConvergenceWriteEvidence() throws {
    let fixture = makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let clock = DisplayEvidenceClock()
    let processOwner = HostRecoveryTransitionEvidenceProcessOwner(
      wallClock: clock.wall,
      monotonicNanoseconds: clock.monotonic
    )
    XCTAssertTrue(processOwner.configure(
      hostInstanceID: "host",
      buildIdentity: "build",
      environment: [
        HostRecoveryTransitionEvidenceWriter.outputEnvironmentKey:
          fixture.output.path,
      ]
    ))
    let expectedRoute = route()
    let owner = HostDisplayReconfigureEvidenceOwner(
      evidenceOwner: processOwner,
      routePoll: { route in
        route == expectedRoute ? .converged : .failed
      }
    )
    let marker = marker()
    let start = HostDisplayReconfigureEvidenceStart(
      marker: marker,
      connectionEpoch: expectedRoute.connectionEpoch,
      codecEpoch: expectedRoute.codecEpoch,
      displayID: expectedRoute.displayID,
      displayRevision: expectedRoute.displayRevision
    )
    let candidate = HostDisplayReconfigureEvidenceCandidate(
      marker: marker,
      replacementRoute: expectedRoute
    )

    XCTAssertTrue(owner.accept(marker))
    XCTAssertTrue(owner.observeStart(start))
    XCTAssertTrue(owner.observeReconfigure(candidate, routeAccepted: true))
    XCTAssertTrue(waitUntil {
      owner.snapshot() == .completed(generation: 4, outcome: .converged)
    })

    let records = try String(contentsOf: fixture.output, encoding: .utf8)
      .split(separator: "\n")
    XCTAssertEqual(records.count, 1)
    let document = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(try XCTUnwrap(records.first).utf8))
        as? [String: Any]
    )
    XCTAssertEqual(document["kind"] as? String, "displayReconfigure")
    XCTAssertEqual(processOwner.snapshot().completedRecords, 1)
  }

  func testGenericOrMismatchedReplacementNeverWritesDisplayEvidence() throws {
    let fixture = makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let processOwner = HostRecoveryTransitionEvidenceProcessOwner(
      wallClock: { Date(timeIntervalSince1970: 10) },
      monotonicNanoseconds: { 100 }
    )
    XCTAssertTrue(processOwner.configure(
      hostInstanceID: "host",
      buildIdentity: "build",
      environment: [
        HostRecoveryTransitionEvidenceWriter.outputEnvironmentKey:
          fixture.output.path,
      ]
    ))
    let owner = HostDisplayReconfigureEvidenceOwner(
      evidenceOwner: processOwner,
      routePoll: { _ in .converged }
    )

    XCTAssertTrue(owner.observeStart(nil))
    XCTAssertTrue(owner.observeReconfigure(nil, routeAccepted: true))
    XCTAssertTrue(owner.accept(marker()))
    XCTAssertFalse(owner.observeStart(nil))
    XCTAssertEqual(
      owner.snapshot(),
      .completed(generation: 4, outcome: .rejected)
    )
    XCTAssertEqual(try Data(contentsOf: fixture.output).count, 0)
    XCTAssertEqual(processOwner.snapshot().completedRecords, 0)
  }

  private func marker() -> HostDisplayReconfigureEvidenceMarker {
    .init(
      generation: 4,
      displayID: 0,
      previousDisplayRevision: 2,
      previousConnectionEpoch: 11,
      previousCodecEpoch: 21
    )
  }

  private func route() -> HostMediaPipelineRouteIdentity {
    .init(
      connectionEpoch: 12,
      codecEpoch: 22,
      displayID: 0,
      displayRevision: 3,
      codec: .h264
    )
  }

  private func waitUntil(
    timeout: TimeInterval = 1,
    _ predicate: () -> Bool
  ) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if predicate() { return true }
      Thread.sleep(forTimeInterval: 0.01)
    }
    return predicate()
  }

  private func makeFixture() -> (directory: URL, output: URL) {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "farpane-display-reconfigure-evidence-owner-tests",
        isDirectory: true
      )
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    return (directory, directory.appendingPathComponent("recovery.jsonl"))
  }
}

private final class DisplayEvidenceClock: @unchecked Sendable {
  private let lock = NSLock()
  private var wallSeconds: TimeInterval = 10
  private var monotonicValue: UInt64 = 100

  var wall: @Sendable () -> Date {
    { [self] in
      lock.lock()
      defer { lock.unlock() }
      defer { wallSeconds += 10 }
      return Date(timeIntervalSince1970: wallSeconds)
    }
  }

  var monotonic: @Sendable () -> UInt64 {
    { [self] in
      lock.lock()
      defer { lock.unlock() }
      defer { monotonicValue += 100 }
      return monotonicValue
    }
  }
}
