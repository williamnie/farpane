import Darwin
import Foundation

/// Pins an explicit local file/directory selection and publishes only a
/// normalized manifest plus opaque lease. Construction performs a bounded,
/// descriptor-relative snapshot; no path enters a future wire/ABI request.
package final class ViewerFileTransferUploadSourceOwner: @unchecked Sendable {
    package static let maximumSelections = 64
    package static let maximumDepth = 64

    private struct DirectoryIdentity: Equatable {
        let device: dev_t
        let inode: ino_t
        let owner: uid_t
        let permissions: mode_t
    }

    private struct FileIdentity: Equatable {
        let device: dev_t
        let inode: ino_t
        let owner: uid_t
        let permissions: mode_t
        let links: nlink_t
        let size: off_t
        let modifiedSeconds: time_t
        let modifiedNanoseconds: Int64
        let changedSeconds: time_t
        let changedNanoseconds: Int64
    }

    private enum RootKind {
        case directory(DirectoryIdentity)
        case file(FileIdentity)
    }

    private struct SourceRoot {
        let descriptor: Int32
        let kind: RootKind
    }

    private struct SourceFile {
        let rootIndex: Int
        let rawComponents: [String]
        let identity: FileIdentity
        let manifestFile: ViewerFileTransferFile
    }

    private struct Selection {
        let url: URL
        let manifestName: String
        let collisionKey: String
    }

    private struct Snapshot {
        var roots: [SourceRoot] = []
        var files: [SourceFile] = []
        var emptyDirectories: [String] = []
        var metadataBytes = 0

        mutating func admit(path: String) -> Bool {
            let next = metadataBytes.addingReportingOverflow(path.utf8.count)
            guard
                !next.overflow,
                next.partialValue
                    <= ViewerFileTransferManifest.maximumMetadataUTF8Bytes,
                files.count + emptyDirectories.count
                    < ViewerFileTransferManifest.maximumEntries
            else { return false }
            metadataBytes = next.partialValue
            return true
        }
    }

    private let lock = NSLock()
    private let sessionEpoch: UInt64
    private let leaseToken: UInt64
    private var roots: [SourceRoot]?
    private var files: [SourceFile]?
    private var manifestStorage: ViewerFileTransferManifest?

    package init?(
        sessionEpoch: UInt64,
        selectedURLs: [URL],
        leaseToken: UInt64 = UInt64.random(in: 1...UInt64.max)
    ) {
        guard
            sessionEpoch > 0,
            leaseToken > 0,
            !selectedURLs.isEmpty,
            selectedURLs.count <= Self.maximumSelections,
            let selections = Self.normalizedSelections(selectedURLs)
        else { return nil }

        var snapshot = Snapshot()
        var succeeded = false
        defer {
            if !succeeded {
                snapshot.roots.forEach { Darwin.close($0.descriptor) }
            }
        }

        for selection in selections {
            guard Self.snapshot(selection, into: &snapshot) else {
                return nil
            }
        }
        let manifestFiles = snapshot.files
            .map(\.manifestFile)
            .sorted { $0.relativePath.utf8.lexicographicallyPrecedes(
                $1.relativePath.utf8
            ) }
        var fileByPath: [String: SourceFile] = [:]
        for file in snapshot.files {
            guard fileByPath.updateValue(
                file,
                forKey: file.manifestFile.relativePath
            ) == nil else { return nil }
        }
        guard
            fileByPath.count == snapshot.files.count,
            let manifest = ViewerFileTransferManifest(
                files: manifestFiles,
                emptyDirectories: snapshot.emptyDirectories.sorted {
                    $0.utf8.lexicographicallyPrecedes($1.utf8)
                }
            )
        else { return nil }
        snapshot.files = manifestFiles.compactMap {
            fileByPath[$0.relativePath]
        }
        guard snapshot.files.count == manifestFiles.count else { return nil }

        self.sessionEpoch = sessionEpoch
        self.leaseToken = leaseToken
        roots = snapshot.roots
        files = snapshot.files
        manifestStorage = manifest
        succeeded = true
    }

    deinit {
        closeOwnedRoots()
    }

    package var lease: ViewerFileTransferUploadSourceLease? {
        lock.lock()
        defer { lock.unlock() }
        guard roots != nil, manifestStorage != nil else { return nil }
        return ViewerFileTransferUploadSourceLease(
            token: leaseToken,
            sessionEpoch: sessionEpoch
        )
    }

    package var manifest: ViewerFileTransferManifest? {
        lock.lock()
        defer { lock.unlock() }
        guard roots != nil else { return nil }
        return manifestStorage
    }

    package func makeUploadRequest(
        transferID: Int32
    ) -> ViewerFileTransferUploadRequest? {
        lock.lock()
        defer { lock.unlock() }
        guard roots != nil,
              let manifestStorage,
              let source = ViewerFileTransferUploadSourceLease(
                  token: leaseToken,
                  sessionEpoch: sessionEpoch
              )
        else { return nil }
        return ViewerFileTransferUploadRequest(
            sessionEpoch: sessionEpoch,
            transferID: transferID,
            source: source,
            manifest: manifestStorage
        )
    }

    /// The descriptor is valid only during `body`. The result is returned only
    /// if the same file identity and bounded metadata remain true afterwards.
    package func withPinnedFileDescriptor<Result>(
        for lease: ViewerFileTransferUploadSourceLease,
        fileNumber: Int,
        _ body: (Int32) throws -> Result
    ) rethrows -> Result? {
        lock.lock()
        defer { lock.unlock() }
        guard
            lease.sessionEpoch == sessionEpoch,
            lease.token == leaseToken,
            let roots,
            let files,
            files.indices.contains(fileNumber)
        else { return nil }
        let file = files[fileNumber]
        guard roots.indices.contains(file.rootIndex),
              let descriptor = Self.openPinnedFile(
                  root: roots[file.rootIndex],
                  file: file
              )
        else { return nil }
        defer { Darwin.close(descriptor) }
        guard Darwin.lseek(descriptor, 0, SEEK_SET) == 0 else {
            return nil
        }
        let result = try body(descriptor)
        guard Self.matchesFile(descriptor, identity: file.identity) else {
            return nil
        }
        return result
    }

    @discardableResult
    package func teardown(sessionEpoch: UInt64) -> Bool {
        lock.lock()
        guard
            sessionEpoch == self.sessionEpoch,
            let roots
        else {
            lock.unlock()
            return false
        }
        self.roots = nil
        files = nil
        manifestStorage = nil
        lock.unlock()
        roots.forEach { Darwin.close($0.descriptor) }
        return true
    }

    private func closeOwnedRoots() {
        lock.lock()
        let roots = roots ?? []
        self.roots = nil
        files = nil
        manifestStorage = nil
        lock.unlock()
        roots.forEach { Darwin.close($0.descriptor) }
    }

    private static func normalizedSelections(_ urls: [URL]) -> [Selection]? {
        var selections: [Selection] = []
        var collisionKeys: Set<String> = []
        for url in urls {
            guard
                NSString(string: url.path).isAbsolutePath,
                url.standardizedFileURL.path == url.path,
                url.path != "/",
                let name = normalizedComponent(url.lastPathComponent),
                let key = collisionKey(name),
                collisionKeys.insert(key).inserted
            else { return nil }
            selections.append(Selection(
                url: url,
                manifestName: name,
                collisionKey: key
            ))
        }
        return selections.sorted {
            if $0.collisionKey != $1.collisionKey {
                return $0.collisionKey.utf8.lexicographicallyPrecedes(
                    $1.collisionKey.utf8
                )
            }
            return $0.manifestName.utf8.lexicographicallyPrecedes(
                $1.manifestName.utf8
            )
        }
    }

    private static func snapshot(
        _ selection: Selection,
        into snapshot: inout Snapshot
    ) -> Bool {
        let descriptor = selection.url.withUnsafeFileSystemRepresentation {
            path in
            guard let path else { return Int32(-1) }
            return Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else { return false }

        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0 else {
            Darwin.close(descriptor)
            return false
        }
        let type = status.st_mode & mode_t(S_IFMT)
        if type == mode_t(S_IFREG) {
            guard
                let identity = fileIdentity(status),
                let modifiedTime = Int64(exactly: status.st_mtimespec.tv_sec),
                modifiedTime >= 0,
                snapshot.admit(path: selection.manifestName),
                let file = ViewerFileTransferFile(
                    relativePath: selection.manifestName,
                    size: UInt64(status.st_size),
                    modifiedTime: modifiedTime
                )
            else {
                Darwin.close(descriptor)
                return false
            }
            let rootIndex = snapshot.roots.count
            snapshot.roots.append(SourceRoot(
                descriptor: descriptor,
                kind: .file(identity)
            ))
            snapshot.files.append(SourceFile(
                rootIndex: rootIndex,
                rawComponents: [],
                identity: identity,
                manifestFile: file
            ))
            return true
        }
        guard
            type == mode_t(S_IFDIR),
            let identity = directoryIdentity(status)
        else {
            Darwin.close(descriptor)
            return false
        }
        let rootIndex = snapshot.roots.count
        snapshot.roots.append(SourceRoot(
            descriptor: descriptor,
            kind: .directory(identity)
        ))
        let before = snapshot.files.count + snapshot.emptyDirectories.count
        guard snapshotDirectory(
            descriptor: descriptor,
            rootIndex: rootIndex,
            rootDevice: status.st_dev,
            rawComponents: [],
            manifestComponents: [selection.manifestName],
            depth: 0,
            into: &snapshot
        ) else { return false }
        if snapshot.files.count + snapshot.emptyDirectories.count == before {
            guard snapshot.admit(path: selection.manifestName) else {
                return false
            }
            snapshot.emptyDirectories.append(selection.manifestName)
        }
        return true
    }

    private static func snapshotDirectory(
        descriptor: Int32,
        rootIndex: Int,
        rootDevice: dev_t,
        rawComponents: [String],
        manifestComponents: [String],
        depth: Int,
        into snapshot: inout Snapshot
    ) -> Bool {
        guard depth < maximumDepth,
              let entries = directoryEntries(descriptor)
        else { return false }
        for entry in entries {
            var namedStatus = stat()
            let lookup = entry.rawName.withCString {
                Darwin.fstatat(
                    descriptor,
                    $0,
                    &namedStatus,
                    AT_SYMLINK_NOFOLLOW
                )
            }
            guard lookup == 0,
                  namedStatus.st_dev == rootDevice
            else { return false }
            let nextRaw = rawComponents + [entry.rawName]
            let nextManifest = manifestComponents + [entry.manifestName]
            let manifestPath = nextManifest.joined(separator: "/")
            let type = namedStatus.st_mode & mode_t(S_IFMT)
            if type == mode_t(S_IFDIR) {
                let child = entry.rawName.withCString {
                    Darwin.openat(
                        descriptor,
                        $0,
                        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                    )
                }
                guard
                    child >= 0,
                    matchesNamedDirectory(
                        child,
                        namedStatus: namedStatus
                    )
                else {
                    if child >= 0 { Darwin.close(child) }
                    return false
                }
                let before = snapshot.files.count
                    + snapshot.emptyDirectories.count
                let accepted = snapshotDirectory(
                    descriptor: child,
                    rootIndex: rootIndex,
                    rootDevice: rootDevice,
                    rawComponents: nextRaw,
                    manifestComponents: nextManifest,
                    depth: depth + 1,
                    into: &snapshot
                )
                Darwin.close(child)
                guard accepted else { return false }
                if snapshot.files.count
                    + snapshot.emptyDirectories.count == before {
                    guard snapshot.admit(path: manifestPath) else {
                        return false
                    }
                    snapshot.emptyDirectories.append(manifestPath)
                }
                continue
            }
            guard type == mode_t(S_IFREG) else { return false }
            let fileDescriptor = entry.rawName.withCString {
                Darwin.openat(
                    descriptor,
                    $0,
                    O_RDONLY | O_NOFOLLOW | O_CLOEXEC
                )
            }
            guard fileDescriptor >= 0 else { return false }
            var fileStatus = stat()
            let fileAccepted = Darwin.fstat(fileDescriptor, &fileStatus) == 0
                && sameIdentity(fileStatus, namedStatus)
            let identity = fileAccepted ? fileIdentity(fileStatus) : nil
            Darwin.close(fileDescriptor)
            guard
                let identity,
                let modifiedTime = Int64(
                    exactly: fileStatus.st_mtimespec.tv_sec
                ),
                modifiedTime >= 0,
                snapshot.admit(path: manifestPath),
                let manifestFile = ViewerFileTransferFile(
                    relativePath: manifestPath,
                    size: UInt64(fileStatus.st_size),
                    modifiedTime: modifiedTime
                )
            else { return false }
            snapshot.files.append(SourceFile(
                rootIndex: rootIndex,
                rawComponents: nextRaw,
                identity: identity,
                manifestFile: manifestFile
            ))
        }
        return true
    }

    private static func directoryEntries(
        _ descriptor: Int32
    ) -> [(rawName: String, manifestName: String)]? {
        let duplicate = Darwin.openat(
            descriptor,
            ".",
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard duplicate >= 0 else { return nil }
        guard let stream = Darwin.fdopendir(duplicate) else {
            Darwin.close(duplicate)
            return nil
        }
        defer { Darwin.closedir(stream) }

        var entries: [(String, String)] = []
        errno = 0
        while let entry = Darwin.readdir(stream) {
            guard let rawName = directoryEntryName(entry) else { return nil }
            if rawName == "." || rawName == ".." { continue }
            if rawName.hasPrefix(".") { continue }
            guard let manifestName = normalizedComponent(rawName) else {
                return nil
            }
            entries.append((rawName, manifestName))
        }
        guard errno == 0 else { return nil }
        return entries.sorted {
            if $0.1 != $1.1 {
                return $0.1.utf8.lexicographicallyPrecedes($1.1.utf8)
            }
            return $0.0.utf8.lexicographicallyPrecedes($1.0.utf8)
        }
    }

    private static func directoryEntryName(
        _ entry: UnsafeMutablePointer<dirent>
    ) -> String? {
        withUnsafePointer(to: &entry.pointee.d_name) { pointer in
            pointer.withMemoryRebound(
                to: CChar.self,
                capacity: Int(MAXNAMLEN) + 1
            ) { String(validatingUTF8: $0) }
        }
    }

    private static func normalizedComponent(_ raw: String) -> String? {
        guard
            !raw.isEmpty,
            raw != ".",
            raw != "..",
            !raw.contains("/"),
            !raw.contains("\0"),
            raw.unicodeScalars.allSatisfy({
                !CharacterSet.controlCharacters.contains($0)
            })
        else { return nil }
        let normalized = raw.precomposedStringWithCanonicalMapping
        guard
            !normalized.isEmpty,
            !normalized.lowercased().hasSuffix(
                ViewerFileTransferManifest.privateStagingSuffix
            ),
            ViewerFileTransferManifest.accepts(relativePath: normalized)
        else { return nil }
        return normalized
    }

    private static func collisionKey(_ name: String) -> String? {
        let key = name.folding(
            options: [.caseInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        return key.isEmpty ? nil : key
    }

    private static func openPinnedFile(
        root: SourceRoot,
        file: SourceFile
    ) -> Int32? {
        switch root.kind {
        case .file(let rootIdentity):
            guard
                file.rawComponents.isEmpty,
                rootIdentity == file.identity,
                matchesFile(root.descriptor, identity: rootIdentity)
            else { return nil }
            let duplicate = Darwin.fcntl(
                root.descriptor,
                F_DUPFD_CLOEXEC,
                0
            )
            guard duplicate >= 0,
                  matchesFile(duplicate, identity: file.identity)
            else {
                if duplicate >= 0 { Darwin.close(duplicate) }
                return nil
            }
            return duplicate
        case .directory(let rootIdentity):
            guard
                !file.rawComponents.isEmpty,
                matchesDirectory(root.descriptor, identity: rootIdentity)
            else { return nil }
            var descriptor = Darwin.openat(
                root.descriptor,
                ".",
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
            guard descriptor >= 0 else { return nil }
            for component in file.rawComponents.dropLast() {
                let next = component.withCString {
                    Darwin.openat(
                        descriptor,
                        $0,
                        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                    )
                }
                Darwin.close(descriptor)
                guard next >= 0 else { return nil }
                var status = stat()
                guard Darwin.fstat(next, &status) == 0,
                      directoryIdentity(status) != nil
                else {
                    Darwin.close(next)
                    return nil
                }
                descriptor = next
            }
            guard let finalName = file.rawComponents.last else {
                Darwin.close(descriptor)
                return nil
            }
            let result = finalName.withCString {
                Darwin.openat(
                    descriptor,
                    $0,
                    O_RDONLY | O_NOFOLLOW | O_CLOEXEC
                )
            }
            Darwin.close(descriptor)
            guard result >= 0,
                  matchesFile(result, identity: file.identity)
            else {
                if result >= 0 { Darwin.close(result) }
                return nil
            }
            return result
        }
    }

    private static func directoryIdentity(
        _ status: stat
    ) -> DirectoryIdentity? {
        guard
            status.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
            status.st_uid == geteuid() || status.st_uid == 0,
            status.st_mode & mode_t(0o022) == 0
        else { return nil }
        return DirectoryIdentity(
            device: status.st_dev,
            inode: status.st_ino,
            owner: status.st_uid,
            permissions: status.st_mode & mode_t(0o777)
        )
    }

    private static func fileIdentity(_ status: stat) -> FileIdentity? {
        guard
            status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
            status.st_uid == geteuid() || status.st_uid == 0,
            status.st_mode & mode_t(0o022) == 0,
            status.st_nlink > 0,
            status.st_size >= 0
        else { return nil }
        return FileIdentity(
            device: status.st_dev,
            inode: status.st_ino,
            owner: status.st_uid,
            permissions: status.st_mode & mode_t(0o777),
            links: status.st_nlink,
            size: status.st_size,
            modifiedSeconds: status.st_mtimespec.tv_sec,
            modifiedNanoseconds: Int64(status.st_mtimespec.tv_nsec),
            changedSeconds: status.st_ctimespec.tv_sec,
            changedNanoseconds: Int64(status.st_ctimespec.tv_nsec)
        )
    }

    private static func matchesDirectory(
        _ descriptor: Int32,
        identity: DirectoryIdentity
    ) -> Bool {
        var status = stat()
        return Darwin.fstat(descriptor, &status) == 0
            && directoryIdentity(status) == identity
    }

    private static func matchesNamedDirectory(
        _ descriptor: Int32,
        namedStatus: stat
    ) -> Bool {
        var status = stat()
        return Darwin.fstat(descriptor, &status) == 0
            && sameIdentity(status, namedStatus)
            && directoryIdentity(status) != nil
    }

    private static func matchesFile(
        _ descriptor: Int32,
        identity: FileIdentity
    ) -> Bool {
        var status = stat()
        return Darwin.fstat(descriptor, &status) == 0
            && fileIdentity(status) == identity
    }

    private static func sameIdentity(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino
    }
}
