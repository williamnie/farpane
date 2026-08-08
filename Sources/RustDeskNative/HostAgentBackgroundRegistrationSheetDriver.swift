import AppKit
import CoreBridge

/// AppKit rendering boundary for H4.2o typed registration prompts. The driver
/// owns at most one sheet and validates both a private presentation token and
/// the UX generation before mapping a response back to the owner. It is not
/// connected to the legacy in-process Host toggle or App lifecycle yet.
final class HostAgentBackgroundRegistrationSheetDriver {
    typealias Completion = (HostAgentBackgroundRegistrationUXView) -> Void
    typealias Update = (HostAgentBackgroundRegistrationUXView) -> Void

    private let owner: HostAgentBackgroundRegistrationUXOwner
    private let onUpdate: Update
    private weak var parentWindow: NSWindow?
    private var alert: NSAlert?
    private var completion: Completion?
    private var activePresentationToken: UInt64 = 0
    private var hasStarted = false
    private var hasFinished = false

    static func makeProduct(
        onUpdate: @escaping Update = { _ in }
    ) -> HostAgentBackgroundRegistrationSheetDriver {
        HostAgentBackgroundRegistrationSheetDriver(
            owner: HostAgentBackgroundRegistrationUXOwner.makeProduct(),
            onUpdate: onUpdate
        )
    }

    init(
        owner: HostAgentBackgroundRegistrationUXOwner,
        onUpdate: @escaping Update = { _ in }
    ) {
        self.owner = owner
        self.onUpdate = onUpdate
    }

    @discardableResult
    func begin(
        on window: NSWindow,
        completion: @escaping Completion = { _ in }
    ) -> Bool {
        guard Thread.isMainThread,
              !hasStarted,
              !hasFinished,
              alert == nil
        else { return false }
        hasStarted = true
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

    private func present(
        _ view: HostAgentBackgroundRegistrationUXView,
        on window: NSWindow
    ) -> Bool {
        guard Thread.isMainThread,
              !hasFinished,
              alert == nil,
              activePresentationToken < UInt64.max,
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
                response,
                alert: alert,
                prompt: prompt,
                generation: generation,
                token: token
            )
        }
        return true
    }

    private func handleResponse(
        _ response: NSApplication.ModalResponse,
        alert: NSAlert,
        prompt: HostAgentBackgroundRegistrationUXPrompt,
        generation: UInt64,
        token: UInt64
    ) {
        guard Thread.isMainThread,
              !hasFinished,
              self.alert === alert,
              activePresentationToken == token
        else { return }
        self.alert = nil

        let current = owner.snapshot()
        guard current.generation == generation,
              current.phase == .awaitingConfirmation(prompt)
        else {
            finish(current)
            return
        }

        let intent = HostAgentBackgroundRegistrationSheetResponsePolicy.intent(
            promptKind: prompt.kind,
            confirmed: response == .alertFirstButtonReturn
        )
        _ = owner.apply(intent)
        let updated = owner.snapshot()

        guard case .awaitingConfirmation = updated.phase,
              updated.generation > generation,
              let window = parentWindow
        else {
            finish(updated)
            return
        }
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window, !self.hasFinished else { return }
            if !self.present(updated, on: window) {
                self.finish(updated)
            }
        }
    }

    private func finish(_ view: HostAgentBackgroundRegistrationUXView) {
        guard !hasFinished else { return }
        hasFinished = true
        alert = nil
        parentWindow = nil
        onUpdate(view)
        let completion = completion
        self.completion = nil
        completion?(view)
    }
}
