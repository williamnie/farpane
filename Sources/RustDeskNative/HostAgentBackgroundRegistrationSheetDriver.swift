import AppKit
import CoreBridge

/// AppKit rendering boundary for H4.2o typed registration prompts. The driver
/// owns at most one sheet and validates both a private presentation token and
/// the UX generation before mapping a response back to the owner. Sequential
/// attempts are allowed after a terminal result, while construction remains
/// inert until a future explicit UI intent calls `begin`.
final class HostAgentBackgroundRegistrationSheetDriver {
    typealias Completion = (HostAgentBackgroundRegistrationUXView) -> Void
    typealias Update = (HostAgentBackgroundRegistrationUXView) -> Void

    private let owner: HostAgentBackgroundRegistrationUXOwner
    private let onUpdate: Update
    private weak var parentWindow: NSWindow?
    private var alert: NSAlert?
    private var completion: Completion?
    private var activePresentationToken: UInt64 = 0
    private var isRunning = false

    static func makeProduct(
        mutationOwner: HostAgentBackgroundRegistrationMutationOwner,
        performMigrationPreparation:
            @escaping HostAgentBackgroundRegistrationUXOwner.MigrationPreparation,
        onUpdate: @escaping Update = { _ in }
    ) -> HostAgentBackgroundRegistrationSheetDriver {
        HostAgentBackgroundRegistrationSheetDriver(
            owner: HostAgentBackgroundRegistrationUXOwner.makeProduct(
                mutationOwner: mutationOwner,
                performMigrationPreparation: performMigrationPreparation), onUpdate: onUpdate)
    }

    init(owner: HostAgentBackgroundRegistrationUXOwner, onUpdate: @escaping Update = { _ in }) {
        self.owner = owner
        self.onUpdate = onUpdate
    }

    @discardableResult func begin(on window: NSWindow, completion: @escaping Completion = { _ in })
        -> Bool
    {
        guard Thread.isMainThread, !isRunning, alert == nil else { return false }
        isRunning = true
        parentWindow = window
        self.completion = completion

        guard owner.apply(.requestBackgroundRegistration) else {
            finish(owner.snapshot())
            return false
        }
        let current = owner.snapshot()
        guard present(current, on: window) else {
            finish(current)
            return false
        }
        return true
    }

    private func present(_ view: HostAgentBackgroundRegistrationUXView, on window: NSWindow) -> Bool
    {
        guard Thread.isMainThread, isRunning, alert == nil, activePresentationToken < UInt64.max,
            case .awaitingConfirmation(let prompt) = view.phase
        else { return false }

        activePresentationToken += 1
        let token = activePresentationToken
        let generation = view.generation
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = prompt.title
        alert.informativeText = prompt.message
        alert.addButton(withTitle: prompt.confirmButtonTitle)
        alert.addButton(withTitle: prompt.cancelButtonTitle)
        self.alert = alert
        onUpdate(view)
        alert.beginSheetModal(for: window) { [weak self, weak alert] response in
            guard let self, let alert else { return }
            self.handleResponse(
                response, alert: alert, prompt: prompt, generation: generation, token: token)
        }
        return true
    }

    private func handleResponse(
        _ response: NSApplication.ModalResponse, alert: NSAlert,
        prompt: HostAgentBackgroundRegistrationUXPrompt, generation: UInt64, token: UInt64
    ) {
        guard Thread.isMainThread, isRunning, self.alert === alert, activePresentationToken == token
        else { return }
        self.alert = nil

        let current = owner.snapshot()
        guard current.generation == generation, current.phase == .awaitingConfirmation(prompt)
        else {
            finish(current)
            return
        }

        let intent = HostAgentBackgroundRegistrationSheetResponsePolicy.intent(
            promptKind: prompt.kind, confirmed: response == .alertFirstButtonReturn)
        _ = owner.apply(intent)
        let updated = owner.snapshot()

        guard case .awaitingConfirmation = updated.phase, updated.generation > generation,
            let window = parentWindow
        else {
            finish(updated)
            return
        }
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window, self.isRunning else { return }
            if !self.present(updated, on: window) { self.finish(updated) }
        }
    }

    private func finish(_ view: HostAgentBackgroundRegistrationUXView) {
        guard isRunning else { return }
        let completion = completion
        self.completion = nil
        alert = nil
        parentWindow = nil
        isRunning = false
        onUpdate(view)
        completion?(view)
    }
}
