package enum HostAgentBackgroundUnregistrationSheetResponsePolicy {
    package static func intent(
        confirmed: Bool
    ) -> HostAgentBackgroundUnregistrationUXIntent {
        confirmed
            ? .confirmBackgroundUnregistration
            : .cancelBackgroundUnregistration
    }
}
