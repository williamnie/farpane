import AppKit
import CoreBridge

/// AppKit rendering boundary for explicit background unregistration. Each
/// attempt owns at most one sheet; sequential attempts are allowed only after
/// the previous attempt reached a terminal typed result.
final class HostAgentBackgroundUnregistrationSheetDriver {
    typealias Completion = (HostAgentBackgroundUnregistrationUXView) -> Void
    typealias Update = (HostAgentBackgroundUnregistrationUXView) -> Void

    private let owner: HostAgentBackgroundUnregistrationUXOwner
    private let onUpdate: Update
    private let mutationQueue = DispatchQueue(
        label: "io.farpane.background-unregistration",
        qos: .userInitiated
    )
    private var alert: NSAlert?
    private var completion: Completion?
    private var activePresentationToken: UInt64 = 0
    private var isRunning = false

    static func makeProduct(
        mutationOwner: HostAgentBackgroundRegistrationMutationOwner,
        onUpdate: @escaping Update = { _ in }
    ) -> HostAgentBackgroundUnregistrationSheetDriver {
        HostAgentBackgroundUnregistrationSheetDriver(
            owner: HostAgentBackgroundUnregistrationUXOwner.makeProduct(
                mutationOwner: mutationOwner
            ),
            onUpdate: onUpdate
        )
    }

    init(
        owner: HostAgentBackgroundUnregistrationUXOwner,
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
              !isRunning,
              alert == nil
        else { return false }
        isRunning = true
        self.completion = completion

        guard owner.apply(.requestBackgroundUnregistration) else {
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
        _ view: HostAgentBackgroundUnregistrationUXView,
        on window: NSWindow
    ) -> Bool {
        guard Thread.isMainThread,
              isRunning,
              alert == nil,
              activePresentationToken < UInt64.max,
              case .awaitingConfirmation(let prompt) = view.phase
        else { return false }

        activePresentationToken += 1
        let token = activePresentationToken
        let generation = view.generation
        let alert = NSAlert()
        alert.alertStyle = .warning
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
        prompt: HostAgentBackgroundUnregistrationUXPrompt,
        generation: UInt64,
        token: UInt64
    ) {
        guard Thread.isMainThread,
              isRunning,
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

        let intent =
            HostAgentBackgroundUnregistrationSheetResponsePolicy.intent(
                confirmed: response == .alertFirstButtonReturn
            )
        guard intent == .confirmBackgroundUnregistration else {
            _ = owner.apply(intent)
            finish(owner.snapshot())
            return
        }

        mutationQueue.async { [weak self] in
            guard let self else { return }
            _ = self.owner.apply(intent)
            let updated = self.owner.snapshot()
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      self.isRunning,
                      self.activePresentationToken == token,
                      self.alert == nil
                else { return }
                self.finish(updated)
            }
        }
    }

    private func finish(
        _ view: HostAgentBackgroundUnregistrationUXView
    ) {
        guard isRunning else { return }
        let completion = completion
        self.completion = nil
        alert = nil
        isRunning = false
        onUpdate(view)
        completion?(view)
    }
}
