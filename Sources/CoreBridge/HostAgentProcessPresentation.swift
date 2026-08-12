import CoreBridgeShim

package enum HostAgentProcessPresentation {
    package static func transformCurrentProcessToUIElement() -> Bool {
        rdn_shim_transform_current_process_to_ui_element() != 0
    }
}
