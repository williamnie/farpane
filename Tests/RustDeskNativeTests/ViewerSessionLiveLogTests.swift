import CoreBridge
import Foundation
import VideoPipeline
import XCTest

@testable import RustDeskNative

final class ViewerSessionLiveLogTests: XCTestCase {
    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "farpane-viewer-log-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func records(in directory: URL) throws -> [[String: Any]] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "jsonl" }.flatMap { url in
                try String(contentsOf: url).split(separator: "\n").map {
                    try XCTUnwrap(
                        JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
                }
            }.sorted { ($0["sequence"] as? Int ?? 0) < ($1["sequence"] as? Int ?? 0) }
    }

    func testStateRetryAndFinalRecordsAreOrderedAndExcludeSensitiveMetricsStrings() throws {
        let directory = try makeDirectory()
        let sentinel = "secret-peer-address-password"
        let metrics = PipelineMetrics(
            inputWidth: 0, inputHeight: 0, inputFPS: 30, selectedGPU: sentinel, source: sentinel)
        metrics.recordCoreState(sentinel)
        metrics.recordFunctionalCheck(sentinel, passed: true)
        let log = try ViewerSessionLiveLog(directory: directory, forceRelay: true)
        log.record(.sessionStarted, metrics: metrics, coreGeneration: 0)
        log.record(
            .coreStateChanged, metrics: metrics, coreGeneration: 1, state: .disconnected, code: 15)
        log.record(.reconnectAttempt, metrics: metrics, coreGeneration: 1)
        log.record(
            .coreStateChanged, metrics: metrics, coreGeneration: 2, state: .streaming, code: 0)
        log.record(.periodic, metrics: metrics, coreGeneration: 2)
        log.finish(metrics: metrics, coreGeneration: 2)
        log.finish(metrics: metrics, coreGeneration: 2)
        log.record(.periodic, metrics: metrics, coreGeneration: 2)
        let rows = try records(in: directory)
        XCTAssertEqual(rows.compactMap { $0["sequence"] as? Int }, Array(1...6))
        XCTAssertEqual(
            rows.compactMap { $0["event"] as? String },
            [
                "sessionStarted", "coreStateChanged", "reconnectAttempt", "coreStateChanged",
                "periodic", "sessionStopped",
            ])
        XCTAssertEqual(rows[2]["coreState"] as? String, "disconnected")
        XCTAssertEqual(rows[2]["stateCode"] as? Int, 15)
        XCTAssertEqual(rows[4]["coreState"] as? String, "streaming")
        XCTAssertEqual(rows[4]["stateCode"] as? Int, 0)
        XCTAssertEqual(rows[4]["forceRelay"] as? Bool, true)
        XCTAssertEqual(rows[4]["coreGeneration"] as? Int, 2)
        let encoded = try JSONSerialization.data(withJSONObject: rows)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains(sentinel))
        let expectedKeys: Set<String> = [
            "schema", "schemaVersion", "sequence", "capturedAt", "monotonicNanoseconds",
            "sessionStartedAt", "buildIdentifier", "event", "forceRelay", "coreGeneration",
            "coreState", "stateCode", "pipeline",
        ]
        for row in rows { XCTAssertEqual(Set(row.keys), expectedKeys) }
        let file = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .first)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testRotationKeepsLateSessionSamplesAndFinalEvent() throws {
        let directory = try makeDirectory()
        let metrics = PipelineMetrics(
            inputWidth: 0, inputHeight: 0, inputFPS: 30, selectedGPU: "test")
        let log = try ViewerSessionLiveLog(
            directory: directory, forceRelay: false, maximumRecordsPerFile: 2)
        log.record(.sessionStarted, metrics: metrics, coreGeneration: 1)
        for _ in 0..<4 { log.record(.periodic, metrics: metrics, coreGeneration: 1) }
        log.finish(metrics: metrics, coreGeneration: 1)
        let files = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 3)
        let rows = try records(in: directory)
        XCTAssertEqual(rows.compactMap { $0["sequence"] as? Int }, Array(1...6))
        XCTAssertEqual(rows.last?["event"] as? String, "sessionStopped")
        XCTAssertEqual(Set(rows.compactMap { $0["sessionStartedAt"] as? String }).count, 1)
        for file in files {
            XCTAssertEqual(try String(contentsOf: file).split(separator: "\n").count, 2)
        }
    }

    func testRetentionPreservesOtherFilesSymlinksAndHardLinks() throws {
        let directory = try makeDirectory()
        let manager = FileManager.default
        for _ in 0..<25 {
            let file = directory.appendingPathComponent("viewer-session-\(UUID().uuidString).jsonl")
            try Data().write(to: file)
        }
        let preserved = directory.appendingPathComponent("notes.jsonl")
        try Data("preserve".utf8).write(to: preserved)
        let symlink = directory.appendingPathComponent("viewer-session-\(UUID().uuidString).jsonl")
        try manager.createSymbolicLink(at: symlink, withDestinationURL: preserved)
        let hardlink = directory.appendingPathComponent("viewer-session-\(UUID().uuidString).jsonl")
        try manager.linkItem(at: preserved, to: hardlink)
        let stale = directory.appendingPathComponent("viewer-session-\(UUID().uuidString).jsonl")
        try Data().write(to: stale)
        try manager.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-8 * 24 * 60 * 60)],
            ofItemAtPath: stale.path)
        let metrics = PipelineMetrics(
            inputWidth: 0, inputHeight: 0, inputFPS: 30, selectedGPU: "test")
        let log = try ViewerSessionLiveLog(directory: directory, forceRelay: false)
        log.finish(metrics: metrics, coreGeneration: 1)
        XCTAssertEqual(
            try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).count,
            27)
        XCTAssertFalse(manager.fileExists(atPath: stale.path))
        XCTAssertEqual(try String(contentsOf: preserved), "preserve")
        XCTAssertEqual(try String(contentsOf: symlink), "preserve")
        XCTAssertEqual(try String(contentsOf: hardlink), "preserve")
    }

    func testRotationFailureDisablesOnlyLogging() throws {
        let parent = try makeDirectory()
        let directory = parent.appendingPathComponent("logs", isDirectory: true)
        let metrics = PipelineMetrics(
            inputWidth: 0, inputHeight: 0, inputFPS: 30, selectedGPU: "test")
        let log = try ViewerSessionLiveLog(
            directory: directory, forceRelay: false, maximumRecordsPerFile: 1)
        log.record(.sessionStarted, metrics: metrics, coreGeneration: 1)
        log.finish(metrics: metrics, coreGeneration: 1)
        let failingLog = try ViewerSessionLiveLog(
            directory: directory, forceRelay: false, maximumRecordsPerFile: 1)
        try FileManager.default.removeItem(at: directory)
        try Data().write(to: directory)
        failingLog.record(.periodic, metrics: metrics, coreGeneration: 1)
        failingLog.finish(metrics: metrics, coreGeneration: 1)
        metrics.recordKeyframeRequest()
        XCTAssertEqual(metrics.viewerDiagnosticSnapshot().keyframeRequests, 1)
    }
}
