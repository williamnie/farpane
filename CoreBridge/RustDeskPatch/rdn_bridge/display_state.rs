#[derive(Clone, Debug, PartialEq)]
struct NativeViewerDisplayCatalogEntry {
    display_index: u32,
    x: i32,
    y: i32,
    width: i32,
    height: i32,
    online: bool,
    scale: f64,
    name: Vec<u8>,
}

#[derive(Clone, Default)]
struct NativeViewerDisplayCatalogState {
    initialized: bool,
    revision: u64,
    entries: Option<Arc<[NativeViewerDisplayCatalogEntry]>>,
    selected_display_index: Option<u32>,
    last_selection_command_id: u64,
    pending_selection: Option<NativeViewerDisplaySelectionPending>,
}

#[derive(Clone, Copy)]
struct NativeViewerDisplaySelectionPending {
    connection_epoch: u64,
    command_id: u64,
    catalog_revision: u64,
    display_index: u32,
}

#[derive(Clone, Copy)]
struct NativeViewerDisplaySelectionSnapshot {
    pending: NativeViewerDisplaySelectionPending,
    result: u32,
    failure: u32,
}

#[derive(Clone)]
struct NativeViewerDisplayCatalogSnapshot {
    connection_epoch: u64,
    revision: u64,
    entries: Option<Arc<[NativeViewerDisplayCatalogEntry]>>,
    selected_display_index: Option<u32>,
}

#[derive(Clone, Copy)]
enum NativeViewerDisplaySelectionIngress {
    RemoteFollow,
    SwitchEcho,
}

fn normalized_native_viewer_display_catalog(
    displays: &[DisplayInfo],
) -> Option<Vec<NativeViewerDisplayCatalogEntry>> {
    if displays.len() > MAX_DISPLAY_CATALOG_ENTRIES {
        return None;
    }
    displays
        .iter()
        .enumerate()
        .map(|(index, display)| {
            let name = display.name.as_bytes();
            let valid_geometry = if display.online {
                display.width > 0 && display.height > 0
            } else {
                display.width >= 0 && display.height >= 0
            };
            if !valid_geometry
                || !display.scale.is_finite()
                || display.scale <= 0.0
                || display.scale > 16.0
                || name.len() > MAX_DISPLAY_NAME_UTF8_BYTES
                || display.name.chars().any(char::is_control)
            {
                return None;
            }
            Some(NativeViewerDisplayCatalogEntry {
                display_index: u32::try_from(index).ok()?,
                x: display.x,
                y: display.y,
                width: display.width,
                height: display.height,
                online: display.online,
                scale: display.scale,
                name: name.to_vec(),
            })
        })
        .collect()
}
