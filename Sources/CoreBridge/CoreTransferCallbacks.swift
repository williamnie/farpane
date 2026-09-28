import CoreBridgeShim
import Foundation

let fileTransferEventCallback: RDNFileTransferEventCallback = { context, eventPointer in
    guard let context, let eventPointer else { return }
    let raw = eventPointer.pointee
    guard raw.abi_version == RDN_ABI_VERSION, raw.current_file_number >= -1,
        let kind = CoreFileTransferEventKind(rawValue: raw.kind),
        let failure = CoreFileTransferFailure(rawValue: raw.failure),
        let event = CoreFileTransferEvent(
            sessionEpoch: raw.session_epoch, transferID: raw.transfer_id, sequence: raw.sequence,
            kind: kind, failure: failure,
            currentFileNumber: raw.current_file_number >= 0 ? Int(raw.current_file_number) : nil,
            filesCompleted: raw.files_completed, totalFiles: raw.total_files,
            bytesCompleted: raw.bytes_completed, totalBytes: raw.total_bytes,
            bytesPerSecond: raw.bytes_per_second)
    else { return }
    let box = Unmanaged<CallbackBox>.fromOpaque(context).takeUnretainedValue()
    box.deliverFileTransferEvent(event)
}

let fileTransferListCallback: RDNFileTransferListCallback = { context, eventPointer in
    guard let context, let eventPointer else { return }
    let raw = eventPointer.pointee
    guard raw.abi_version == RDN_ABI_VERSION, raw.session_epoch > 0, raw.request_id > 0,
        let status = CoreFileTransferListStatus(rawValue: raw.status),
        raw.entry_count <= Int(RDN_MAX_FILE_TRANSFER_LIST_ENTRIES)
    else { return }

    var entries: [CoreFileTransferListEntry] = []
    entries.reserveCapacity(raw.entry_count)
    if raw.entry_count > 0 {
        guard let rawEntries = raw.entries else { return }
        for index in 0..<raw.entry_count {
            let rawEntry = rawEntries.advanced(by: index).pointee
            guard let kind = CoreFileTransferListEntryKind(rawValue: rawEntry.kind),
                rawEntry.relative_path_length > 0,
                rawEntry.relative_path_length
                    <= Int(RDN_MAX_FILE_TRANSFER_LIST_METADATA_UTF8_BYTES),
                let pathBytes = rawEntry.relative_path_utf8
            else { return }
            let pathData = Data(bytes: pathBytes, count: rawEntry.relative_path_length)
            guard let relativePath = String(data: pathData, encoding: .utf8) else { return }
            entries.append(
                CoreFileTransferListEntry(
                    kind: kind, relativePath: relativePath, size: rawEntry.size,
                    modifiedTime: rawEntry.modified_time))
        }
    } else if raw.entries != nil {
        return
    }
    guard
        let event = CoreFileTransferListEvent(
            sessionEpoch: raw.session_epoch, requestID: raw.request_id, status: status,
            entries: entries)
    else { return }
    let box = Unmanaged<CallbackBox>.fromOpaque(context).takeUnretainedValue()
    box.deliverFileTransferList(event)
}

let fileTransferManifestCallback: RDNFileTransferManifestCallback = { context, eventPointer in
    guard let context, let eventPointer else { return }
    let raw = eventPointer.pointee
    guard raw.abi_version == RDN_ABI_VERSION, raw.session_epoch > 0, raw.request_id > 0,
        let status = CoreFileTransferListStatus(rawValue: raw.status),
        let part = CoreFileTransferManifestPartKind(rawValue: raw.part),
        raw.entry_count <= Int(RDN_MAX_FILE_TRANSFER_LIST_ENTRIES)
    else { return }

    var entries: [CoreFileTransferListEntry] = []
    entries.reserveCapacity(raw.entry_count)
    if raw.entry_count > 0 {
        guard let rawEntries = raw.entries else { return }
        for index in 0..<raw.entry_count {
            let rawEntry = rawEntries.advanced(by: index).pointee
            guard let kind = CoreFileTransferListEntryKind(rawValue: rawEntry.kind),
                rawEntry.relative_path_length > 0,
                rawEntry.relative_path_length
                    <= Int(RDN_MAX_FILE_TRANSFER_LIST_METADATA_UTF8_BYTES),
                let pathBytes = rawEntry.relative_path_utf8
            else { return }
            let pathData = Data(bytes: pathBytes, count: rawEntry.relative_path_length)
            guard let relativePath = String(data: pathData, encoding: .utf8) else { return }
            entries.append(
                CoreFileTransferListEntry(
                    kind: kind, relativePath: relativePath, size: rawEntry.size,
                    modifiedTime: rawEntry.modified_time))
        }
    } else if raw.entries != nil {
        return
    }
    guard
        let event = CoreFileTransferManifestEvent(
            sessionEpoch: raw.session_epoch, requestID: raw.request_id, status: status, part: part,
            entries: entries)
    else { return }
    let box = Unmanaged<CallbackBox>.fromOpaque(context).takeUnretainedValue()
    box.deliverFileTransferManifest(event)
}

let fileTransferReceiveBlockCallback: RDNFileTransferReceiveBlockCallback = {
    context, blockPointer in
    guard let context, let blockPointer else { return }
    let raw = blockPointer.pointee
    guard raw.abi_version == RDN_ABI_VERSION, raw.length > 0,
        raw.length <= CoreFileTransferReceiveBlock.maximumPayloadBytes, let bytes = raw.data
    else { return }
    let payload = Data(bytes: bytes, count: raw.length)
    guard
        let block = CoreFileTransferReceiveBlock(
            sessionEpoch: raw.session_epoch, transferID: raw.transfer_id,
            fileNumber: raw.file_number, payload: payload)
    else { return }
    let box = Unmanaged<CallbackBox>.fromOpaque(context).takeUnretainedValue()
    box.deliverFileTransferReceiveBlock(block)
}

let fileTransferUploadReadCallback: RDNFileTransferUploadReadCallback = {
    context, requestPointer, bytesWrittenPointer in
    guard let bytesWrittenPointer else { return Int32(RDN_CLIENT_ERR_INVALID_PAYLOAD) }
    bytesWrittenPointer.pointee = 0
    guard let context, let requestPointer else { return Int32(RDN_CLIENT_ERR_INVALID_PAYLOAD) }
    let raw = requestPointer.pointee
    guard raw.abi_version == RDN_ABI_VERSION, raw.session_epoch > 0, raw.transfer_id > 0,
        raw.source_token > 0, raw.length > 0,
        raw.length <= CoreFileTransferReceiveBlock.maximumPayloadBytes, let buffer = raw.buffer
    else { return Int32(RDN_CLIENT_ERR_INVALID_PAYLOAD) }
    let box = Unmanaged<CallbackBox>.fromOpaque(context).takeUnretainedValue()
    switch box.readFileTransferUpload(
        sessionEpoch: raw.session_epoch, transferID: raw.transfer_id, sourceToken: raw.source_token,
        fileNumber: raw.file_number, offset: raw.offset, buffer: buffer, length: raw.length)
    {
    case .success(let bytesWritten):
        guard bytesWritten == raw.length else { return Int32(RDN_CLIENT_ERR_INVALID_PAYLOAD) }
        bytesWrittenPointer.pointee = bytesWritten
        return 0
    case .rejected: return Int32(RDN_CLIENT_ERR_VALIDATION)
    }
}
