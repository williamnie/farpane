import CoreBridgeShim
import Foundation

let stateCallback: RDNStateCallback = { context, state, code, message in
    guard let context else { return }
    let box = Unmanaged<CallbackBox>.fromOpaque(context).takeUnretainedValue()
    let event = CoreStateEvent(
        state: CoreConnectionState(rawValue: Int32(state.rawValue)) ?? .error, code: code,
        message: message.map { String(cString: $0) } ?? "")
    box.queue.async { box.onState(event) }
}

let remotePermissionCallback: RDNRemotePermissionCallback = { context, eventPointer in
    guard let context, let eventPointer else { return }
    let raw = eventPointer.pointee
    guard raw.abi_version == RDN_ABI_VERSION, raw.connection_epoch > 0,
        let permission = CoreRemotePermission(rawValue: raw.permission)
    else { return }
    let event = CoreRemotePermissionEvent(
        connectionEpoch: raw.connection_epoch, permission: permission, enabled: raw.enabled)
    let box = Unmanaged<CallbackBox>.fromOpaque(context).takeUnretainedValue()
    box.queue.async { box.onRemotePermission(event) }
}

let displayCatalogCallback: RDNDisplayCatalogCallback = { context, eventPointer in
    guard let context, let eventPointer else { return }
    let raw = eventPointer.pointee
    guard raw.abi_version == RDN_ABI_VERSION,
        let status = CoreDisplayCatalogStatus(rawValue: raw.status),
        raw.entry_count <= Int(RDN_MAX_DISPLAY_CATALOG_ENTRIES),
        (raw.entry_count == 0) == (raw.entries == nil),
        raw.selected_display_known
            ? raw.selected_display_index != UInt32(RDN_DISPLAY_INDEX_UNKNOWN)
            : raw.selected_display_index == UInt32(RDN_DISPLAY_INDEX_UNKNOWN)
    else { return }
    var entries: [CoreDisplayCatalogEntry] = []
    entries.reserveCapacity(raw.entry_count)
    if let rawEntries = raw.entries {
        for offset in 0..<raw.entry_count {
            let entry = rawEntries[offset]
            guard entry.name_length <= Int(RDN_MAX_DISPLAY_NAME_UTF8_BYTES),
                (entry.name_length == 0) == (entry.name_utf8 == nil)
            else { return }
            let name: String
            if let bytes = entry.name_utf8 {
                let data = Data(bytes: bytes, count: entry.name_length)
                guard let copied = String(data: data, encoding: .utf8) else { return }
                name = copied
            } else {
                name = ""
            }
            guard
                let projected = CoreDisplayCatalogEntry(
                    displayIndex: entry.display_index, x: entry.x, y: entry.y, width: entry.width,
                    height: entry.height, online: entry.online, scale: entry.scale, name: name)
            else { return }
            entries.append(projected)
        }
    }
    guard
        let event = CoreDisplayCatalogEvent(
            connectionEpoch: raw.connection_epoch, catalogRevision: raw.catalog_revision,
            status: status,
            selectedDisplayIndex: raw.selected_display_known ? raw.selected_display_index : nil,
            entries: entries)
    else { return }
    let box = Unmanaged<CallbackBox>.fromOpaque(context).takeUnretainedValue()
    box.observeDisplayCatalog(event)
}

let displaySelectionCallback: RDNDisplaySelectionCallback = { context, eventPointer in
    guard let context, let eventPointer else { return }
    let raw = eventPointer.pointee
    guard raw.abi_version == RDN_ABI_VERSION,
        let result = CoreDisplaySelectionResult(rawValue: raw.result),
        let failure = CoreDisplaySelectionFailure(rawValue: raw.failure),
        let event = CoreDisplaySelectionEvent(
            connectionEpoch: raw.connection_epoch, commandID: raw.command_id,
            catalogRevision: raw.catalog_revision, displayIndex: raw.display_index, result: result,
            failure: failure)
    else { return }
    let box = Unmanaged<CallbackBox>.fromOpaque(context).takeUnretainedValue()
    box.deliverDisplaySelection(event)
}

let videoCallback: RDNVideoCallback = { context, framePointer in
    guard let context, let framePointer else { return }
    let box = Unmanaged<CallbackBox>.fromOpaque(context).takeUnretainedValue()
    let frame = framePointer.pointee
    guard frame.abi_version == RDN_ABI_VERSION, let bytes = frame.data,
        box.acceptsVideoFrame(
            connectionEpoch: frame.connection_epoch,
            catalogRevision: frame.display_catalog_revision, displayIndex: frame.display)
    else { return }
    // The Rust pointer is callback-scoped. Copy only compressed packet bytes.
    let data = Data(bytes: bytes, count: frame.length)
    let packet = CoreVideoPacket(
        codec: CoreVideoCodec(rawValue: Int32(frame.codec.rawValue)) ?? .unknown,
        format: CorePacketFormat(rawValue: Int32(frame.packet_format.rawValue)) ?? .unknown,
        data: data, sequence: frame.sequence, timestampUS: frame.timestamp_us, flags: frame.flags,
        width: frame.width, height: frame.height, display: frame.display,
        connectionEpoch: frame.connection_epoch,
        displayCatalogRevision: frame.display_catalog_revision)
    box.deliverVideo(packet)
}

let metricsCallback: RDNMetricsCallback = { context, metricsPointer in
    guard let context, let metricsPointer else { return }
    let box = Unmanaged<CallbackBox>.fromOpaque(context).takeUnretainedValue()
    let raw = metricsPointer.pointee
    guard raw.abi_version == RDN_ABI_VERSION else { return }
    let metrics = CoreRuntimeMetrics(
        remoteFPS: raw.remote_fps, networkDelayMS: raw.network_delay_ms,
        targetBitrate: raw.target_bitrate)
    box.queue.async { box.onMetrics(metrics) }
}
