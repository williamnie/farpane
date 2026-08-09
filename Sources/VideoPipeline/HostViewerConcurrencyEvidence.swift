import CryptoKit
import Darwin
import Dispatch
import Foundation

public enum HostViewerConcurrencyEvidenceError: Error, Equatable {
  case outputPathMustBeAbsolute
  case outputMustBeJSONLines
  case outputParentMustExist
  case outputPathIsUnsafe
  case outputAlreadyExists
  case invalidProcessIdentity
  case invalidEvent
  case invalidTiming
  case invalidLifecycle
  case recordCapacityExceeded
}

public enum HostViewerConcurrencyProcessRole: String, Codable, Sendable {
  case application
  case hostAgent
}

public struct HostViewerConcurrencyProcessIdentity: Equatable, Sendable {
  public let role: HostViewerConcurrencyProcessRole
  public let processID: Int32
  public let processStartIdentitySHA256: String
  public let buildIdentitySHA256: String
  public let scenarioCorrelationSHA256: String

  public init(
    role: HostViewerConcurrencyProcessRole,
    processID: Int32,
    processStartIdentitySHA256: String,
    buildIdentitySHA256: String,
    scenarioCorrelationSHA256: String
  ) {
    self.role = role
    self.processID = processID
    self.processStartIdentitySHA256 = processStartIdentitySHA256
    self.buildIdentitySHA256 = buildIdentitySHA256
    self.scenarioCorrelationSHA256 = scenarioCorrelationSHA256
  }
}

public enum HostViewerConcurrencyHostState: String, Codable, Sendable {
  case readyZeroInbound
  case inboundMediaActive
  case disconnected
  case recoveredReadyZeroInbound
  case recoveredInboundMediaActive
}

public struct HostViewerConcurrencyHostObservation: Equatable, Sendable {
  public let state: HostViewerConcurrencyHostState
  public let hostInstanceScopeSHA256: String
  public let agentBootID: UUID
  public let configRevision: UInt64
  public let hostAgentProcessID: Int32
  public let hostAgentProcessStartIdentitySHA256: String
  public let hostAgentBuildIdentitySHA256: String
  public let transitionGeneration: UInt64

  public init(
    state: HostViewerConcurrencyHostState,
    hostInstanceScopeSHA256: String,
    agentBootID: UUID,
    configRevision: UInt64,
    hostAgentProcessID: Int32,
    hostAgentProcessStartIdentitySHA256: String,
    hostAgentBuildIdentitySHA256: String,
    transitionGeneration: UInt64
  ) {
    self.state = state
    self.hostInstanceScopeSHA256 = hostInstanceScopeSHA256
    self.agentBootID = agentBootID
    self.configRevision = configRevision
    self.hostAgentProcessID = hostAgentProcessID
    self.hostAgentProcessStartIdentitySHA256 =
      hostAgentProcessStartIdentitySHA256
    self.hostAgentBuildIdentitySHA256 = hostAgentBuildIdentitySHA256
    self.transitionGeneration = transitionGeneration
  }
}

public enum HostViewerConcurrencyViewerState: String, Codable, Sendable {
  case starting
  case authenticatedStreaming
  case stopped
  case disconnected
  case recoveredStreaming
}

public struct HostViewerConcurrencyViewerObservation: Equatable, Sendable {
  public let state: HostViewerConcurrencyViewerState
  public let sessionEpoch: UInt64
  public let transitionGeneration: UInt64

  public init(
    state: HostViewerConcurrencyViewerState,
    sessionEpoch: UInt64,
    transitionGeneration: UInt64
  ) {
    self.state = state
    self.sessionEpoch = sessionEpoch
    self.transitionGeneration = transitionGeneration
  }
}

public enum HostViewerConcurrencyLifecycleEvent: Equatable, Sendable {
  case processStarted
  case processTerminating
  case host(HostViewerConcurrencyHostObservation)
  case viewer(HostViewerConcurrencyViewerObservation)
}

/// Derives domain-separated digests before any raw identity reaches evidence.
public enum HostViewerConcurrencyEvidenceDigest {
  private static let maximumRawIdentityUTF8Bytes = 512

  public static func processStartIdentity(_ rawIdentity: String) -> String? {
    digest(
      domain: "farpane.v1-concurrency.process-start.v1",
      rawIdentity: rawIdentity
    )
  }

  public static func buildIdentity(_ rawIdentity: String) -> String? {
    digest(
      domain: "farpane.v1-concurrency.build.v1",
      rawIdentity: rawIdentity
    )
  }

  public static func hostInstanceScope(_ rawIdentity: String) -> String? {
    digest(
      domain: "farpane.v1-concurrency.host-scope.v1",
      rawIdentity: rawIdentity
    )
  }

  public static func scenarioCorrelation(_ rawIdentity: String) -> String? {
    digest(
      domain: "farpane.v1-concurrency.scenario.v1",
      rawIdentity: rawIdentity
    )
  }

  private static func digest(
    domain: String,
    rawIdentity: String
  ) -> String? {
    let bytes = rawIdentity.utf8
    guard !bytes.isEmpty,
          bytes.count <= maximumRawIdentityUTF8Bytes,
          bytes.allSatisfy({ $0 >= 0x20 && $0 != 0x7F })
    else { return nil }

    var hasher = SHA256()
    hasher.update(data: Data(domain.utf8))
    hasher.update(data: Data([0]))
    hasher.update(data: Data(bytes))
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }
}

/// A process-scoped, default-off writer for the five V1 coexistence cases.
///
/// App and HostAgent deliberately write separate files. Each file has one
/// process identity, one scenario correlation digest, a contiguous sequence,
/// and a terminal lifecycle. A later validator correlates files with the
/// machine-wide boot-monotonic clock; this writer never performs inference.
public final class HostViewerConcurrencyEvidenceWriter:
  @unchecked Sendable
{
  public static let outputEnvironmentKey =
    "FARPANE_HOST_VIEWER_CONCURRENCY_OUTPUT"
  public static let maximumRecordCount: UInt64 = 512

  private enum LifecycleState {
    case initial
    case running
    case terminated
  }

  private enum EncodedEvent: Encodable {
    case processStarted
    case processTerminating
    case host(HostViewerConcurrencyHostObservation)
    case viewer(HostViewerConcurrencyViewerObservation)

    private enum CodingKeys: String, CodingKey {
      case kind, state, hostInstanceScopeSHA256, agentBootID
      case configRevision, hostAgentProcessID
      case hostAgentProcessStartIdentitySHA256
      case hostAgentBuildIdentitySHA256, transitionGeneration
      case sessionEpoch
    }

    func encode(to encoder: Encoder) throws {
      var container = encoder.container(keyedBy: CodingKeys.self)
      switch self {
      case .processStarted:
        try container.encode("processStarted", forKey: .kind)
      case .processTerminating:
        try container.encode("processTerminating", forKey: .kind)
      case .host(let observation):
        try container.encode("hostState", forKey: .kind)
        try container.encode(observation.state, forKey: .state)
        try container.encode(
          observation.hostInstanceScopeSHA256,
          forKey: .hostInstanceScopeSHA256
        )
        try container.encode(
          observation.agentBootID.uuidString.lowercased(),
          forKey: .agentBootID
        )
        try container.encode(
          observation.configRevision,
          forKey: .configRevision
        )
        try container.encode(
          observation.hostAgentProcessID,
          forKey: .hostAgentProcessID
        )
        try container.encode(
          observation.hostAgentProcessStartIdentitySHA256,
          forKey: .hostAgentProcessStartIdentitySHA256
        )
        try container.encode(
          observation.hostAgentBuildIdentitySHA256,
          forKey: .hostAgentBuildIdentitySHA256
        )
        try container.encode(
          observation.transitionGeneration,
          forKey: .transitionGeneration
        )
      case .viewer(let observation):
        try container.encode("viewerState", forKey: .kind)
        try container.encode(observation.state, forKey: .state)
        try container.encode(observation.sessionEpoch, forKey: .sessionEpoch)
        try container.encode(
          observation.transitionGeneration,
          forKey: .transitionGeneration
        )
      }
    }
  }

  private struct Record: Encodable {
    let schema = "farpane-host-viewer-concurrency-lifecycle"
    let schemaVersion = 1
    let sequence: UInt64
    let capturedAt: Date
    let monotonicNanoseconds: UInt64
    let observerProcessRole: HostViewerConcurrencyProcessRole
    let observerProcessID: Int32
    let observerProcessStartIdentitySHA256: String
    let observerBuildIdentitySHA256: String
    let scenarioCorrelationSHA256: String
    let event: EncodedEvent
  }

  private let outputHandle: FileHandle
  private let identity: HostViewerConcurrencyProcessIdentity
  var identitySnapshot: HostViewerConcurrencyProcessIdentity { identity }
  private let lock = NSLock()
  private var lifecycleState: LifecycleState = .initial
  private var sequence: UInt64 = 0
  private var lastCapturedAt: Date?
  private var lastMonotonicNanoseconds: UInt64?

  public init(
    outputURL: URL,
    identity: HostViewerConcurrencyProcessIdentity,
    fileManager: FileManager = .default
  ) throws {
    guard Self.valid(identity) else {
      throw HostViewerConcurrencyEvidenceError.invalidProcessIdentity
    }
    guard outputURL.isFileURL,
          NSString(string: outputURL.path).isAbsolutePath
    else {
      throw HostViewerConcurrencyEvidenceError.outputPathMustBeAbsolute
    }
    guard outputURL.pathExtension.lowercased() == "jsonl" else {
      throw HostViewerConcurrencyEvidenceError.outputMustBeJSONLines
    }
    guard let pathComponents = Self.safeAbsolutePathComponents(
      outputURL.path
    ) else {
      throw HostViewerConcurrencyEvidenceError.outputPathIsUnsafe
    }
    let outputPath = outputURL.path
    let parentPath = "/" + pathComponents.dropLast().joined(separator: "/")
    guard !Self.hasSymlinkComponent(
      pathComponents,
      fileManager: fileManager
    ) else {
      throw HostViewerConcurrencyEvidenceError.outputPathIsUnsafe
    }
    guard Self.isDirectory(parentPath, fileManager: fileManager) else {
      throw HostViewerConcurrencyEvidenceError.outputParentMustExist
    }
    guard !Self.pathExists(outputPath, fileManager: fileManager) else {
      throw HostViewerConcurrencyEvidenceError.outputAlreadyExists
    }
    guard Self.isTrustedParent(parentPath, fileManager: fileManager) else {
      throw HostViewerConcurrencyEvidenceError.outputPathIsUnsafe
    }
    let output = URL(fileURLWithPath: outputPath, isDirectory: false)

    do {
      try Data().write(to: output, options: .withoutOverwriting)
    } catch let error as CocoaError where error.code == .fileWriteFileExists {
      throw HostViewerConcurrencyEvidenceError.outputAlreadyExists
    }

    do {
      try fileManager.setAttributes(
        [.posixPermissions: NSNumber(value: Int16(0o600))],
        ofItemAtPath: outputPath
      )
      guard Self.isTrustedOutput(
        outputPath,
        fileManager: fileManager
      ) else {
        throw HostViewerConcurrencyEvidenceError.outputPathIsUnsafe
      }
      outputHandle = try FileHandle(forWritingTo: output)
    } catch {
      try? fileManager.removeItem(atPath: outputPath)
      throw error
    }
    self.identity = identity
  }

  deinit {
    try? outputHandle.close()
  }

  public static func configured(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    identity: HostViewerConcurrencyProcessIdentity,
    fileManager: FileManager = .default
  ) throws -> HostViewerConcurrencyEvidenceWriter? {
    guard let path = environment[outputEnvironmentKey] else { return nil }
    guard !path.isEmpty,
          NSString(string: path).isAbsolutePath
    else {
      throw HostViewerConcurrencyEvidenceError.outputPathMustBeAbsolute
    }
    return try HostViewerConcurrencyEvidenceWriter(
      outputURL: URL(fileURLWithPath: path, isDirectory: false),
      identity: identity,
      fileManager: fileManager
    )
  }

  @discardableResult
  public func record(
    _ event: HostViewerConcurrencyLifecycleEvent,
    capturedAt: Date? = nil,
    monotonicNanoseconds: UInt64? = nil
  ) throws -> UInt64 {
    guard Self.valid(event, for: identity) else {
      throw HostViewerConcurrencyEvidenceError.invalidEvent
    }

    return try lock.withLock {
      let capturedAt = capturedAt ?? Date()
      let monotonicNanoseconds = monotonicNanoseconds
        ?? DispatchTime.now().uptimeNanoseconds
      guard capturedAt.timeIntervalSince1970.isFinite,
            capturedAt.timeIntervalSince1970 >= 0,
            monotonicNanoseconds > 0
      else {
        throw HostViewerConcurrencyEvidenceError.invalidTiming
      }
      guard sequence < Self.maximumRecordCount else {
        throw HostViewerConcurrencyEvidenceError.recordCapacityExceeded
      }
      if let lastCapturedAt, capturedAt < lastCapturedAt {
        throw HostViewerConcurrencyEvidenceError.invalidTiming
      }
      if let lastMonotonicNanoseconds,
         monotonicNanoseconds <= lastMonotonicNanoseconds {
        throw HostViewerConcurrencyEvidenceError.invalidTiming
      }
      let nextLifecycle = try lifecycle(after: event)
      let nextSequence = sequence + 1
      let record = Record(
        sequence: nextSequence,
        capturedAt: capturedAt,
        monotonicNanoseconds: monotonicNanoseconds,
        observerProcessRole: identity.role,
        observerProcessID: identity.processID,
        observerProcessStartIdentitySHA256:
          identity.processStartIdentitySHA256,
        observerBuildIdentitySHA256: identity.buildIdentitySHA256,
        scenarioCorrelationSHA256: identity.scenarioCorrelationSHA256,
        event: Self.encoded(event)
      )
      let encoder = JSONEncoder()
      encoder.dateEncodingStrategy = .iso8601
      encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
      var line = try encoder.encode(record)
      line.append(0x0A)
      try outputHandle.seekToEnd()
      try outputHandle.write(contentsOf: line)
      try outputHandle.synchronize()
      sequence = nextSequence
      lifecycleState = nextLifecycle
      lastCapturedAt = capturedAt
      lastMonotonicNanoseconds = monotonicNanoseconds
      return nextSequence
    }
  }

  private func lifecycle(
    after event: HostViewerConcurrencyLifecycleEvent
  ) throws -> LifecycleState {
    switch (lifecycleState, event) {
    case (.initial, .processStarted):
      return .running
    case (.running, .processTerminating):
      return .terminated
    case (.running, .host), (.running, .viewer):
      return .running
    case (.initial, _), (.running, .processStarted), (.terminated, _):
      throw HostViewerConcurrencyEvidenceError.invalidLifecycle
    }
  }

  private static func encoded(
    _ event: HostViewerConcurrencyLifecycleEvent
  ) -> EncodedEvent {
    switch event {
    case .processStarted:
      return .processStarted
    case .processTerminating:
      return .processTerminating
    case .host(let observation):
      return .host(observation)
    case .viewer(let observation):
      return .viewer(observation)
    }
  }

  private static func valid(
    _ identity: HostViewerConcurrencyProcessIdentity
  ) -> Bool {
    identity.processID > 1
      && isLowercaseSHA256(identity.processStartIdentitySHA256)
      && isLowercaseSHA256(identity.buildIdentitySHA256)
      && isLowercaseSHA256(identity.scenarioCorrelationSHA256)
  }

  private static func valid(
    _ event: HostViewerConcurrencyLifecycleEvent,
    for identity: HostViewerConcurrencyProcessIdentity
  ) -> Bool {
    switch event {
    case .processStarted, .processTerminating:
      return true
    case .viewer(let observation):
      guard identity.role == .application,
            observation.sessionEpoch > 0
      else { return false }
      switch observation.state {
      case .starting, .authenticatedStreaming, .stopped:
        return observation.transitionGeneration == 0
      case .disconnected, .recoveredStreaming:
        return observation.transitionGeneration > 0
      }
    case .host(let observation):
      guard observation.configRevision > 0,
            observation.hostAgentProcessID > 1,
            observation.agentBootID.uuidString
              != "00000000-0000-0000-0000-000000000000",
            isLowercaseSHA256(observation.hostInstanceScopeSHA256),
            isLowercaseSHA256(
              observation.hostAgentProcessStartIdentitySHA256
            ),
            isLowercaseSHA256(observation.hostAgentBuildIdentitySHA256)
      else { return false }
      if identity.role == .hostAgent {
        guard observation.hostAgentProcessID == identity.processID,
              observation.hostAgentProcessStartIdentitySHA256
                == identity.processStartIdentitySHA256,
              observation.hostAgentBuildIdentitySHA256
                == identity.buildIdentitySHA256
        else { return false }
      }
      switch observation.state {
      case .readyZeroInbound, .inboundMediaActive:
        return observation.transitionGeneration == 0
      case .disconnected, .recoveredReadyZeroInbound,
           .recoveredInboundMediaActive:
        return observation.transitionGeneration > 0
      }
    }
  }

  private static func isLowercaseSHA256(_ value: String) -> Bool {
    value.count == 64
      && value.utf8.allSatisfy {
        ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66)
      }
  }

  private static func safeAbsolutePathComponents(
    _ path: String
  ) -> [String]? {
    guard path.hasPrefix("/"), !path.hasSuffix("/") else { return nil }
    let rawComponents = path.split(
      separator: "/",
      omittingEmptySubsequences: false
    )
    guard rawComponents.first?.isEmpty == true else { return nil }
    let components = rawComponents.dropFirst().map(String.init)
    guard !components.isEmpty,
          components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
    else { return nil }
    return components
  }

  private static func hasSymlinkComponent(
    _ components: [String],
    fileManager: FileManager
  ) -> Bool {
    var current = "/"
    for component in components.dropLast() {
      current = NSString(string: current).appendingPathComponent(component)
      guard let attributes = try? fileManager.attributesOfItem(
        atPath: current
      ) else { return false }
      if attributes[.type] as? FileAttributeType == .typeSymbolicLink {
        return true
      }
    }
    return false
  }

  private static func isDirectory(
    _ path: String,
    fileManager: FileManager
  ) -> Bool {
    guard let attributes = try? fileManager.attributesOfItem(
      atPath: path
    ) else { return false }
    return attributes[.type] as? FileAttributeType == .typeDirectory
  }

  private static func isTrustedParent(
    _ path: String,
    fileManager: FileManager
  ) -> Bool {
    guard let attributes = try? fileManager.attributesOfItem(
      atPath: path
    ), let owner = attributes[.ownerAccountID] as? NSNumber,
      let permissions = attributes[.posixPermissions] as? NSNumber
    else { return false }
    return owner.uint32Value == geteuid()
      && permissions.uint16Value & 0o022 == 0
  }

  private static func isTrustedOutput(
    _ path: String,
    fileManager: FileManager
  ) -> Bool {
    guard let attributes = try? fileManager.attributesOfItem(
      atPath: path
    ), attributes[.type] as? FileAttributeType == .typeRegular,
      let owner = attributes[.ownerAccountID] as? NSNumber,
      let permissions = attributes[.posixPermissions] as? NSNumber,
      let links = attributes[.referenceCount] as? NSNumber
    else { return false }
    return owner.uint32Value == geteuid()
      && permissions.uint16Value == 0o600
      && links.uint64Value == 1
  }

  private static func pathExists(
    _ path: String,
    fileManager: FileManager
  ) -> Bool {
    (try? fileManager.attributesOfItem(atPath: path)) != nil
      || fileManager.fileExists(atPath: path)
  }
}

private extension NSLock {
  func withLock<T>(_ body: () throws -> T) rethrows -> T {
    lock()
    defer { unlock() }
    return try body()
  }
}
