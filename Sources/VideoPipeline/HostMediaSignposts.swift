import Foundation
import os.signpost

public enum HostMediaStage: String, CaseIterable, Sendable {
  case capture
  case encodeSubmit
  case encodeRejected
  case packetReady
  case sendSubmit
  case sendAccepted
  case sendDropped
}

public protocol HostMediaStageRecording: Sendable {
  func record(
    _ stage: HostMediaStage,
    presentationTimeUS: UInt64,
    byteCount: Int
  )
}

/// Sanitized Instruments events for the in-process Host media path. PTS and
/// compressed byte count are sufficient to correlate stages without exposing
/// pixels, encoded payloads, peer identifiers, server configuration or keys.
public final class HostMediaSignpostRecorder: HostMediaStageRecording, @unchecked Sendable {
  public static let shared = HostMediaSignpostRecorder()

  private let log = OSLog(subsystem: "io.farpane", category: "HostMedia")

  public init() {}

  public func record(
    _ stage: HostMediaStage,
    presentationTimeUS: UInt64,
    byteCount: Int
  ) {
    let bytes = UInt64(max(0, byteCount))
    switch stage {
    case .capture:
      emit(name: "capture", presentationTimeUS: presentationTimeUS, bytes: bytes)
    case .encodeSubmit:
      emit(name: "encode-submit", presentationTimeUS: presentationTimeUS, bytes: bytes)
    case .encodeRejected:
      emit(name: "encode-rejected", presentationTimeUS: presentationTimeUS, bytes: bytes)
    case .packetReady:
      emit(name: "packet-ready", presentationTimeUS: presentationTimeUS, bytes: bytes)
    case .sendSubmit:
      emit(name: "send-submit", presentationTimeUS: presentationTimeUS, bytes: bytes)
    case .sendAccepted:
      emit(name: "send-accepted", presentationTimeUS: presentationTimeUS, bytes: bytes)
    case .sendDropped:
      emit(name: "send-dropped", presentationTimeUS: presentationTimeUS, bytes: bytes)
    }
  }

  private func emit(
    name: StaticString,
    presentationTimeUS: UInt64,
    bytes: UInt64
  ) {
    os_signpost(
      .event,
      log: log,
      name: name,
      "pts_us=%{public}llu bytes=%{public}llu",
      presentationTimeUS,
      bytes
    )
  }
}
