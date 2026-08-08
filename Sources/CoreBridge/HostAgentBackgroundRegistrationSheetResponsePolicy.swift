package enum HostAgentBackgroundRegistrationSheetResponsePolicy {
    package static func intent(
        promptKind: HostAgentBackgroundRegistrationUXPromptKind,
        confirmed: Bool
    ) -> HostAgentBackgroundRegistrationUXIntent {
        switch (promptKind, confirmed) {
        case (.backgroundPersistence, true):
            return .confirmBackgroundRegistration
        case (.backgroundPersistence, false):
            return .cancelBackgroundRegistration
        case (.loginItemsApproval, true):
            return .confirmApprovalNavigation
        case (.loginItemsApproval, false):
            return .cancelApprovalNavigation
        }
    }
}
