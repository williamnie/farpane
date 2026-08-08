import Foundation

package enum HostAgentBackgroundRegistrationUXIntent: Equatable, Sendable {
    case requestBackgroundRegistration
    case confirmBackgroundRegistration
    case cancelBackgroundRegistration
    case confirmApprovalNavigation
    case cancelApprovalNavigation
}

package enum HostAgentBackgroundRegistrationUXPromptKind:
    Equatable,
    Sendable
{
    case backgroundPersistence
    case loginItemsApproval
}

package struct HostAgentBackgroundRegistrationUXPrompt:
    Equatable,
    Sendable
{
    package let kind: HostAgentBackgroundRegistrationUXPromptKind
    package let title: String
    package let message: String
    package let confirmButtonTitle: String
    package let cancelButtonTitle: String

    fileprivate init(
        kind: HostAgentBackgroundRegistrationUXPromptKind,
        title: String,
        message: String,
        confirmButtonTitle: String,
        cancelButtonTitle: String
    ) {
        self.kind = kind
        self.title = title
        self.message = message
        self.confirmButtonTitle = confirmButtonTitle
        self.cancelButtonTitle = cancelButtonTitle
    }
}

package enum HostAgentBackgroundRegistrationUXFailure:
    Equatable,
    Sendable
{
    case migration(HostAgentLegacyHostMigrationCoordinatorFailure)
    case registration(HostAgentBackgroundRegistrationMutationFailure)
    case approvalNavigation(HostAgentBackgroundApprovalNavigationFailure)
    case invalidMigrationResult
    case invalidRegistrationResult
    case invalidApprovalNavigationResult
    case generationExhausted
}

package enum HostAgentBackgroundRegistrationUXPhase: Equatable, Sendable {
    case idle
    case awaitingConfirmation(HostAgentBackgroundRegistrationUXPrompt)
    case preparingLegacyHost
    case migrationBlocked(Set<HostAgentLegacyHostMigrationBlocker>)
    case registering
    case registered
    case navigating
    case navigationRequested
    case approvalNoLongerRequired
    case cancelled
    case failed(HostAgentBackgroundRegistrationUXFailure)
}

package struct HostAgentBackgroundRegistrationUXView: Equatable, Sendable {
    package let generation: UInt64
    package let phase: HostAgentBackgroundRegistrationUXPhase
    package let registration: HostAgentBackgroundRegistrationStatus?

    package init(
        generation: UInt64,
        phase: HostAgentBackgroundRegistrationUXPhase,
        registration: HostAgentBackgroundRegistrationStatus?
    ) {
        self.generation = generation
        self.phase = phase
        self.registration = registration
    }
}

/// Product-independent UX sequencing for background registration. It owns the
/// exact user disclosure and confirmation order, but no UI toolkit. The first
/// positive confirmation may invoke registration; a requires-approval result
/// creates a second prompt, whose positive confirmation alone may navigate to
/// Login Items. Registration, navigation and Agent readiness remain distinct.
package final class HostAgentBackgroundRegistrationUXOwner:
    @unchecked Sendable
{
    package typealias MigrationPreparation = @Sendable () -> (
        Bool,
        HostAgentLegacyHostMigrationCoordinatorView
    )
    package typealias Observer = @Sendable
        (HostAgentBackgroundRegistrationUXView) -> Void
    package typealias RegistrationOperation = @Sendable () -> (
        Bool,
        HostAgentBackgroundRegistrationMutationView
    )
    package typealias ApprovalNavigationOperation = @Sendable () -> (
        Bool,
        HostAgentBackgroundApprovalNavigationView
    )

    private static let persistencePrompt =
        HostAgentBackgroundRegistrationUXPrompt(
            kind: .backgroundPersistence,
            title: "允许 FarPane 在后台接受连接？",
            message: "启用后，即使退出 FarPane，当前已登录用户仍可通过这台 Mac 接受远程连接。你可以稍后在 FarPane 中关闭并取消后台注册。",
            confirmButtonTitle: "允许后台连接",
            cancelButtonTitle: "取消"
        )
    private static let approvalPrompt =
        HostAgentBackgroundRegistrationUXPrompt(
            kind: .loginItemsApproval,
            title: "还需要在系统设置中允许",
            message: "后台组件尚未获准运行。打开“系统设置 > 通用 > 登录项与扩展”，允许 FarPane 后返回应用；这一步不代表已可被连接。",
            confirmButtonTitle: "打开登录项设置",
            cancelButtonTitle: "稍后"
        )

    private let stateLock = NSLock()
    private let deliveryLock = NSRecursiveLock()
    private let performMigrationPreparation: MigrationPreparation
    private let performRegistration: RegistrationOperation
    private let performApprovalNavigation: ApprovalNavigationOperation
    private let observer: Observer
    private var transitionInFlight = false
    private var view = HostAgentBackgroundRegistrationUXView(
        generation: 0,
        phase: .idle,
        registration: nil
    )

    package static func makeProduct(
        mutationOwner: HostAgentBackgroundRegistrationMutationOwner,
        performMigrationPreparation: @escaping MigrationPreparation,
        observer: @escaping Observer = { _ in }
    ) -> HostAgentBackgroundRegistrationUXOwner {
        let navigationOwner =
            HostAgentBackgroundApprovalNavigationOwner.makeProduct()
        return HostAgentBackgroundRegistrationUXOwner(
            performMigrationPreparation: performMigrationPreparation,
            performRegistration: {
                let accepted = mutationOwner.apply(
                    .registerBackgroundAgent
                )
                return (accepted, mutationOwner.snapshot())
            },
            performApprovalNavigation: {
                let accepted = navigationOwner.apply(
                    .openLoginItemsAfterUserConfirmation
                )
                return (accepted, navigationOwner.snapshot())
            },
            observer: observer
        )
    }

    package init(
        performMigrationPreparation: @escaping MigrationPreparation,
        performRegistration: @escaping RegistrationOperation,
        performApprovalNavigation: @escaping ApprovalNavigationOperation,
        observer: @escaping Observer = { _ in }
    ) {
        self.performMigrationPreparation = performMigrationPreparation
        self.performRegistration = performRegistration
        self.performApprovalNavigation = performApprovalNavigation
        self.observer = observer
    }

    package func snapshot() -> HostAgentBackgroundRegistrationUXView {
        stateLock.lock()
        defer { stateLock.unlock() }
        return view
    }

    @discardableResult
    package func apply(
        _ intent: HostAgentBackgroundRegistrationUXIntent
    ) -> Bool {
        switch intent {
        case .requestBackgroundRegistration:
            return requestRegistration()
        case .confirmBackgroundRegistration:
            return confirmRegistration()
        case .cancelBackgroundRegistration:
            return cancelPrompt(kind: .backgroundPersistence)
        case .confirmApprovalNavigation:
            return confirmApprovalNavigation()
        case .cancelApprovalNavigation:
            return cancelPrompt(kind: .loginItemsApproval)
        }
    }

    private func requestRegistration() -> Bool {
        transition(
            allowed: { phase in
                switch phase {
                case .idle, .registered, .navigationRequested,
                     .approvalNoLongerRequired, .migrationBlocked,
                     .cancelled, .failed:
                    return true
                case .awaitingConfirmation, .preparingLegacyHost,
                     .registering, .navigating:
                    return false
                }
            },
            phase: .awaitingConfirmation(Self.persistencePrompt),
            registration: nil,
            result: true
        )
    }

    private func cancelPrompt(
        kind: HostAgentBackgroundRegistrationUXPromptKind
    ) -> Bool {
        transition(
            allowed: { phase in
                guard case .awaitingConfirmation(let prompt) = phase else {
                    return false
                }
                return prompt.kind == kind
            },
            phase: .cancelled,
            registration: currentRegistration(),
            result: true
        )
    }

    private func confirmRegistration() -> Bool {
        guard beginOperation(
            expectedPrompt: .backgroundPersistence,
            phase: .preparingLegacyHost
        ) else { return false }

        let (migrationAccepted, migration) = performMigrationPreparation()
        let migrationResolution = resolveMigration(
            accepted: migrationAccepted,
            migration: migration
        )
        if let terminalPhase = migrationResolution.phase {
            return finishOperation(
                phase: terminalPhase,
                registration: nil,
                result: migrationResolution.result
            )
        }
        guard advanceOperation(
            phase: .registering,
            registration: nil
        ) else { return false }

        let (accepted, mutation) = performRegistration()
        let resolution = resolveRegistration(
            accepted: accepted,
            mutation: mutation
        )
        return finishOperation(
            phase: resolution.phase,
            registration: mutation.registration,
            result: resolution.result
        )
    }

    private func confirmApprovalNavigation() -> Bool {
        guard beginOperation(
            expectedPrompt: .loginItemsApproval,
            phase: .navigating
        ) else { return false }

        let (accepted, navigation) = performApprovalNavigation()
        let resolution = resolveApprovalNavigation(
            accepted: accepted,
            navigation: navigation
        )
        return finishOperation(
            phase: resolution.phase,
            registration: navigation.registration,
            result: resolution.result
        )
    }

    private func transition(
        allowed: (HostAgentBackgroundRegistrationUXPhase) -> Bool,
        phase: HostAgentBackgroundRegistrationUXPhase,
        registration: HostAgentBackgroundRegistrationStatus?,
        result: Bool
    ) -> Bool {
        deliveryLock.lock()
        stateLock.lock()
        guard !transitionInFlight,
              view.generation < UInt64.max,
              allowed(view.phase)
        else {
            stateLock.unlock()
            deliveryLock.unlock()
            return false
        }
        transitionInFlight = true
        replaceViewLocked(phase: phase, registration: registration)
        let publication = view
        stateLock.unlock()
        observer(publication)
        stateLock.lock()
        transitionInFlight = false
        stateLock.unlock()
        deliveryLock.unlock()
        return result
    }

    private func beginOperation(
        expectedPrompt: HostAgentBackgroundRegistrationUXPromptKind,
        phase: HostAgentBackgroundRegistrationUXPhase
    ) -> Bool {
        deliveryLock.lock()
        stateLock.lock()
        guard !transitionInFlight,
              view.generation < UInt64.max,
              case .awaitingConfirmation(let prompt) = view.phase,
              prompt.kind == expectedPrompt
        else {
            stateLock.unlock()
            deliveryLock.unlock()
            return false
        }
        transitionInFlight = true
        replaceViewLocked(phase: phase, registration: view.registration)
        let publication = view
        stateLock.unlock()
        observer(publication)
        deliveryLock.unlock()
        return true
    }

    private func finishOperation(
        phase: HostAgentBackgroundRegistrationUXPhase,
        registration: HostAgentBackgroundRegistrationStatus?,
        result: Bool
    ) -> Bool {
        deliveryLock.lock()
        stateLock.lock()
        guard transitionInFlight else {
            stateLock.unlock()
            deliveryLock.unlock()
            return false
        }

        let finalResult: Bool
        if view.generation == UInt64.max {
            replaceViewLocked(
                phase: .failed(.generationExhausted),
                registration: registration
            )
            finalResult = false
        } else {
            replaceViewLocked(phase: phase, registration: registration)
            finalResult = result
        }
        let publication = view
        stateLock.unlock()
        observer(publication)
        stateLock.lock()
        transitionInFlight = false
        stateLock.unlock()
        deliveryLock.unlock()
        return finalResult
    }

    private func advanceOperation(
        phase: HostAgentBackgroundRegistrationUXPhase,
        registration: HostAgentBackgroundRegistrationStatus?
    ) -> Bool {
        deliveryLock.lock()
        stateLock.lock()
        guard transitionInFlight else {
            stateLock.unlock()
            deliveryLock.unlock()
            return false
        }
        guard view.generation < UInt64.max else {
            replaceViewLocked(
                phase: .failed(.generationExhausted),
                registration: registration
            )
            let publication = view
            transitionInFlight = false
            stateLock.unlock()
            observer(publication)
            deliveryLock.unlock()
            return false
        }
        replaceViewLocked(phase: phase, registration: registration)
        let publication = view
        stateLock.unlock()
        observer(publication)
        deliveryLock.unlock()
        return true
    }

    private func resolveMigration(
        accepted: Bool,
        migration: HostAgentLegacyHostMigrationCoordinatorView
    ) -> (
        phase: HostAgentBackgroundRegistrationUXPhase?,
        result: Bool
    ) {
        switch migration.phase {
        case .readyForRegistration where accepted:
            return (nil, true)
        case .blocked(let blockers) where !accepted:
            return (.migrationBlocked(blockers), false)
        case .failed(let failure) where !accepted:
            return (.failed(.migration(failure)), false)
        case .idle, .assessing, .quiescing, .readyForRegistration,
             .blocked, .failed:
            return (.failed(.invalidMigrationResult), false)
        }
    }

    private func resolveRegistration(
        accepted: Bool,
        mutation: HostAgentBackgroundRegistrationMutationView
    ) -> (phase: HostAgentBackgroundRegistrationUXPhase, result: Bool) {
        switch mutation.phase {
        case .registered where accepted && mutation.registration == .enabled:
            return (.registered, true)
        case .requiresApproval
            where accepted && mutation.registration == .requiresApproval:
            return (.awaitingConfirmation(Self.approvalPrompt), true)
        case .failed(let intent, let failure)
            where !accepted && intent == .registerBackgroundAgent:
            return (.failed(.registration(failure)), false)
        case .idle, .registering, .unregistering, .registered,
             .requiresApproval, .unregistered, .failed:
            return (.failed(.invalidRegistrationResult), false)
        }
    }

    private func resolveApprovalNavigation(
        accepted: Bool,
        navigation: HostAgentBackgroundApprovalNavigationView
    ) -> (phase: HostAgentBackgroundRegistrationUXPhase, result: Bool) {
        switch navigation.phase {
        case .navigationRequested
            where accepted && navigation.registration == .requiresApproval:
            return (.navigationRequested, true)
        case .notRequired
            where !accepted
                && (navigation.registration == .enabled
                    || navigation.registration == .notRegistered):
            return (.approvalNoLongerRequired, false)
        case .failed(let failure) where !accepted:
            return (.failed(.approvalNavigation(failure)), false)
        case .idle, .checking, .notRequired, .navigationRequested, .failed:
            return (.failed(.invalidApprovalNavigationResult), false)
        }
    }

    private func replaceViewLocked(
        phase: HostAgentBackgroundRegistrationUXPhase,
        registration: HostAgentBackgroundRegistrationStatus?
    ) {
        view = HostAgentBackgroundRegistrationUXView(
            generation: view.generation == UInt64.max
                ? UInt64.max
                : view.generation + 1,
            phase: phase,
            registration: registration
        )
    }

    private func currentRegistration()
        -> HostAgentBackgroundRegistrationStatus?
    {
        stateLock.lock()
        defer { stateLock.unlock() }
        return view.registration
    }
}
