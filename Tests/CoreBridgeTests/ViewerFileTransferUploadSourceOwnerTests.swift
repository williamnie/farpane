import Darwin
import Foundation
@testable import CoreBridge
import XCTest

final class ViewerFileTransferUploadSourceOwnerTests: XCTestCase {
    func testSnapshotsExplicitFilesAndDirectoriesIntoPathFreeRequest() throws {
        let root = try makePrivateDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let single = root.appendingPathComponent("single.txt")
        try write(Data("one".utf8), to: single)
        let folder = root.appendingPathComponent("Folder", isDirectory: true)
        let nested = folder.appendingPathComponent("Sub", isDirectory: true)
        let empty = folder.appendingPathComponent("Empty", isDirectory: true)
        try makeDirectory(folder)
        try makeDirectory(nested)
        try makeDirectory(empty)
        try write(Data("aa".utf8), to: folder.appendingPathComponent("a.txt"))
        try write(Data("bbb".utf8), to: nested.appendingPathComponent("b.txt"))
        try write(Data("hidden".utf8), to: folder.appendingPathComponent(".secret"))

        let owner = try XCTUnwrap(ViewerFileTransferUploadSourceOwner(
            sessionEpoch: 41,
            selectedURLs: [single, folder],
            leaseToken: 91
        ))
        let lease = try XCTUnwrap(owner.lease)
        let manifest = try XCTUnwrap(owner.manifest)

        XCTAssertEqual(lease.sessionEpoch, 41)
        XCTAssertEqual(lease.token, 91)
        XCTAssertEqual(
            manifest.files.map(\.relativePath),
            ["Folder/Sub/b.txt", "Folder/a.txt", "single.txt"]
        )
        XCTAssertEqual(manifest.emptyDirectories, ["Folder/Empty"])
        XCTAssertEqual(manifest.totalBytes, 8)
        XCTAssertFalse(manifest.files.contains { $0.relativePath.contains(".secret") })

        let request = try XCTUnwrap(owner.makeUploadRequest(transferID: 7))
        XCTAssertEqual(request.sessionEpoch, 41)
        XCTAssertEqual(request.transferID, 7)
        XCTAssertEqual(request.source, lease)
        XCTAssertEqual(request.manifest, manifest)

        let bytes = try XCTUnwrap(owner.withPinnedFileDescriptor(
            for: lease,
            fileNumber: 0
        ) { descriptor -> Data? in
            var buffer = [UInt8](repeating: 0, count: 3)
            let count = Darwin.pread(descriptor, &buffer, buffer.count, 0)
            return count == buffer.count ? Data(buffer) : nil
        })
        XCTAssertEqual(bytes, Data("bbb".utf8))
    }

    func testPinsSelectedDirectoryAndRejectsMutationAndStaleAuthority() throws {
        let root = try makePrivateDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let selected = root.appendingPathComponent("Selected", isDirectory: true)
        try makeDirectory(selected)
        let selectedFile = selected.appendingPathComponent("one.txt")
        try write(Data("old".utf8), to: selectedFile)
        var originalStatus = stat()
        XCTAssertEqual(Darwin.lstat(selectedFile.path, &originalStatus), 0)

        let owner = try XCTUnwrap(ViewerFileTransferUploadSourceOwner(
            sessionEpoch: 9,
            selectedURLs: [selected],
            leaseToken: 17
        ))
        let lease = try XCTUnwrap(owner.lease)
        let moved = root.appendingPathComponent("Moved", isDirectory: true)
        try FileManager.default.moveItem(at: selected, to: moved)
        let outside = try makePrivateDirectory(inside: root, name: "Outside")
        try write(Data("escape".utf8), to: outside.appendingPathComponent("one.txt"))
        try FileManager.default.createSymbolicLink(
            at: selected,
            withDestinationURL: outside
        )

        let pinned = try XCTUnwrap(owner.withPinnedFileDescriptor(
            for: lease,
            fileNumber: 0
        ) { descriptor -> Data? in
            var buffer = [UInt8](repeating: 0, count: 3)
            let count = Darwin.pread(descriptor, &buffer, buffer.count, 0)
            return count == buffer.count ? Data(buffer) : nil
        })
        XCTAssertEqual(pinned, Data("old".utf8))

        let movedFile = moved.appendingPathComponent("one.txt")
        try Data("new".utf8).write(to: movedFile)
        let originalTimes = [
            originalStatus.st_atimespec,
            originalStatus.st_mtimespec,
        ]
        let restored = movedFile.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return originalTimes.withUnsafeBufferPointer { times in
                Darwin.utimensat(AT_FDCWD, path, times.baseAddress, 0)
            }
        }
        XCTAssertEqual(restored, 0)
        XCTAssertNil(owner.withPinnedFileDescriptor(
            for: lease,
            fileNumber: 0
        ) { _ in true })

        let stale = try XCTUnwrap(ViewerFileTransferUploadSourceLease(
            token: lease.token,
            sessionEpoch: lease.sessionEpoch + 1
        ))
        XCTAssertNil(owner.withPinnedFileDescriptor(
            for: stale,
            fileNumber: 0
        ) { _ in true })
        XCTAssertFalse(owner.teardown(sessionEpoch: 8))
        XCTAssertTrue(owner.teardown(sessionEpoch: 9))
        XCTAssertNil(owner.lease)
        XCTAssertNil(owner.manifest)
    }

    func testRejectsSymlinkUnsafeDirectoryDuplicateTopLevelAndPrivateName() throws {
        let root = try makePrivateDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let unsafe = root.appendingPathComponent("Unsafe", isDirectory: true)
        try makeDirectory(unsafe)
        let target = unsafe.appendingPathComponent("target.txt")
        try write(Data("target".utf8), to: target)
        try FileManager.default.createSymbolicLink(
            at: unsafe.appendingPathComponent("link.txt"),
            withDestinationURL: target
        )
        XCTAssertNil(ViewerFileTransferUploadSourceOwner(
            sessionEpoch: 1,
            selectedURLs: [unsafe],
            leaseToken: 1
        ))

        let loose = try makePrivateDirectory(inside: root, name: "Loose")
        XCTAssertEqual(Darwin.chmod(loose.path, 0o777), 0)
        XCTAssertNil(ViewerFileTransferUploadSourceOwner(
            sessionEpoch: 1,
            selectedURLs: [loose],
            leaseToken: 2
        ))

        let firstParent = try makePrivateDirectory(inside: root, name: "First")
        let secondParent = try makePrivateDirectory(inside: root, name: "Second")
        let first = firstParent.appendingPathComponent("same.txt")
        let second = secondParent.appendingPathComponent("same.txt")
        try write(Data("1".utf8), to: first)
        try write(Data("2".utf8), to: second)
        XCTAssertNil(ViewerFileTransferUploadSourceOwner(
            sessionEpoch: 1,
            selectedURLs: [first, second],
            leaseToken: 3
        ))

        let staging = root.appendingPathComponent("private.farpane-part")
        try write(Data("x".utf8), to: staging)
        XCTAssertNil(ViewerFileTransferUploadSourceOwner(
            sessionEpoch: 1,
            selectedURLs: [staging],
            leaseToken: 4
        ))
        XCTAssertNil(ViewerFileTransferUploadSourceOwner(
            sessionEpoch: 1,
            selectedURLs: Array(
                repeating: first,
                count: ViewerFileTransferUploadSourceOwner.maximumSelections + 1
            ),
            leaseToken: 5
        ))
    }

    func testNormalizesExplicitLocalNameAndRejectsControlCharacter() throws {
        let root = try makePrivateDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let decomposed = root.appendingPathComponent("cafe\u{301}.txt")
        try write(Data("ok".utf8), to: decomposed)
        let owner = try XCTUnwrap(ViewerFileTransferUploadSourceOwner(
            sessionEpoch: 2,
            selectedURLs: [decomposed],
            leaseToken: 6
        ))
        XCTAssertEqual(
            try XCTUnwrap(owner.manifest).files.map(\.relativePath),
            ["café.txt"]
        )

        let control = root.appendingPathComponent("bad\nname.txt")
        try write(Data("bad".utf8), to: control)
        XCTAssertNil(ViewerFileTransferUploadSourceOwner(
            sessionEpoch: 2,
            selectedURLs: [control],
            leaseToken: 7
        ))
    }

    func testReadsExactPinnedRangesAndRejectsShortOrStaleReads() throws {
        let root = try makePrivateDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("range.bin")
        try write(Data("0123456789".utf8), to: file)
        let owner = try XCTUnwrap(ViewerFileTransferUploadSourceOwner(
            sessionEpoch: 12,
            selectedURLs: [file],
            leaseToken: 44
        ))
        let lease = try XCTUnwrap(owner.lease)

        var bytes = [UInt8](repeating: 0, count: 4)
        XCTAssertTrue(bytes.withUnsafeMutableBufferPointer { buffer in
            owner.readPinnedBytes(
                for: lease,
                fileNumber: 0,
                offset: 3,
                into: buffer.baseAddress!,
                length: buffer.count
            )
        })
        XCTAssertEqual(Data(bytes), Data("3456".utf8))
        XCTAssertFalse(bytes.withUnsafeMutableBufferPointer { buffer in
            owner.readPinnedBytes(
                for: lease,
                fileNumber: 0,
                offset: 8,
                into: buffer.baseAddress!,
                length: buffer.count
            )
        })
        XCTAssertTrue(owner.teardown(sessionEpoch: 12))
        XCTAssertFalse(bytes.withUnsafeMutableBufferPointer { buffer in
            owner.readPinnedBytes(
                for: lease,
                fileNumber: 0,
                offset: 0,
                into: buffer.baseAddress!,
                length: buffer.count
            )
        })
    }

    func testSemanticReadAdapterBindsExactRouteAndClosesOnTerminal() throws {
        let root = try makePrivateDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("payload.bin")
        try write(Data("abcdefgh".utf8), to: file)
        let owner = try XCTUnwrap(ViewerFileTransferUploadSourceOwner(
            sessionEpoch: 21,
            selectedURLs: [file],
            leaseToken: 55
        ))
        let request = try XCTUnwrap(owner.makeUploadRequest(transferID: 6))
        let adapter = ViewerFileTransferUploadReadAdapter()
        XCTAssertTrue(adapter.begin(request, sourceOwner: owner))
        XCTAssertFalse(adapter.begin(request, sourceOwner: owner))

        var bytes = [UInt8](repeating: 0, count: 3)
        let accepted = bytes.withUnsafeMutableBufferPointer { buffer in
            adapter.read(
                sessionEpoch: 21,
                transferID: 6,
                sourceToken: 55,
                fileNumber: 0,
                offset: 2,
                buffer: buffer.baseAddress!,
                length: buffer.count
            )
        }
        XCTAssertEqual(accepted, .success(bytesWritten: 3))
        XCTAssertEqual(Data(bytes), Data("cde".utf8))
        XCTAssertEqual(bytes.withUnsafeMutableBufferPointer { buffer in
            adapter.read(
                sessionEpoch: 21,
                transferID: 6,
                sourceToken: 56,
                fileNumber: 0,
                offset: 2,
                buffer: buffer.baseAddress!,
                length: buffer.count
            )
        }, .rejected)

        let terminal = try XCTUnwrap(CoreFileTransferEvent(
            sessionEpoch: 21,
            transferID: 6,
            sequence: 1,
            kind: .cancelled,
            failure: .none,
            currentFileNumber: nil,
            filesCompleted: 0,
            totalFiles: 1,
            bytesCompleted: 0,
            totalBytes: 8,
            bytesPerSecond: 0
        ))
        XCTAssertTrue(adapter.observe(terminal))
        XCTAssertNil(owner.lease)
        XCTAssertEqual(bytes.withUnsafeMutableBufferPointer { buffer in
            adapter.read(
                sessionEpoch: 21,
                transferID: 6,
                sourceToken: 55,
                fileNumber: 0,
                offset: 0,
                buffer: buffer.baseAddress!,
                length: buffer.count
            )
        }, .rejected)
    }

    func testUploadPickerContractIsExplicitAndProductWired() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let dialogs = try String(
            contentsOf: repository.appendingPathComponent(
                "Sources/RustDeskNative/ViewerFileTransferDialogs.swift"
            ),
            encoding: .utf8
        )
        let app = try String(
            contentsOf: repository.appendingPathComponent(
                "Sources/RustDeskNative/RustDeskNativeApp.swift"
            ),
            encoding: .utf8
        )
        let viewerUI = try String(
            contentsOf: repository.appendingPathComponent(
                "Sources/RustDeskNative/ViewerUI.swift"
            ),
            encoding: .utf8
        )

        for marker in [
            "ViewerFileTransferUploadSourcePickerController",
            "panel.canChooseFiles = true",
            "panel.canChooseDirectories = true",
            "panel.allowsMultipleSelection = true",
            "panel.resolvesAliases = false",
        ] {
            XCTAssertTrue(dialogs.contains(marker), marker)
        }
        XCTAssertTrue(app.contains("requestFileTransferUpload"))
        XCTAssertTrue(app.contains(
            "selection: .upload(selectedURLs: selectedURLs)"
        ))
        XCTAssertTrue(viewerUI.contains("onFileTransferUploadAction"))
        XCTAssertTrue(viewerUI.contains("发送文件"))
    }

    private func makePrivateDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ViewerFileTransferUploadSourceOwnerTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false
        )
        XCTAssertEqual(Darwin.chmod(root.path, 0o700), 0)
        return root
    }

    private func makePrivateDirectory(
        inside parent: URL,
        name: String
    ) throws -> URL {
        let directory = parent.appendingPathComponent(name, isDirectory: true)
        try makeDirectory(directory)
        return directory
    }

    private func makeDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: false
        )
        XCTAssertEqual(Darwin.chmod(url.path, 0o700), 0)
    }

    private func write(_ data: Data, to url: URL) throws {
        XCTAssertTrue(FileManager.default.createFile(
            atPath: url.path,
            contents: data,
            attributes: [.posixPermissions: NSNumber(value: 0o600)]
        ))
    }
}
