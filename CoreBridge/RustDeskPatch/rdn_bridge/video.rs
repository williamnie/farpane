struct PacketInspection {
    format: RDNPacketFormat,
    flags: u32,
}

fn inspect_packet(data: &[u8]) -> PacketInspection {
    let annex_types = annex_b_nal_types(data);
    let avcc_types = avcc_nal_types(data);
    let (format, types) = match (annex_types, avcc_types) {
        (Some(types), None) => (RDNPacketFormat::AnnexB, types),
        (None, Some(types)) => (RDNPacketFormat::Avcc, types),
        (Some(types), Some(_)) => (RDNPacketFormat::Mixed, types),
        (None, None) => (RDNPacketFormat::Unknown, Vec::new()),
    };
    let mut flags = 0;
    for nal_type in types {
        match nal_type {
            32 => flags |= FLAG_VPS,
            33 => flags |= FLAG_SPS,
            34 => flags |= FLAG_PPS,
            _ => {}
        }
    }
    PacketInspection { format, flags }
}

fn annex_b_nal_types(data: &[u8]) -> Option<Vec<u8>> {
    let mut starts = Vec::new();
    let mut index = 0;
    while index + 3 <= data.len() {
        let prefix = if index + 4 <= data.len() && data[index..index + 4] == [0, 0, 0, 1] {
            4
        } else if data[index..index + 3] == [0, 0, 1] {
            3
        } else {
            index += 1;
            continue;
        };
        starts.push((index, prefix));
        index += prefix;
    }
    if starts.first().map(|entry| entry.0) != Some(0) {
        return None;
    }
    let types: Vec<u8> = starts
        .iter()
        .filter_map(|(offset, prefix)| data.get(offset + prefix).map(|byte| (byte >> 1) & 0x3f))
        .collect();
    (!types.is_empty()).then_some(types)
}

fn avcc_nal_types(data: &[u8]) -> Option<Vec<u8>> {
    let mut index = 0;
    let mut types = Vec::new();
    while index + 4 <= data.len() {
        let length = u32::from_be_bytes(data[index..index + 4].try_into().ok()?) as usize;
        index += 4;
        if length == 0 || index + length > data.len() {
            return None;
        }
        types.push((data[index] >> 1) & 0x3f);
        index += length;
    }
    (index == data.len() && !types.is_empty()).then_some(types)
}
